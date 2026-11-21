import Synchronization
import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 6: `LiveInferenceRunner` on the synthetic board, the Demo playback and a
/// fault-injecting fake board, with the real worker; and `FeedbackPolicy`'s rules.
///
/// The model is the tiny fixture's frozen fit (8 channels) with its rate set to the
/// stream's: the arrays are a real, validated model, so the plumbing, validity states and
/// logs are exercised end to end; what its scores mean on another signal is not tested here.
@MainActor
final class LiveInferenceRunnerTests: XCTestCase {
    private var scratch: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: scratch.appendingPathComponent("tiny.bciproj"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func launch() throws -> WorkerLaunch { try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh") }

    /// The tiny fixture evaluated with a 2 s window (decision #40) and frozen.
    private func frozenModel() async throws -> ModelRecord {
        let ids = try await store.recordingIDs()
        let recording = try XCTUnwrap(ids.first)
        let e = EvaluationRunner(store: store, launch: try launch())
        var request = EvaluationRunner.Request(recordingID: recording, seed: 0)
        request.windowLengthSeconds = 2.0
        let state = await e.evaluateAndWait(request)
        await e.shutdown()
        guard case .done(let id) = state else { throw XCTSkip("evaluation failed: \(state)") }
        let r = ReplayRunner(store: store, launch: try launch())
        defer { Task { await r.shutdown() } }
        return try await r.freeze(result: try await store.result(id: id), role: .reference, name: "Live")
    }

    private func runner(_ model: ModelRecord, board: BoardDescription, session: AcquisitionSession?, writer: LiveRunWriter?,
                        now: @escaping @Sendable () -> Int64 = { HostMonotonicClock.nowNanos() }) async throws -> LiveInferenceRunner {
        var m = model
        m.expectedSampleRateHz = Double(board.samplingRate)
        let config = LiveInferenceRunner.Configuration(model: m, arraysPath: await store.arraysURL(for: model).path,
                                                       channelRows: Array(board.eegChannelRows.prefix(m.expectedChannelIDs.count)),
                                                       channelIDs: m.expectedChannelIDs, sampleRateHz: Double(board.samplingRate),
                                                       timestampRow: board.timestampRow, markerRow: board.markerRow)
        return LiveInferenceRunner(configuration: config, launch: try launch(), writer: writer, sourceState: { session?.snapshot.state ?? .streaming }, now: now)
    }

    private func liveRun(_ model: ModelRecord) async throws -> LiveRunWriter {
        try await store.createLiveRun(LiveRunRecord(kind: .live, modelID: model.modelID, recordingID: UUID(), runIDs: [], hopSamples: 16,
                                                    abstainThreshold: 0.6, staleLimitMillis: 250, startedAt: Date()))
    }

    /// Plays the participant window: reports every display change as presented now.
    private func surface(_ r: LiveInferenceRunner) -> Task<Void, Never> {
        Task { for await u in r.updates { await r.presented(sequence: u.sequence, display: u.display, at: HostMonotonicClock.nowNanos()) } }
    }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Real sources, real worker

    /// Synthetic and Demo: warm-up first, then valid windows; a cue gets its cue-locked
    /// outcome; every prediction carries its latency stamps; feedback is logged apart.
    private func endToEnd(_ source: AcquisitionSource, name: String) async throws {
        let model = try await frozenModel()
        let session = AcquisitionSession(source: source, projectDirectory: nil)
        await session.connect()
        await session.startStreaming()
        guard session.snapshot.state == .streaming, let board = session.snapshot.board else { return XCTFail("\(name): \(session.snapshot.state)") }
        let writer = try await liveRun(model)
        let r = try await runner(model, board: board, session: session, writer: writer)
        try await r.start(source: session)
        let shown = surface(r)
        try await waitFor("\(name): a valid window") { r.status.validity == .valid || r.status.validity == .stale }
        await r.addCue(trialID: "t1", marker: nil, presentedAt: HostMonotonicClock.nowNanos(), lengthSeconds: 4)
        let stored = try await store.liveRuns().runs.first!.liveRunID
        try await waitFor("\(name): the cue-locked window and the feedback span", timeout: .seconds(15)) {
            let p = (try? await self.store.predictions(liveRun: stored).records) ?? []
            return p.contains { $0.windowKind == "cue_locked" } && p.contains { $0.feedbackEligible == true }
        }
        let (summary, latency) = await r.stop()
        shown.cancel()
        await session.disconnect()

        let preds = try await store.predictions(liveRun: stored).records
        XCTAssertEqual(preds.map(\.sequence), Array(0..<preds.count).map { $0 }, name)
        XCTAssertEqual(preds.first?.validity, .insufficientWindow, "\(name): warm-up comes first")
        let hops = preds.filter { $0.windowKind == "hop" }
        XCTAssertTrue(hops.contains { $0.validity == .valid || $0.validity == .stale }, name)
        XCTAssertTrue(hops.allSatisfy { $0.acquisitionReceiptMonotonicNanos != nil && $0.emittedAtMonotonicNanos != nil && $0.workerComputeNanos != nil }, name)
        XCTAssertTrue(hops.allSatisfy { ($0.emittedAtMonotonicNanos ?? 0) >= ($0.acquisitionReceiptMonotonicNanos ?? .max) }, name)
        XCTAssertTrue(preds.filter { $0.validity != .valid }.allSatisfy { $0.action == .abstain }, name)
        XCTAssertTrue(hops.contains { $0.feedbackEligible == true }, "\(name): windows inside the cue are feedback-eligible")
        XCTAssertNotNil(FeedbackPolicy.trialOutcomes(preds)["t1"], name)
        let feedback = try await store.feedback(liveRun: stored).records
        XCTAssertFalse(feedback.isEmpty, name)
        XCTAssertTrue(feedback.allSatisfy { $0.presentedAtMonotonicNanos != nil }, name)
        XCTAssertTrue(feedback.allSatisfy { f in preds.contains { $0.sequence == f.predictionSequence } }, name)
        XCTAssertEqual(summary.predictions, preds.count)
        let runs = try await store.liveRuns().runs
        let run = try XCTUnwrap(runs.first)
        XCTAssertNotNil(run.endedAt)
        XCTAssertEqual(run.latency, latency)
        let e = try XCTUnwrap(latency.receiptToEmission, name)
        // Reported, not gated: shared runners are noisy (brief 006 Tests).
        print("\(name) latency ms: receipt→emission p50 \(e.p50) p95 \(e.p95) max \(e.max) (n=\(e.count)); "
              + "buffer wait \(latency.bufferWait.map { "p95 \($0.p95)" } ?? "n/a"); "
              + "emission→presentation \(latency.emissionToPresentation.map { "p95 \($0.p95)" } ?? "n/a")")
    }

    func testSyntheticBoard_endToEnd() async throws { try await endToEnd(.synthetic, name: "synthetic") }

    func testDemoPlayback_endToEnd() async throws {
        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo(), "the build phase copies build/demo into Resources/Demo")
        try await endToEnd(.playback(file: csv, loop: true), name: "demo")
    }

    // MARK: Fake board: stall, interruption, killed worker

    func testStallThenInterruptThenKilledWorker_eachStateNamed_recordingContinues() async throws {
        let model = try await frozenModel()
        let link = FakeLink()
        var options = AcquisitionSession.Options()
        options.noSampleTimeout = .seconds(1)
        options.retryInterval = .milliseconds(50)
        options.retryWindow = .seconds(5)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, options: options, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let channels = zip(link.description.eegChannelRows, link.description.eegNames).enumerated().map { i, p in
            ChannelSpec(id: String(format: "ch%02d", i + 1), label: p.1, kind: "eeg", unit: "uV", sourceRow: p.0)
        }
        let recording = try await session.startRecording(.init(channels: channels, reference: "SRB2", montage: "undeclared"), in: store)
        let writer = try await liveRun(model)
        let r = try await runner(model, board: link.description, session: session, writer: writer)
        try await r.start(source: session)
        try await waitFor("predictions") { r.status.predictions > 3 }

        // A stalled stream: stale within the limit, long before the session calls it interrupted.
        link.set { $0.silent = true; $0.prepareFails = true }
        try await waitFor("stale", timeout: .seconds(2)) { r.status.validity == .stale }
        XCTAssertEqual(r.status.display, .hidden(words: "Signal delayed"))
        XCTAssertEqual(session.snapshot.state, .streaming, "the session hasn't called it yet")
        try await waitFor("disconnected") { r.status.validity == .disconnected }
        XCTAssertEqual(r.status.display, .hidden(words: "Board disconnected"))
        // Reconnect: a new segment, so warm-up again before any valid window.
        link.set { $0.silent = false; $0.prepareFails = false }
        try await waitFor("waiting again") { r.status.validity == .insufficientWindow }
        XCTAssertEqual(r.status.display, .hidden(words: "Waiting for enough signal"))

        // Kill the worker mid-run: the bar hides, the state is named, acquisition goes on.
        await r.killWorkerForTesting()
        try await waitFor("worker unavailable", timeout: .seconds(3)) { r.status.validity == .workerUnavailable }
        XCTAssertEqual(r.status.display, .hidden(words: "Analysis stopped"))
        let deliveredAtKill = link.delivered
        try await waitFor("samples after the kill") { link.delivered > deliveredAtKill + 100 }
        XCTAssertEqual(session.snapshot.state, .streaming)
        XCTAssertEqual(session.snapshot.recordingID, recording)
        await r.stop()
        _ = await session.stopRecording()
        await session.disconnect()

        let runs = try await store.liveRuns().runs
        let liveID = try XCTUnwrap(runs.first?.liveRunID)
        let preds = try await store.predictions(liveRun: liveID).records
        for v in [Validity.stale, .disconnected, .workerUnavailable] {
            XCTAssertTrue(preds.contains { $0.validity == v && $0.inputSampleRange == nil }, "\(v) logged as its own record")
        }
        let segments = Set(preds.compactMap { $0.inputSampleRange == nil ? nil : $0.inputSegment })
        XCTAssertGreaterThanOrEqual(segments.count, 2, "the reconnect restarted the worker segment")
        let m = try await store.recording(id: recording).manifest
        XCTAssertGreaterThan(m.chunks.reduce(0) { $0 + $1.sampleCount }, deliveredAtKill - 50, "recording continued past the kill")
    }

    /// A fake clock that puts every emission 300 ms after now: each window is `stale`.
    func testLatePredictions_areStale_withAFakeClock() async throws {
        let model = try await frozenModel()
        let link = FakeLink()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let writer = try await liveRun(model)
        let r = try await runner(model, board: link.description, session: session, writer: writer,
                                 now: { HostMonotonicClock.nowNanos() + 300_000_000 })
        try await r.start(source: session)
        let id = await writer.record.liveRunID
        try await waitFor("frames") { r.status.predictions > 0 }
        await r.addCue(trialID: "late", marker: nil, presentedAt: HostMonotonicClock.nowNanos(), lengthSeconds: 4)
        try await waitFor("a late window and the cue-locked one", timeout: .seconds(12)) {
            let p = (try? await self.store.predictions(liveRun: id).records) ?? []
            return p.contains { $0.validityDetail == "prediction_late" } && p.contains { $0.windowKind == "cue_locked" && $0.trialID == "late" }
        }
        await r.stop()
        await session.disconnect()
        XCTAssertEqual(r.status.validity, .stale)
        XCTAssertEqual(r.status.display, .hidden(words: "Signal delayed"))
        let preds = try await store.predictions(liveRun: id).records
        XCTAssertTrue(preds.contains { $0.validityDetail == "prediction_late" && $0.inputSampleRange != nil }, "past warm-up, late windows are stale")
        XCTAssertFalse(preds.contains { $0.validity == .valid && $0.windowKind == "hop" })
        let outcome = try XCTUnwrap(preds.first { $0.windowKind == "cue_locked" && $0.trialID == "late" })
        XCTAssertNotEqual(outcome.validity, .stale, "lateness never changes a trial's outcome window (decision #41)")
        XCTAssertEqual(outcome.cueSampleMethod, LiveInferenceRunner.estimateMethod)
    }

    func testWrongChannelMap_isRefusedBeforeAnythingRuns() async throws {
        let model = try await frozenModel()
        let link = FakeLink()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, makeBoard: link.factory)
        var m = model
        m.expectedSampleRateHz = 125
        var config = LiveInferenceRunner.Configuration(model: m, arraysPath: await store.arraysURL(for: model).path,
                                                       channelRows: Array(link.description.eegChannelRows.prefix(8)),
                                                       channelIDs: Array(m.expectedChannelIDs.reversed()), sampleRateHz: 125, timestampRow: nil, markerRow: nil)
        config.workerTimeout = .seconds(2)
        let r = LiveInferenceRunner(configuration: config, launch: try launch(), writer: nil, sourceState: { session.snapshot.state })
        do {
            try await r.start { (AsyncStream { $0.finish() }, {}) }
            XCTFail("a reordered map is refused")
        } catch let e as WorkerError {
            XCTAssertEqual(e.code, "channel_mismatch")
        }
    }

