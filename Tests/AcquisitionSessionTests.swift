import Synchronization
import XCTest
@testable import BCIWorkspace

/// Brief 004 PR 3: the acquisition session on the synthetic board, the playback fixture,
/// and a fault-injecting fake board. No hardware (decision #26).
final class AcquisitionSessionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-acq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func store(_ name: String = "p") throws -> ProjectStore {
        try ProjectStore.create(at: scratch.appendingPathComponent("\(name).bciproj"), name: name)
    }

    private func request(_ d: BoardDescription) -> AcquisitionSession.RecordingRequest {
        let channels = zip(d.eegChannelRows, d.eegNames).enumerated().map { i, pair in
            ChannelSpec(id: String(format: "ch%02d", i + 1), label: pair.1, kind: "eeg", unit: "uV", sourceRow: pair.0)
        }
        return .init(channels: channels, reference: "SRB2", montage: "undeclared")
    }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fastOptions() -> AcquisitionSession.Options {
        var o = AcquisitionSession.Options()
        o.noSampleTimeout = .milliseconds(400)
        o.retryInterval = .milliseconds(50)
        o.retryWindow = .seconds(2)
        return o
    }

    // MARK: Synthetic board

    func testSyntheticBoard_connectStreamRecordStop_manifestChunksAndHealthAgree() async throws {
        let store = try store()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory)
        await session.connect()
        XCTAssertEqual(session.snapshot.state, .ready)
        await session.startStreaming()
        XCTAssertEqual(session.snapshot.state, .streaming)

        let d = try BrainFlowBoard.describe(boardID: KnownBoard.synthetic)
        let id = try await session.startRecording(request(d), in: store)
        XCTAssertTrue(session.snapshot.holdsPowerAssertion, "idle sleep is held off while recording")
        var frames = 0
        for await _ in session.preview { frames += 1; if frames == 3 { break } }
        try await Task.sleep(for: .seconds(5))
        let stopped = await session.stopRecording()
        let status = try XCTUnwrap(stopped)
        XCTAssertFalse(session.snapshot.holdsPowerAssertion)
        let health = session.snapshot.health
        await session.disconnect()
        XCTAssertEqual(session.snapshot.state, .disconnected)

        let handle = try await store.recording(id: id)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.source.kind, "synthetic")
        XCTAssertNil(handle.manifest.source.dataPath)
        XCTAssertEqual(handle.manifest.source.warning, "Synthetic board — generated signal, not a device")
        XCTAssertEqual(handle.manifest.segments.map(\.endReason), [.stopped])
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [])
        let stored = handle.manifest.chunks.reduce(0) { $0 + $1.sampleCount }
        XCTAssertEqual(stored, status.committedSamples)
        XCTAssertEqual(status.uncommittedSamples, 0)
        XCTAssertGreaterThan(stored, 4 * d.samplingRate)
        XCTAssertGreaterThanOrEqual(health.samplesThisSegment, stored - d.samplingRate, "health counts the whole stream segment")
        XCTAssertEqual(try XCTUnwrap(health.effectiveRateHz), Double(d.samplingRate), accuracy: Double(d.samplingRate) * 0.1)
        XCTAssertEqual(health.gaps, [:])
        XCTAssertNotNil(health.drainInterval)
        XCTAssertNotNil(health.timestampInterval)
        XCTAssertNotNil(health.freeBytes)
        XCTAssertGreaterThan(try XCTUnwrap(health.hoursLeft), 0)
    }

    // MARK: Playback fixture (Cyton+Daisy layout, step-2 counters, injected faults)

    func testPlaybackFixture_everyInjectedFaultIsStoredWithItsEvidence() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback_cyton_daisy_faults", withExtension: "csv"))
        let fixture = try String(contentsOf: file, encoding: .ascii).split(separator: "\n").map { $0.split(separator: "\t").map { Double($0)! } }
        let store = try store()
        var options = AcquisitionSession.Options()
        options.noSampleTimeout = .seconds(30)          // the file ends; that is not an interruption here
        let session = AcquisitionSession(source: .playback(file: file, loop: false), projectDirectory: store.directory, options: options)
        await session.connect()
        await session.startStreaming()
        let d = try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)
        let id = try await session.startRecording(request(d), in: store)
        try await waitFor("the whole file") { session.snapshot.health.samplesThisSegment >= fixture.count }
        await session.stopRecording()
        await session.disconnect()

        let handle = try await store.recording(id: id)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.source.kind, "playback")
        XCTAssertEqual(handle.manifest.source.sourceFiles?.map(\.name), ["playback_cyton_daisy_faults.csv"])
        XCTAssertEqual(handle.manifest.timing.sequenceStep, 2)
        // Recording started a drain or two into the stream: find where, by the file's own timestamps.
        let first = try XCTUnwrap(handle.manifest.chunks.first?.firstBrainflowTimestamp)
        let offset = try XCTUnwrap(fixture.firstIndex { $0[d.timestampRow] == first })
        XCTAssertLessThan(offset, 59, "recording must start before the first fault")
        var stored: [[Double]] = []
        for entry in handle.manifest.chunks {
            let data = try handle.chunk(entry)
            stored += (0..<entry.sampleCount).map { i in (0..<entry.rowCount).map { data[$0 * entry.sampleCount + i] } }
        }
        XCTAssertEqual(stored, Array(fixture[offset...]), "every sample as received, timestamps kept")
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [
            .init(afterSampleIndex: 59 - offset, evidence: .sequenceSkip, estimatedMissingSamples: 2, ambiguous: true),
            .init(afterSampleIndex: 99 - offset, evidence: .staleHalf, estimatedMissingSamples: nil, ambiguous: false),
            .init(afterSampleIndex: 139 - offset, evidence: .invalidCounter, estimatedMissingSamples: nil, ambiguous: false),
            .init(afterSampleIndex: 153 - offset, evidence: .sequenceSkip, estimatedMissingSamples: 2, ambiguous: true),
        ])
    }

    func testLoopingPlaybackSlotsIn_andKeepsStreaming() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback_cyton_daisy_faults", withExtension: "csv"))
        let session = AcquisitionSession(source: .playback(file: file, loop: true), projectDirectory: nil)
        await session.connect()
        await session.startStreaming()
        try await waitFor("the loop to restart") { session.snapshot.health.samplesThisSegment > 250 }
        XCTAssertEqual(session.snapshot.state, .streaming, "the restart is a counter jump, not an interruption")
        XCTAssertNotNil(session.snapshot.health.gaps[.sequenceSkip])
        await session.disconnect()
    }

    // MARK: Fake board: interruption, reconnect, failure

    func testStopsDelivering_thenDeliversAgain_interruptedThenNewSegment_nothingJoined() async throws {
        let link = FakeLink()
        let store = try store()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: fastOptions(), makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(request(link.description), in: store)
        try await waitFor("samples") { link.delivered > 300 }

        link.set { $0.silent = true; $0.prepareFails = true }
        try await waitFor("interrupted") { if case .interrupted = session.snapshot.state { true } else { false } }
        let before = link.delivered
        link.set { $0.silent = false; $0.prepareFails = false }
        try await waitFor("streaming again") { session.snapshot.state == .streaming }
        try await waitFor("segment 1 samples") { link.delivered > before + 300 }
        let health = session.snapshot.health
        await session.disconnect()

        XCTAssertEqual(health.segment, 1)
        XCTAssertEqual(health.reconnects, 1)
        XCTAssertEqual(health.gaps[.disconnect]?.events, 1)
        let m = try await store.recording(id: id).manifest
        XCTAssertEqual(m.segments.map(\.index), [0, 1])
        XCTAssertEqual(m.segments.map(\.endReason), [.disconnect, .stopped])
        XCTAssertEqual(m.segments.map(\.runID), [m.runID, m.runID], "same recording, same run")
        let seg0 = m.chunks.filter { $0.segment == 0 }.reduce(0) { $0 + $1.sampleCount }
        XCTAssertEqual(m.segments[0].detectedGaps, [.init(afterSampleIndex: seg0 - 1, evidence: .disconnect, estimatedMissingSamples: nil, ambiguous: false)])
        XCTAssertEqual(m.chunks.first { $0.segment == 1 }?.firstSampleIndex, 0, "sample indices restart")
        // Counters jumped across the break (the fake kept counting); reset() means no gap is invented in segment 1.
        XCTAssertEqual(m.segments[1].detectedGaps, [])
    }

    func testReadError_interruptsAtOnce_andReconnects() async throws {
        let link = FakeLink()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, options: fastOptions(), makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        try await waitFor("samples") { link.delivered > 50 }
        link.set { $0.readErrors = 1 }
        try await waitFor("the reconnect") { session.snapshot.health.reconnects == 1 }
        XCTAssertEqual(session.snapshot.state, .streaming)
        XCTAssertEqual(link.boardsMade, 2, "a reconnect is a fresh board session")
        await session.disconnect()
    }

    func testRetriesExhausted_failed_recordingFinishedAsDisconnect_assertionReleased_retryStreams() async throws {
        let link = FakeLink()
        let store = try store()
        var options = fastOptions()
        options.retryWindow = .milliseconds(300)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: options, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(request(link.description), in: store)
        try await waitFor("samples") { link.delivered > 200 }
        link.set { $0.silent = true; $0.prepareFails = true }
        try await waitFor("failed") { if case .failed = session.snapshot.state { true } else { false } }
        guard case .failed(let reason) = session.snapshot.state else { return }
        XCTAssertTrue(reason.contains("Reconnect failed"), reason)
        try await waitFor("the recording to end") { session.snapshot.lastRecordingEnd != nil }
        XCTAssertNil(session.snapshot.recordingID, "nothing records in failed")
        XCTAssertFalse(session.snapshot.holdsPowerAssertion, "the Mac may sleep again")
        XCTAssertEqual(session.snapshot.lastRecordingEnd?.endReason, .disconnect)
        XCTAssertEqual(link.live, 0)

        link.set { $0.silent = false; $0.prepareFails = false }
        await session.reconnect()
        try await waitFor("streaming again") { session.snapshot.state == .streaming }
        XCTAssertNil(session.snapshot.recordingID)
        await session.disconnect()
        let m = try await store.recording(id: id).manifest
        XCTAssertEqual(m.segments.map(\.endReason), [.disconnect])
        XCTAssertEqual(link.live, 0)
    }

    func testArrivalPauseWithContiguousCounters_isReceiptIntervalNotLoss() async throws {
        let link = FakeLink()
        let store = try store()
        var options = fastOptions()
        options.noSampleTimeout = .seconds(5)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: options, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(request(link.description), in: store)
        try await waitFor("samples") { link.delivered > 100 }
        // Jump the drain clock 1.5 s while counters stay contiguous: one arrival pause,
        // independent of real scheduling.
        link.set { $0.clockSkewNanos = 1_500_000_000 }
        try await waitFor("more samples") { link.delivered > 400 }
        let health = session.snapshot.health
        await session.disconnect()
        XCTAssertEqual(health.arrivalPauses, 1)
        XCTAssertNil(health.gaps[.sequenceSkip], "no samples lost by counter")
        let gaps = try await store.recording(id: id).manifest.segments[0].detectedGaps
        XCTAssertEqual(gaps.map(\.evidence), [.receiptInterval])
        XCTAssertNil(gaps.first?.estimatedMissingSamples)
    }

    func testConnectFailure_isFailedWithTheErrorAndWritesNothing() async throws {
        let link = FakeLink()
        link.set { $0.prepareFails = true }
        let store = try store()
        let session = AcquisitionSession(source: .serial(port: "/dev/cu.nothing"), projectDirectory: store.directory, makeBoard: link.factory)
        await session.connect()
        guard case .failed(let reason) = session.snapshot.state else { return XCTFail("\(session.snapshot.state)") }
        XCTAssertTrue(reason.contains("prepare_session"), reason)
        let ids = try await store.recordingIDs()
        XCTAssertEqual(ids, [])
        link.set { $0.prepareFails = false }
        await session.reconnect()          // Retry after a failed connect retries the connect
        XCTAssertEqual(session.snapshot.state, .ready)
        await session.disconnect()
    }

    func testRecordRefusedUnlessStreaming() async throws {
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, makeBoard: FakeLink().factory)
        await session.connect()
        do {
            try await session.startRecording(request(FakeLink().description), in: try store())
            XCTFail("ready is not streaming")
        } catch let error as AcquisitionSession.SessionError {
            XCTAssertEqual(error, .notStreaming)
        }
        await session.disconnect()
    }

    // MARK: Reentrancy

    func testDoubleRetry_runsOneReconnectLoop_noLeakedSession() async throws {
        let link = FakeLink()
        var options = fastOptions()
        options.retryWindow = .milliseconds(200)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, options: options, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        try await waitFor("samples") { link.delivered > 50 }
        link.set { $0.silent = true; $0.prepareFails = true }
        try await waitFor("failed") { if case .failed = session.snapshot.state { true } else { false } }
        link.set { $0.silent = false; $0.prepareFails = false; $0.prepareDelay = .milliseconds(100) }
        async let a: Void = session.reconnect()
        async let b: Void = session.reconnect()
        _ = await (a, b)
        try await waitFor("streaming") { session.snapshot.state == .streaming }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(link.live, 1, "one board session, nothing leaked")
        XCTAssertEqual(session.snapshot.health.reconnects, 1)
        await session.disconnect()
        XCTAssertEqual(link.live, 0)
        XCTAssertEqual(link.value(\.maxLive), 1)
    }

    func testDoubleStart_startsTheStreamOnce_andStaysHealthy() async throws {
        let link = FakeLink()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, options: fastOptions(), makeBoard: link.factory)
        await session.connect()
        link.set { $0.prepareDelay = .milliseconds(100) }    // startStream re-prepares: make it slow
        async let a: Void = session.startStreaming()
        async let b: Void = session.startStreaming()
        _ = await (a, b)
        XCTAssertEqual(session.snapshot.state, .streaming)
        XCTAssertEqual(link.value(\.streamStarts), 1)
        await session.disconnect()
    }

    func testCancelDuringConnecting_releasesThatBoard_andALaterConnectIsClean() async throws {
        let link = FakeLink()
        link.set { $0.prepareDelay = .milliseconds(300) }
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, options: fastOptions(), makeBoard: link.factory)
        let first = Task { await session.connect() }
        try await waitFor("connecting") { session.snapshot.state == .connecting }
        await session.disconnect()
        XCTAssertEqual(session.snapshot.state, .disconnected)
        link.set { $0.prepareDelay = .zero }
        await session.connect()                 // the first prepare is still sleeping
        XCTAssertEqual(session.snapshot.state, .ready)
        await first.value
        XCTAssertEqual(session.snapshot.state, .ready, "the cancelled connect never lands on the new one")
        XCTAssertEqual(link.live, 1, "the cancelled connect released its own board")
        await session.disconnect()
        XCTAssertEqual(link.live, 0)
    }

    func testDisconnectDuringRetrying_endsCleanly() async throws {
        let link = FakeLink()
        let store = try store()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: fastOptions(), makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(request(link.description), in: store)
        try await waitFor("samples") { link.delivered > 100 }
        link.set { $0.silent = true; $0.prepareFails = true }
        try await waitFor("interrupted") { if case .interrupted = session.snapshot.state { true } else { false } }
        await session.disconnect()
        XCTAssertEqual(session.snapshot.state, .disconnected)
        link.set { $0.prepareFails = false; $0.silent = false }
        try await Task.sleep(for: .milliseconds(300))   // longer than a retry interval
        XCTAssertEqual(session.snapshot.state, .disconnected, "no retry survives Disconnect")
        XCTAssertEqual(link.live, 0)
        XCTAssertFalse(session.snapshot.holdsPowerAssertion)
        let m = try await store.recording(id: id).manifest
        XCTAssertEqual(m.segments.map(\.endReason), [.disconnect])
    }

    func testStopRecording_neverReadsBesideTheDrainLoop_noFalseGaps() async throws {
        let link = FakeLink()
        let store = try store()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: fastOptions(), makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        var ids: [UUID] = []
        for _ in 0..<4 {
            ids.append(try await session.startRecording(request(link.description), in: store))
            let target = link.delivered + 60
            try await waitFor("samples") { link.delivered > target }
            await session.stopRecording()
        }
        try await Task.sleep(for: .milliseconds(200))
        let health = session.snapshot.health
        await session.disconnect()
        XCTAssertEqual(health.gaps, [:], "counters were seen in order")
        let counters = link.value(\.counters)
        for id in ids {
            let handle = try await store.recording(id: id)
            XCTAssertEqual(handle.manifest.segments.map(\.endReason), [.stopped])
            XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [])
            // Every recording is one contiguous run of what the board delivered, in order.
            let stored = try handle.manifest.chunks.flatMap { e in try handle.chunk(e)[0..<e.sampleCount].map { Int($0) } }
            let start = try XCTUnwrap(counters.indices.first { counters[$0...].starts(with: stored) }, "recorded counters out of order")
            XCTAssertEqual(Array(counters[start..<(start + stored.count)]), stored)
        }
    }

    // MARK: Health accumulator

    func testHealth_effectiveRateIsCounterDerived_andPausesNeedContiguousCounters() throws {
        let d = try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)
        var h = HealthAccumulator(board: d)
        h.beginSegment(reconnect: false)
        func chunk(_ n: Int, at seconds: Double) -> SampleChunk {
            .init(numRows: d.numRows, count: n, values: Array(repeating: 0, count: n * d.numRows),
                  drainedAtMonotonicNanos: Int64(seconds * 1e9), availableBeforeDrain: n, overflowSuspected: false)
        }
        XCTAssertNil(h.ingest(chunk(125, at: 1), gaps: []))
        XCTAssertNil(h.ingest(chunk(62, at: 1.5), gaps: []))
        XCTAssertNil(h.ingest(chunk(38, at: 2), gaps: [.init(afterSampleIndex: 10, evidence: .sequenceSkip, estimatedMissingSamples: 25, ambiguous: true)]))
        XCTAssertEqual(h.health.effectiveRateHz, 125, "received + counter-evidenced missing per monotonic second")
        // 1.5 s without samples, contiguous counters: an arrival pause, stored as receipt_interval.
        XCTAssertEqual(h.ingest(chunk(187, at: 3.5), gaps: []),
                       .init(afterSampleIndex: -1, evidence: .receiptInterval, estimatedMissingSamples: nil, ambiguous: false))
        // The same pause with a counter jump is a gap, not a pause.
        XCTAssertNil(h.ingest(chunk(10, at: 5), gaps: [.init(afterSampleIndex: -1, evidence: .sequenceSkip, estimatedMissingSamples: 3, ambiguous: true)]))
        XCTAssertEqual(h.health.arrivalPauses, 1)
        XCTAssertEqual(h.health.gaps[.sequenceSkip], .init(events: 2, estimatedMissingSamples: 28, ambiguous: 2))
        XCTAssertEqual(h.health.samplesThisSegment, 422)
        XCTAssertEqual(h.snapshot().drainInterval?.max, 1.5)
        // A stall: empty drains pull the rate down, and to 0 once the window is empty.
        func empty(at seconds: Double) -> SampleChunk {
            .init(numRows: d.numRows, count: 0, values: [], drainedAtMonotonicNanos: Int64(seconds * 1e9), availableBeforeDrain: 0, overflowSuspected: false)
        }
        _ = h.ingest(empty(at: 8), gaps: [])
        let stalled = try XCTUnwrap(h.health.effectiveRateHz)
        XCTAssertLessThan(stalled, 125)
        _ = h.ingest(empty(at: 20), gaps: [])
        XCTAssertEqual(h.health.effectiveRateHz, 0)
        XCTAssertEqual(HealthAccumulator.spread([0.3, 0.1, 0.4, 0.2, 5]), .init(p50: 0.3, p95: 5, max: 5))
    }
}

