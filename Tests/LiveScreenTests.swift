import XCTest
@testable import BCIWorkspace

/// Brief 004 PR 6: the acquisition screen's models and copy, the preview buffer, and the
/// live path end to end on the synthetic board (decision #26: no hardware in tests).
@MainActor
final class LiveScreenTests: XCTestCase {
    private var scratch: URL!
    private let daisy = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A chunk with `rows` rows; row r, sample j holds `value(r, j)`.
    private func chunk(rows: Int, count: Int, _ value: (Int, Int) -> Double) -> SampleChunk {
        var values = [Double](repeating: 0, count: rows * count)
        for r in 0..<rows { for j in 0..<count { values[r * count + j] = value(r, j) } }
        return SampleChunk(numRows: rows, count: count, values: values, drainedAtMonotonicNanos: 0, availableBeforeDrain: count, overflowSuspected: false)
    }

    // MARK: Copy

    func testStatusLines_everyState_andEveryReconnectNamed() {
        typealias M = AcquisitionStateModel
        XCTAssertTrue(M.statusLines(.disconnected, source: .demo, recording: false, reconnects: 0) == ("Disconnected", "Demo"))
        XCTAssertEqual(M.statusLines(.connecting, source: .demo, recording: false, reconnects: 0).state, "Connecting")
        XCTAssertEqual(M.statusLines(.ready, source: .demo, recording: false, reconnects: 0).state, "Ready")
        XCTAssertEqual(M.statusLines(.streaming, source: .demo, recording: false, reconnects: 0).state, "Streaming")
        XCTAssertEqual(M.statusLines(.streaming, source: .demo, recording: true, reconnects: 2).state, "Recording · reconnected 2×")
        XCTAssertEqual(M.statusLines(.interrupted(reason: "No samples for 3 s"), source: .demo, recording: true, reconnects: 1).state,
                       "Interrupted: No samples for 3 s · reconnected 1×")
        XCTAssertEqual(M.statusLines(.stopping, source: .demo, recording: false, reconnects: 0).state, "Stopping")
        XCTAssertEqual(M.statusLines(.failed(reason: "Port busy"), source: .demo, recording: false, reconnects: 0).state, "Failed: Port busy")
        // Decision #42: the Demo is "Demo" only; synthetic always says it is not a device.
        XCTAssertEqual(M.statusLines(.streaming, source: .synthetic, recording: false, reconnects: 0).source,
                       "Synthetic board — generated signal, not a device")
        XCTAssertEqual(M.statusLines(.streaming, source: .serial(SerialPort(path: "/dev/cu.usbserial-X")), recording: false, reconnects: 0).source,
                       "/dev/cu.usbserial-X")
        XCTAssertEqual(M.symbol(.streaming, recording: true), "record.circle.fill")
        XCTAssertEqual(M.symbol(.streaming, recording: false), "waveform")
        XCTAssertEqual(M.symbol(.interrupted(reason: ""), recording: false), "exclamationmark.triangle.fill")
        XCTAssertEqual(M.symbol(.failed(reason: ""), recording: false), "exclamationmark.octagon.fill")
        XCTAssertEqual(SidebarSection.statusLine, "No hardware connected · Replay mode", "still shown with no board")
    }