    // MARK: Hand-made frames: drops and refused pushes

    /// A hole in the fan-out is logged (`frames_dropped:N`) and restarts the worker segment;
    /// a cue still waiting for its marker gets `cue_lost_frames_dropped`; a non-finite chunk
    /// is `invalid_input` and the cue riding on it `cue_lost_push_refused`.
    func testFrameDropAndRefusedPush_areLogged_andTheirCuesGetOutcomes() async throws {
        let model = try await frozenModel()
        let d = FakeLink().description
        let writer = try await liveRun(model)
        let r = try await runner(model, board: d, session: nil, writer: writer)
        let (frames, sink) = AsyncStream.makeStream(of: AcquisitionSession.InferenceFrame.self)
        try await r.start { (frames, { sink.finish() }) }
        func frame(_ first: Int, poisoned: Bool = false) -> AcquisitionSession.InferenceFrame {
            var values = [Double](repeating: 0, count: 6 * d.numRows)
            for i in 0..<6 {
                for (c, row) in d.eegChannelRows.enumerated() { values[row * 6 + i] = 20 * sin(Double(first + i) * (0.21 + 0.03 * Double(c))) }
            }
            if poisoned { values[d.eegChannelRows[0] * 6 + 2] = .nan }
            return .init(segment: 0, firstSample: first, chunk: SampleChunk(numRows: d.numRows, count: 6, values: values,
                         drainedAtMonotonicNanos: HostMonotonicClock.nowNanos(), availableBeforeDrain: 6, overflowSuspected: false), gaps: [], clockPair: nil)
        }
        let id = await writer.record.liveRunID
        func preds() async -> [PredictionRecord] { (try? await store.predictions(liveRun: id).records) ?? [] }
        for k in 0..<20 { sink.yield(frame(6 * k)) }
        try await waitFor("hops") { await preds().count > 4 }
        await r.addCue(trialID: "waits", marker: 42, presentedAt: HostMonotonicClock.nowNanos(), lengthSeconds: 4)
        sink.yield(frame(6 * 25))                                   // 30 samples never arrived
        try await waitFor("the drop") { await preds().contains { $0.validityDetail == "frames_dropped:30" } }
        await r.addCue(trialID: "rides", marker: nil, presentedAt: HostMonotonicClock.nowNanos(), lengthSeconds: 4)
        sink.yield(frame(6 * 26, poisoned: true))
        for k in 27..<40 { sink.yield(frame(6 * k)) }
        try await waitFor("the refusal and a new segment") {
            let p = await preds()
            return p.contains { $0.validity == .invalidInput } && Set(p.compactMap { $0.inputSampleRange == nil ? nil : $0.inputSegment }).count == 3
        }
        await r.stop()

        let p = await preds()
        let outcomes = FeedbackPolicy.trialOutcomes(p)
        XCTAssertEqual(outcomes["waits"], .invalid(.insufficientWindow, "cue_lost_frames_dropped"))
        XCTAssertEqual(outcomes["rides"], .invalid(.insufficientWindow, "cue_lost_push_refused"))
        XCTAssertEqual(p.first { $0.validity == .invalidInput }?.validityDetail, "non_finite_samples")
        let segments = p.compactMap { $0.inputSampleRange == nil ? nil : $0.inputSegment }
        XCTAssertEqual(Set(segments).count, 3, "segment 0, after the drop, after the refusal")
    }