/// Controls every `FakeBoard` a test's factory makes (one per connect / reconnect attempt).
final class FakeLink: Sendable {
    struct Script {
        var silent = false
        var prepareFails = false
        var prepareDelay: Duration = .zero
        var readErrors = 0
        var counter = 0            // keeps counting across boards: a reconnect's first counter jumps
        var delivered = 0
        var boardsMade = 0
        var streamStarts = 0
        /// Boards prepared and not yet released: more than 1 would mean a leaked session.
        var live = 0
        var maxLive = 0
        /// Added to every drain time: an injectable monotonic clock for pause tests.
        var clockSkewNanos: Int64 = 0
        /// Counters of every delivered sample, in delivery order.
        var counters: [Int] = []
        /// Every `configure` command, and the reply to `?` (nil: echo like the synthetic board).
        var commands: [String] = []
        var registerReply: String?
    }
    let script = Mutex(Script())
    let description = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    func set(_ change: (inout Script) -> Void) { script.withLock { change(&$0) } }
    func value<T>(_ read: (Script) -> T) -> T { script.withLock { read($0) } }
    var delivered: Int { value(\.delivered) }
    var boardsMade: Int { value(\.boardsMade) }
    var live: Int { value(\.live) }

    var factory: @Sendable () throws -> any AcquisitionBoard {
        { [self] in
            script.withLock { $0.boardsMade += 1 }
            return FakeBoard(link: self)
        }
    }
}