    func testScreenCopy() {
        XCTAssertEqual(LiveScreenModel.title(.demo), "Live · Demo")
        XCTAssertEqual(LiveScreenModel.title(.synthetic), "Live · Synthetic board (no hardware)")
        XCTAssertEqual(LiveScreenModel.recordingLine(elapsedS: 72.6, committedSamples: 8_750, rateHz: 125), "Recording · 01:12 · 70 s saved")
        XCTAssertEqual(LiveScreenModel.clock(3_725), "1:02:05")
        XCTAssertEqual(LiveScreenModel.saved(seconds: 8.2), "Recording saved: 8 s. It is listed under Recordings.")
        XCTAssertEqual(LiveScreenModel.mapLine(.none), "Channel map: not declared")
        XCTAssertEqual(LiveScreenModel.mapLine(.withoutPositions), "Channel map: without positions (montage \"undeclared\")")
        XCTAssertEqual(LivePreviewModel.heightText(100, auto: true), "Lane height 100 µV · auto")
        XCTAssertEqual(LivePreviewModel.pickerTitle(.fixed(50)), "50 µV")
        XCTAssertEqual(LivePreviewModel.ticks.map(LivePreviewModel.tickLabel), ["-10 s", "-8 s", "-6 s", "-4 s", "-2 s", "now"])
        // The brief's exact disk-full copy, and the warning before Record (decision #33).
        var full = RecordingWriter.Status()
        full.endReason = .diskFull
        full.committedSamples = 1_250
        XCTAssertEqual(RecordingEndModel.message(full, rateHz: 125), "Recording stopped: disk full. 10 s recorded and saved.")
        XCTAssertEqual(RecordingEndModel.diskWarning(hoursLeft: 0.5, freeBytes: 150_000_000),
                       "Less than 1 hour of recording space left (150 MB free). Recording stops at 100 MB free.")
        XCTAssertNil(RecordingEndModel.diskWarning(hoursLeft: 3, freeBytes: 1_000_000_000))
    }

    func testLiveRecordingTitle_namesSourceAndStart() throws {
        var m = try ContractJSON.decoder().decode(RecordingManifest.self, from: Data(contentsOf: fixtureManifest()))
        m.createdAt = Date(timeIntervalSince1970: 1_763_663_400)            // 2025-11-20 18:30 UTC
        m.source.subject = nil
        m.source.kind = "synthetic"
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Synthetic recording · 2025-11-20 18:30")
        m.source.kind = "playback"
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Playback recording · 2025-11-20 18:30")
        m.source.kind = "brainflow"
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Recording · 2025-11-20 18:30")
        m.source.kind = "public_dataset"
        XCTAssertNil(RecordingDetailModel.liveTitle(for: m))
    }