    /// Live and replay put a cue on the same sample: a protocol run on the synthetic board,
    /// cues handed to the runner as the run records them (with their markers); each lands on
    /// the marked sample, whose values are the ones the recording's event names.
    func testProtocolRun_liveCuesLandOnTheSampleReplayUses() async throws {
        let model = try await frozenModel()
        let draft = ProtocolDraft(name: "Live cues", classes: ProtocolDraft.grazDefault.classes,
                                  timing: .init(fixationMs: 250, cueMs: 800, restMinMs: 100, restMaxMs: 150),
                                  trialsPerClass: 2, runsPerSession: 3, instructions: "Short test run.")
        let p = try await store.createProtocolVersion(draft, basedOn: nil)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory)
        await session.connect()
        await session.startStreaming()
        let d = try XCTUnwrap(session.snapshot.board)
        let r = try await runner(model, board: d, session: session, writer: nil)
        try await r.start(source: session)
        // The test's own fan-out subscriber keeps every drained chunk by stream sample.
        let (consumer, frames) = session.inferenceFrames(buffer: 4096)
        let seen = Task.detached {
            var all: [AcquisitionSession.InferenceFrame] = []
            for await f in frames { all.append(f) }
            return all
        }
        let channels = d.eegChannelRows.enumerated().map { ChannelSpec(id: String(format: "ch%02d", $0 + 1), label: "undeclared", kind: "eeg", unit: "uV", sourceRow: $1) }
        let host = LiveCueHost(base: AcquisitionRunHost(session: session, request: .init(channels: channels, reference: "SRB2", montage: "undeclared"), store: store),
                               runner: r, cueLabels: Set(p.classes.map(\.label)), cueSeconds: 0.8)
        var o = ProtocolRunner.Options()
        o.startLead = 600_000_000
        let run = ProtocolRunner(protocol: p, runID: "run01", sessionID: "S", runIndex: 0, sessionSeed: 7, host: host,
                                 display: TimedDisplay(), store: store, options: o)
        run.begin()
        _ = await run.run()
        try await Task.sleep(for: .milliseconds(300))
        let recordingID = try XCTUnwrap(session.snapshot.recordingID)
        _ = await session.stopRecording()
        session.removeInferenceConsumer(consumer)
        let stream = await seen.value
        await r.stop()
        await session.disconnect()

