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

    func testCloseConfirmationCopy() {
        XCTAssertEqual(CloseConfirmation.recording.message, "Stop recording and close?")
        XCTAssertEqual(CloseConfirmation.recording.confirm, "Stop Recording and Close")
        XCTAssertEqual(CloseConfirmation.recording.keep, "Keep Recording")
        XCTAssertTrue(CloseConfirmation.recording.info.contains("ends here as stopped"))
        XCTAssertEqual(CloseConfirmation.evaluation.message, "Stop the evaluation and close?")
        XCTAssertEqual(CloseConfirmation.evaluation.info, "Nothing will be saved.")
    }

    func testWelcomeHardwareEnabled_introAndPlaceholderNoLongerSayPhase2() {
        let hardware = WelcomeModel.actions.first { $0.kind == .hardware }!
        XCTAssertTrue(hardware.isEnabled)
        XCTAssertFalse(hardware.caption.contains("phase 2"))
        XCTAssertTrue(hardware.caption.contains("Opens a project first"))
        XCTAssertFalse(IntroModel.steps[3].title.contains("phase 2"))
        XCTAssertFalse(IntroModel.steps[3].body.contains("phase 2"))
        XCTAssertFalse(LiveScreenModel.emptyRecordings.contains("phase 2"))
        XCTAssertTrue(LiveScreenModel.emptyRecordings.contains("New Recording…"))
        // Protocols and Live Test still arrive later (briefs 005 / 006).
        XCTAssertTrue(SidebarSection.protocols.placeholder!.contains("arrive"))
        XCTAssertTrue(SidebarSection.liveTest.placeholder!.contains("arrives"))
    }

    func testLiveRecordingTitle_namesSourceAndStart() throws {
        var m = try ContractJSON.decoder().decode(RecordingManifest.self, from: Data(contentsOf: fixtureManifest()))
        m.createdAt = Date(timeIntervalSince1970: 1_763_663_400)            // 2025-11-20 18:30 UTC
        m.source.subject = nil
        m.source.kind = "synthetic"
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Synthetic recording · 2025-11-20 18:30")
        m.source.kind = "playback"
        m.source.sourceFiles = [.init(name: "other.csv", sha256: "x")]
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Playback recording · 2025-11-20 18:30")
        m.source.sourceFiles = [.init(name: AcquisitionSource.demoFileName, sha256: "x")]
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Demo recording · 2025-11-20 18:30",
                       "decision #42: the Demo is Demo on screen")
        m.source.kind = "brainflow"
        XCTAssertEqual(RecordingDetailModel.liveTitle(for: m, timeZone: TimeZone(identifier: "UTC")!), "Recording · 2025-11-20 18:30")
        m.source.kind = "public_dataset"
        XCTAssertNil(RecordingDetailModel.liveTitle(for: m))
    }

    func testDemoRecording_isJustDemoOnScreen_provenanceStaysStored() throws {
        var m = try ContractJSON.decoder().decode(RecordingManifest.self, from: Data(contentsOf: fixtureManifest()))
        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo())
        m.source = AcquisitionSource.playback(file: csv, loop: true).recordingSource(daisy, appVersion: "t")
        let model = RecordingDetailModel(manifest: m, events: [])
        XCTAssertEqual(model.badge, "Demo")
        XCTAssertNil(model.warning, "decision #42: no playback / not-a-device banner on screen")
        XCTAssertEqual(model.sourceFields.first { $0.label == "Device" }?.value, "Demo")
        XCTAssertNil(model.sourceFields.first { $0.label == "Runs" }, "no raw run UUID")
        let shown = ([model.title] + model.sourceFields.map(\.value)).joined(separator: " ").lowercased()
        XCTAssertFalse(shown.contains("playback"), shown)
        XCTAssertFalse(shown.contains("not a device") || shown.contains("not from a device"), shown)
        // The stored provenance is untouched, and the export still carries it.
        XCTAssertEqual(m.source.kind, "playback")
        XCTAssertTrue(m.source.warning?.hasPrefix("Derived demo input") == true)
        XCTAssertTrue(ProjectStore.attribution(for: m).contains("Derived demo input"))
        // Synthetic keeps its warning.
        m.source = AcquisitionSource.synthetic.recordingSource(daisy, appVersion: "t")
        let synthetic = RecordingDetailModel(manifest: m, events: [])
        XCTAssertEqual(synthetic.warning, "Synthetic board — generated signal, not a device")
        XCTAssertNil(synthetic.badge)
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
        XCTAssertEqual(w.segmentStarts, [40])
        let m = LivePreviewModel(window: w, labels: ["C3"], columns: 10, height: 4)
        XCTAssertEqual(m.lanes.map(\.label), ["C3", "Channel 2"])
        XCTAssertEqual(m.lanes[0].columns.prefix(5), [nil, nil, nil, nil, nil], "an unfilled window is empty on the left")
        XCTAssertNotNil(m.lanes[0].columns[9])
        XCTAssertEqual(m.breakColumns, [9])
        XCTAssertEqual(m.filledSeconds, 5)
        // Mean of 40 × 1000 and 1000…1009 = 1000.9: display-only offset, values otherwise as received.
        XCTAssertEqual(Double(m.lanes[0].columns[5]!.lo), -0.9, accuracy: 1e-3)
        XCTAssertTrue(m.lanes[0].clipped, "1009 − 1000.9 = 8.1 µV is past ± 2 µV")
        XCTAssertFalse(m.lanes[1].clipped, "a flat channel is flat")
    }

    func testPreviewBuffer_keepsEverySegmentBreakInTheWindow_andForgetsOnesThatScrolledOut() {
        let buffer = PreviewBuffer(rows: [0], rate: 10, seconds: 2)         // capacity 20
        for segment in 0..<4 { buffer.ingest(.init(segment: segment, chunk: chunk(rows: 1, count: 6) { _, _ in 1 })) }
        // 24 samples: segments start at 6, 12, 18; the window holds 4…23.
        XCTAssertEqual(buffer.window().segmentStarts, [2, 8, 14])
        XCTAssertEqual(buffer.framesIngested, 4)
        XCTAssertEqual(buffer.filledCount, 20)
        buffer.ingest(.init(segment: 3, chunk: chunk(rows: 1, count: 10) { _, _ in 1 }))
        XCTAssertEqual(buffer.window().segmentStarts, [4], "older breaks scrolled out")
        let m = LivePreviewModel(window: buffer.window(), labels: [], columns: 20, height: 1)
        XCTAssertEqual(m.breakColumns, [4])
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

    func testRecordGate_diskBelowTheStopThreshold_andStartFailuresInPlainWords() {
        XCTAssertEqual(RecordGate.disabledReason(state: .streaming, source: .synthetic, board: daisy, configuration: nil,
                                                 map: .withoutPositions, freeBytes: 50_000_000),
                       "Not enough disk space to record: 50 MB free, and recording stops under 100 MB. Free some space first.")
        XCTAssertNil(RecordGate.disabledReason(state: .streaming, source: .synthetic, board: daisy, configuration: nil,
                                               map: .withoutPositions, freeBytes: 500_000_000))
        XCTAssertEqual(RecordGate.startFailed(ProjectStoreError.io("chunks", ENOSPC)), "The recording could not start: the disk is full. Nothing was recorded.")
        XCTAssertEqual(RecordGate.startFailed(ProjectStoreError.io("x", EACCES)),
                       "The recording could not start: this app may not write to the project folder. Nothing was recorded.")
        XCTAssertEqual(LivePreviewModel.fallbackLabel(1), "Channel 2")
        XCTAssertEqual(LiveScreenModel.disconnectQuestion, "Stop recording and disconnect?")
    }

    func testDemo_declaresItsElectrodes_10_10_andSyntheticDeclaresNothing() throws {
        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo())
        let map = try XCTUnwrap(AcquisitionSource.playback(file: csv, loop: true).declaredChannelMap(for: daisy))
        XCTAssertEqual(Array(map.channels.prefix(4).map(\.label)), ["FC3", "FC1", "FC2", "FC4"])
        XCTAssertEqual(map.channels.map(\.sourceRow), daisy.eegChannelRows)
        XCTAssertEqual(map.montage, "international 10-10 (BCI2000 64-ch subset), cropped to 16")
        XCTAssertTrue(map.fits(daisy))
        let layout = MontageLayout(montage: map.montage, reference: map.reference,
                                   channels: map.channels.map { .init(id: $0.id, label: $0.label, unit: $0.unit, kind: $0.kind) })
        XCTAssertEqual(layout.placed.count, 16, "the montage head places every Demo electrode")
        XCTAssertNil(AcquisitionSource.synthetic.declaredChannelMap(for: daisy))
        // A file whose sidecar doesn't name its hash declares nothing.
        let copy = scratch.appendingPathComponent(AcquisitionSource.demoFileName)
        try Data("0\n".utf8).write(to: copy)
        try FileManager.default.copyItem(at: csv.deletingPathExtension().appendingPathExtension("json"),
                                         to: copy.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertNil(AcquisitionSource.playback(file: copy, loop: false).declaredChannelMap(for: daisy))
    }

    func testStopThenImmediateDisconnect_waitsForTheFinish_everySampleCommitted() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("race.bciproj"), name: "race")
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory)
        await session.connect()
        await session.startStreaming()
        let d = try XCTUnwrap(session.snapshot.board)
        let id = try await session.startRecording(.init(map: .defaults(for: d)), in: store)
        try await Task.sleep(for: .seconds(2))
        // Stop and Disconnect (⌘Q right after Stop) race; a second Disconnect races too.
        async let stopped = session.stopRecording()
        async let second: Void = session.disconnect()
        await session.disconnect()
        // Read the disk the moment Disconnect returns: the finish must already be done.
        let handle = try await ProjectStore.open(at: store.directory).recording(id: id)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.segments.map(\.endReason), [.stopped])
        await second
        let stoppedStatus = await stopped
        let status = try XCTUnwrap(stoppedStatus)
        XCTAssertEqual(status.uncommittedSamples, 0)
        XCTAssertEqual(handle.manifest.chunks.reduce(0) { $0 + $1.sampleCount }, status.committedSamples, "every submitted sample committed")
        XCTAssertEqual(session.snapshot.state, .disconnected)
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
        XCTAssertEqual(w.segmentStarts, [])
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
        XCTAssertEqual(Workspace.closeConfirmation(session), .recording)
        try await Task.sleep(for: .seconds(5))
        await live.perform(.stopRecording)
        XCTAssertFalse(live.isRecording)
        XCTAssertNil(Workspace.closeConfirmation(session))
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
        XCTAssertTrue(Workspace.closeNeedsConfirmation(session), "closing asks to stop first")
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

    // MARK: Entry points (6b)

    func testConnectHardware_usesTheMostRecentlyActiveProject() async throws {
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        let a = await workspace.adopt(try ProjectStore.create(at: scratch.appendingPathComponent("a.bciproj"), name: "a"))
        let b = await workspace.adopt(try ProjectStore.create(at: scratch.appendingPathComponent("b.bciproj"), name: "b"))
        XCTAssertNil(workspace.frontmostSession(), "no project window has been active yet")
        workspace.noteActive(a.url)
        workspace.noteActive(b.url)
        XCTAssertTrue(workspace.frontmostSession() === b)
        workspace.noteActive(a.url)
        XCTAssertTrue(workspace.frontmostSession() === a)
        await workspace.close(a.url)
        XCTAssertTrue(workspace.frontmostSession() === b, "a closed window falls back to the previous one")
        await workspace.closeAll()
    }

    func testQuitWithTheSheetOpenMidConnect_dismissesTheSheetAndReleasesTheBoard() async throws {
        let url = scratch.appendingPathComponent("q.bciproj")
        let store = try ProjectStore.create(at: url, name: "q")
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        let session = await workspace.adopt(store)
        let live = session.wire(ConnectController(store: store, projectDirectory: url, demoFile: nil, scan: { [] }))
        session.showsConnectSheet = true
        live.selectedID = ConnectSource.synthetic.id
        let connect = Task { await live.perform(.connect) }
        while live.session == nil { await Task.yield() }
        // What ⌘Q runs: the sheets go, then every project shuts down.
        workspace.dismissSheetsForQuit()
        XCTAssertFalse(session.showsConnectSheet)
        let started = ContinuousClock.now
        await workspace.closeAll()
        await connect.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the quit never hangs")
        XCTAssertTrue(session.isShutDown)
        XCTAssertEqual(live.session?.snapshot.state, .disconnected, "the board opened mid-connect is released")
    }

    func testNewRecordingWhileRecording_showsTheLiveScreen_notTheSheet() async throws {
        let (workspace, session, live, _) = try await liveProject()
        await live.perform(.startPreview)
        live.recordWithoutPositions()
        await live.perform(.record)
        session.liveShown = false
        session.section = .results
        session.showConnectSheet()
        XCTAssertFalse(session.showsConnectSheet)
        XCTAssertTrue(session.liveShown)
        XCTAssertEqual(session.section, .recordings)
        XCTAssertTrue(session.live === live)
        await workspace.closeAll()
    }
}