/// Delivers 6 samples per read (≈ 125 Hz at a 50 ms drain) with step-2 counters, or
/// nothing while `silent`, or throws while `readErrors` > 0.
actor FakeBoard: AcquisitionBoard {
    nonisolated let description: BoardDescription
    private let link: FakeLink
    private var prepared = false

    init(link: FakeLink) { self.link = link; description = link.description }

    func prepare() async throws {
        let delay = link.value(\.prepareDelay)
        if delay > .zero { try? await Task.sleep(for: delay) }
        if link.value(\.prepareFails) {
            throw BrainFlowError(code: BrainFlowExitCode.boardNotReady.rawValue, operation: "prepare_session")
        }
        guard !prepared else { return }
        prepared = true
        link.set { $0.live += 1; $0.maxLive = max($0.maxLive, $0.live) }
    }

    func startStream(bufferSize: Int32) async throws {
        try await prepare()
        link.set { $0.streamStarts += 1 }
    }

    func configure(_ command: String) throws -> String {
        try link.script.withLock { s in
            if s.prepareFails { throw BrainFlowError(code: BrainFlowExitCode.boardNotReady.rawValue, operation: "config_board") }
            s.commands.append(command)
            return command == "?" ? (s.registerReply ?? "Config:?") : "Success: Channel set$$$"
        }
    }

    func readAll() throws -> SampleChunk {
        let d = description
        let (first, skew) = try link.script.withLock { s -> (Int?, Int64) in
            if s.readErrors > 0 {
                s.readErrors -= 1
                throw BrainFlowError(code: BrainFlowExitCode.generalError.rawValue, operation: "get_board_data")
            }
            guard !s.silent else { return (nil, s.clockSkewNanos) }
            defer { s.counters += (s.counter..<(s.counter + 6)).map { ($0 * 2) % 256 }; s.counter += 6; s.delivered += 6 }
            return (s.counter, s.clockSkewNanos)
        }
        let n = first == nil ? 0 : 6
        var values = [Double](repeating: 0, count: n * d.numRows)
        for i in 0..<n {
            let k = first! + i
            values[d.packageNumRow * n + i] = Double((k * 2) % 256)
            values[d.timestampRow * n + i] = 1_700_000_000 + Double(k) / 125
            for r in d.eegChannelRows { values[r * n + i] = Double(k % 50) }
        }
        return SampleChunk(numRows: d.numRows, count: n, values: values, drainedAtMonotonicNanos: HostMonotonicClock.nowNanos() + skew,
                           availableBeforeDrain: n, overflowSuspected: false)
    }

    func release() {
        guard prepared else { return }
        prepared = false
        link.set { $0.live -= 1 }
    }
}