        let rec = try await store.recording(id: recordingID)
        let cues = try rec.events().filter { p.classes.map(\.label).contains($0.label) }
        XCTAssertEqual(cues.count, 4)
        let placements = r.placements
        for cue in cues {
            let trial = try XCTUnwrap(cue.trialID)
            let a = try XCTUnwrap(cue.sampleAssociation, trial)
            XCTAssertEqual(a.method, "brainflow_marker", trial)
            let live = try XCTUnwrap(placements[trial], trial)
            XCTAssertEqual(live.method, LiveInferenceRunner.markerMethod, trial)
            // The recorded values at the event's sample are the stream's at the live sample.
            let entry = try XCTUnwrap(rec.chunks(inSegment: a.segment).first { (($0.firstSampleIndex)..<($0.firstSampleIndex + $0.sampleCount)).contains(a.sampleIndex) })
            let values = try rec.chunk(entry)
            let f = try XCTUnwrap(stream.first { $0.segment == live.streamSegment && ($0.firstSample..<($0.firstSample + $0.chunk.count)).contains(live.streamSample) })
            let j = live.streamSample - f.firstSample
            for ch in rec.manifest.channels {
                XCTAssertEqual(values[ch.sourceRow * entry.sampleCount + (a.sampleIndex - entry.firstSampleIndex)], f.chunk.row(ch.sourceRow)[f.chunk.row(ch.sourceRow).startIndex + j], "\(trial) \(ch.id)")
            }
            XCTAssertEqual(f.chunk.row(d.markerRow)[f.chunk.row(d.markerRow).startIndex + j], ProtocolRunner.marker(for: cue.label, in: p), trial)
        }
    }

    // MARK: FeedbackPolicy

    func testFeedbackPolicy() {
        let policy = FeedbackPolicy()
        XCTAssertEqual(policy.threshold, 0.6)
        for bad in [0.49, 1.0, .nan] { XCTAssertThrowsError(try FeedbackPolicy(threshold: bad), "\(bad)") }
        XCTAssertThrowsError(try FeedbackPolicy(threshold: 0.7, staleLimitMillis: 0))
        XCTAssertEqual(try FeedbackPolicy(threshold: 0.5).threshold, 0.5)
        XCTAssertEqual(policy.staleLimitMillis, 250)
        func p(_ v: Validity, c: Double? = 0.8, eligible: Bool = true, kind: String = "hop", trial: String? = nil) -> PredictionRecord {
            PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: nil, score: 1, validity: v, emittedAtMonotonicNanos: 0,
                             action: policy.action(validity: v, confidence: c, label: "right"), feedbackPresentedAtMonotonicNanos: nil,
                             confidence: c, windowKind: kind, trialID: trial, feedbackEligible: eligible)
        }
        XCTAssertEqual(policy.display(for: p(.valid)), .bar(side: "right", length: 0.6000000000000001))
        XCTAssertEqual(policy.display(for: p(.valid, c: 0.59)), .hidden(words: "Not confident"))
        XCTAssertEqual(policy.display(for: p(.valid, c: 0.6)).isShown, true, "at the threshold shows")
        XCTAssertEqual(policy.display(for: p(.valid, eligible: false)), .hidden(words: nil), "outside the feedback span: nothing")
        XCTAssertEqual(policy.display(for: p(.insufficientWindow)), .hidden(words: "Waiting for enough signal"))
        XCTAssertEqual(policy.display(for: p(.stale)), .hidden(words: "Signal delayed"))
        XCTAssertEqual(policy.display(for: p(.disconnected)), .hidden(words: "Board disconnected"))
        XCTAssertEqual(policy.display(for: p(.workerUnavailable)), .hidden(words: "Analysis stopped"))
        XCTAssertEqual(policy.action(validity: .stale, confidence: 0.99, label: "right"), .abstain)
        XCTAssertEqual(policy.action(validity: .valid, confidence: .nan, label: "right"), .abstain)
        XCTAssertEqual([0.5, 0.75, 1.0, 1.2, .nan].map(FeedbackPolicy.barLength), [0, 0.5, 1, 1, 0])
        XCTAssertTrue(policy.isLate(receipt: 0, emitted: 250_000_001))
        XCTAssertFalse(policy.isLate(receipt: 0, emitted: 250_000_000))

        // Decision #41: the cue-locked window is the trial's outcome; hop windows are not.
        let outcomes = FeedbackPolicy.trialOutcomes([
            p(.valid, kind: "hop", trial: "a"), p(.valid, kind: "cue_locked", trial: "a"),
            p(.valid, c: 0.55, kind: "cue_locked", trial: "b"), p(.insufficientWindow, kind: "cue_locked", trial: "c"),
        ])
        XCTAssertEqual(outcomes, ["a": .chosen("right"), "b": .abstained, "c": .invalid(.insufficientWindow, nil)])
        XCTAssertEqual(LiveInferenceRunner.percentiles([5, 1, 3, 2, 4]), .init(count: 5, p50: 3, p95: 5, max: 5))
        XCTAssertNil(LiveInferenceRunner.percentiles([]))
    }
}

/// The run's host with the live runner beside it: every cue the run records (with its
/// marker and presentation time) is also handed to the runner, as the live run will.
private struct LiveCueHost: ProtocolRunHost {
    let base: AcquisitionRunHost
    let runner: LiveInferenceRunner
    let cueLabels: Set<String>
    let cueSeconds: Double

    func beginRun(runID: String, sessionID: String) async throws -> UUID { try await base.beginRun(runID: runID, sessionID: sessionID) }
    func endRun() async { await base.endRun() }
    var isStreaming: Bool { base.isStreaming }

    func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool {
        // Queued first, so the runner waits for the marker before the board can write it.
        for e in events where cueLabels.contains(e.label) {
            if let trial = e.trialID, let at = associateAt { await runner.addCue(trialID: trial, marker: marker, presentedAt: at, lengthSeconds: cueSeconds) }
        }
        return await base.record(events, marker: marker, associateAt: associateAt)
    }
}