    private func fixtureManifest() throws -> URL {
        let recordings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tiny.bciproj/recordings")
        let first = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: recordings.path).first { !$0.hasPrefix(".") })
        return recordings.appendingPathComponent(first).appendingPathComponent("recording.json")
    }

    // MARK: Preview model

    func testPreviewModel_meanRemoved_newestAtRight_breakAndClipping() {
        let buffer = PreviewBuffer(rows: [1, 2], rate: 10, seconds: 10)      // capacity 100
        buffer.ingest(.init(segment: 0, chunk: chunk(rows: 3, count: 40) { r, _ in r == 1 ? 1_000 : -5 }))
        buffer.ingest(.init(segment: 1, chunk: chunk(rows: 3, count: 10) { r, j in r == 1 ? 1_000 + Double(j) : -5 }))
        let w = buffer.window()
        XCTAssertEqual(w.count, 50)
        XCTAssertEqual(w.segmentStart, 40)
        let m = LivePreviewModel(window: w, labels: ["C3"], columns: 10, height: 4)
        XCTAssertEqual(m.lanes.map(\.label), ["C3", "ch2"])
        XCTAssertEqual(m.lanes[0].columns.prefix(5), [nil, nil, nil, nil, nil], "an unfilled window is empty on the left")
        XCTAssertNotNil(m.lanes[0].columns[9])
        XCTAssertEqual(m.breakColumn, 9)
        XCTAssertEqual(m.filledSeconds, 5)
        // Mean of 40 × 1000 and 1000…1009 = 1000.9: display-only offset, values otherwise as received.
        XCTAssertEqual(Double(m.lanes[0].columns[5]!.lo), -0.9, accuracy: 1e-3)
        XCTAssertTrue(m.lanes[0].clipped, "1009 − 1000.9 = 8.1 µV is past ± 2 µV")
        XCTAssertFalse(m.lanes[1].clipped, "a flat channel is flat")
    }

    func testAutoHeight_isA125Step_fromTheMedianChannel() {
        let buffer = PreviewBuffer(rows: [0, 1, 2], rate: 100, seconds: 1)
        buffer.ingest(.init(segment: 0, chunk: chunk(rows: 3, count: 100) { r, j in
            let amp = [10.0, 60.0, 5_000.0][r]                 // one channel far noisier
            return j % 2 == 0 ? amp : -amp
        }))
        XCTAssertEqual(LivePreviewModel.autoHeight(buffer.window()), 200, "median span 120 µV × 0.85 → 200")
        XCTAssertEqual(LivePreviewModel.autoHeight(PreviewBuffer(rows: [0], rate: 1).window()), 100, "no samples: a default")
    }

    // MARK: Preview buffer

    func testPreviewBuffer_isABoundedRing_inOrder_acrossWrap() {
        let buffer = PreviewBuffer(rows: [0], rate: 5, seconds: 2)          // capacity 10
        var next = 0.0
        for n in [3, 4, 6, 25] {
            buffer.ingest(.init(segment: 0, chunk: chunk(rows: 1, count: n) { _, _ in defer { next += 1 }; return next }))
        }
        let w = buffer.window()
        XCTAssertEqual(w.channels[0], (28..<38).map(Float.init), "the newest 10, oldest first")
        XCTAssertEqual(w.segmentStart, 0)
        XCTAssertEqual(w.framesIngested, 4)
        buffer.ingest(.init(segment: 0, chunk: chunk(rows: 1, count: 0) { _, _ in 0 }))
        XCTAssertEqual(buffer.window().framesIngested, 4, "an empty drain is not a frame")
        buffer.ingest(.init(segment: 0, chunk: chunk(rows: 0, count: 3) { _, _ in 0 }))
        XCTAssertEqual(buffer.window().channels[0].count, 10, "a chunk without the rows is ignored")
    }

    func testPreview_slowConsumerDropsFrames_recordingKeepsEverySample() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("p.bciproj"), name: "p")
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory)
        await session.connect()
        await session.startStreaming()
        let d = try XCTUnwrap(session.snapshot.board)
        let id = try await session.startRecording(.init(map: .defaults(for: d)), in: store)
        // Nobody reads the preview for 3 s (about 60 drains): only the newest frames wait.
        try await Task.sleep(for: .seconds(3))
        let buffer = PreviewBuffer(rows: d.eegChannelRows, rate: d.samplingRate)
        let consumer = Task.detached { await buffer.consume(session.preview) }
        try await Task.sleep(for: .milliseconds(300))
        let stopped = await session.stopRecording()
        let status = try XCTUnwrap(stopped)
        let health = session.snapshot.health
        await session.disconnect()
        consumer.cancel()
        let w = buffer.window()
        XCTAssertGreaterThan(w.count, 0)
        XCTAssertLessThan(w.framesIngested, 30, "the stalled preview lost frames (newest-wins)")
        let handle = try await store.recording(id: id)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.chunks.reduce(0) { $0 + $1.sampleCount }, status.committedSamples)
        XCTAssertEqual(status.uncommittedSamples, 0)
        XCTAssertGreaterThan(status.committedSamples, 3 * d.samplingRate, "the recording has every drained second")
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [], "no false gaps from the stalled preview")
        XCTAssertEqual(health.gaps.values.reduce(0) { $0 + $1.events }, 0)
    }

    // MARK: End to end

    private func liveProject() async throws -> (Workspace, ProjectSession, ConnectController, URL) {
        let url = scratch.appendingPathComponent("live.bciproj")
        let store = try ProjectStore.create(at: url, name: "live")
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        let session = await workspace.adopt(store)
        let live = session.wire(ConnectController(store: store, projectDirectory: url, demoFile: nil, scan: { [] }))
        session.showsConnectSheet = true
        live.selectedID = ConnectSource.synthetic.id
        await live.perform(.connect)
        XCTAssertEqual(live.state, .ready)
        return (workspace, session, live, url)
    }

    func testSynthetic_connectPreviewRecord5sStop_recordingOpensAndVerifies() async throws {
        let (workspace, session, live, url) = try await liveProject()
        XCTAssertEqual(live.recordDisabledReason, RecordGate.notStreaming)
        await live.perform(.startPreview)
        XCTAssertFalse(session.showsConnectSheet, "the sheet hands over to the acquisition screen")
        XCTAssertTrue(session.liveShown && session.hasLiveRow)
        XCTAssertFalse(session.canEvaluate, "Evaluate waits while the live screen is shown")
        XCTAssertEqual(live.recordDisabledReason, ChannelMapModel.undecided, "decision #31: an explicit map choice first")
        live.recordWithoutPositions()
        XCTAssertNil(live.recordDisabledReason)
        let buffer = try XCTUnwrap(live.preview)
        try await waitFor("preview samples") { buffer.window().count > 0 }

        await live.perform(.record)
        XCTAssertTrue(live.isRecording)
        XCTAssertNotNil(live.recordingStartedAt)
        try await Task.sleep(for: .seconds(5))
        await live.perform(.stopRecording)
        XCTAssertFalse(live.isRecording)
        XCTAssertEqual(live.state, .streaming, "Stop recording keeps the preview running")
        let id = try XCTUnwrap(live.lastRecordingID)
        XCTAssertEqual(live.recordMessage?.danger, false)
        XCTAssertTrue(live.recordMessage?.text.hasPrefix("Recording saved: ") == true, live.recordMessage?.text ?? "")
        await session.liveReload?.value
        XCTAssertEqual(session.recordings.map(\.id), [id], "listed in Recordings")
        session.showRecording(id)
        XCTAssertFalse(session.liveShown)
        XCTAssertEqual(session.selectedRecordingID, id)

        let handle = try XCTUnwrap(session.selectedRecording)
        XCTAssertEqual(handle.verify(), [])
        let model = RecordingDetailModel(manifest: handle.manifest, events: session.eventsByRecording[id] ?? [])
        XCTAssertTrue(model.title.hasPrefix("Synthetic recording · "), model.title)
        XCTAssertEqual(model.warning, "Synthetic board — generated signal, not a device")
        XCTAssertEqual(model.montage, "undeclared")
        XCTAssertEqual(model.channels.count, 16)
        XCTAssertEqual(model.segments.map(\.endReason), ["stopped"])
        XCTAssertEqual(model.events, [], "events arrive with brief 005")
        let seconds = Double(model.segments[0].samples) / handle.manifest.timing.nominalSampleRateHz
        XCTAssertGreaterThan(seconds, 4.5)

        await workspace.close(url)
        XCTAssertEqual(session.live?.isClosed, true, "the board is released with the window")
        XCTAssertEqual(live.session?.snapshot.state, .disconnected)
    }

    func testClosingTheWindowWhileRecording_stopsTheRecordingAsStopped_andReleasesTheBoard() async throws {
        let (workspace, session, live, url) = try await liveProject()
        await live.perform(.startPreview)
        live.recordWithoutPositions()
        await live.perform(.record)
        let recording = try XCTUnwrap(live.snapshot.recordingID)
        try await Task.sleep(for: .seconds(2))
        // What "Stop Recording and Close" (and quitting, through closeAll) runs.
        await workspace.closeAll()
        XCTAssertTrue(session.isShutDown)
        XCTAssertEqual(live.session?.snapshot.state, .disconnected)
        XCTAssertFalse(live.session?.snapshot.holdsPowerAssertion ?? true)
        let reopened = try ProjectStore.open(at: url)
        let handle = try await reopened.recording(id: recording)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.segments.map(\.endReason), [.stopped], "stopped, not process_terminated")
        XCTAssertGreaterThan(handle.manifest.chunks.reduce(0) { $0 + $1.sampleCount }, 0)
    }

    func testSheetClose_beforeStreaming_disconnects_afterStreaming_keepsTheBoard() async throws {
        let (_, session, live, _) = try await liveProject()
        await live.closeSheet()
        session.connectSheetClosed()
        XCTAssertEqual(live.session?.snapshot.state, .disconnected, "never streamed: the board goes with the sheet")
        XCTAssertNil(session.live)

        session.showConnectSheet()
        let next = try XCTUnwrap(session.live)
        XCTAssertFalse(next === live, "a fresh controller after a closed one")
        await session.endLive()
    }
}
