import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 7: what the participant window draws (bar only during cues, every change
/// reported once, in order), the operator view's copy, cue routing to the live runner, and
/// a refused start logging its one record.
@MainActor
final class LiveFeedbackViewTests: XCTestCase {
    private let bar = FeedbackPolicy.Display.bar(side: "cue_right_hand", length: 0.4)
    private let notConfident = FeedbackPolicy.Display.hidden(words: "Model unsure")

    // MARK: Participant window

    func testFrameState_drawsNothingBeforeTheFirstPrediction() {
        var s = FeedbackFrameState()
        XCTAssertNil(s.take(cueOnScreen: true))
        XCTAssertNil(s.take(cueOnScreen: false))
    }

    private let ms = Int64(1_000_000)
    private func u(_ seq: Int, _ d: FeedbackPolicy.Display, at e: Int64, reason: String? = nil) -> LiveInferenceRunner.Update {
        .init(sequence: seq, display: d, emittedAt: e, reason: reason)
    }

    func testFrameState_barOnlyWhileACueIsOnScreen_eachChangeOnce() {
        var s = FeedbackFrameState(staleLimitNanos: 250 * ms)
        s.submit(u(3, bar, at: 0))
        // Fixation: nothing, reported once as hidden without words.
        XCTAssertEqual(s.take(cueOnScreen: false, targetNanos: 10 * ms), .init(sequence: 3, display: .hidden(words: nil), reason: "no_cue", measured: true))
        XCTAssertNil(s.take(cueOnScreen: false, targetNanos: 20 * ms), "unchanged: nothing to draw or log")
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 30 * ms), .init(sequence: 3, display: bar, reason: nil, measured: false),
                       "the cue appearing is not a new prediction: logged, not counted as latency")
        XCTAssertNil(s.take(cueOnScreen: true, targetNanos: 40 * ms))
        s.submit(u(4, notConfident, at: 50 * ms, reason: "abstain"))
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 60 * ms), .init(sequence: 4, display: notConfident, reason: "abstain", measured: true))
        XCTAssertEqual(s.take(cueOnScreen: false, targetNanos: 70 * ms)?.display, .hidden(words: nil), "cue over: the words go too")
    }

    /// The stale rule at presentation: a stalled main loop (or display link) never draws an
    /// old bar; the window says "Signal delayed" and logs why.
    func testFrameState_stalledLoopNeverDrawsAnOldBar() async throws {
        var s = FeedbackFrameState(staleLimitNanos: 250 * ms)
        s.submit(u(5, bar, at: 0))
        let late = try XCTUnwrap(s.take(cueOnScreen: true, targetNanos: 900 * ms))
        XCTAssertEqual(late.display, .hidden(words: "Signal delayed"))
        XCTAssertEqual(late.reason, "delayed")
        var t = FeedbackFrameState(staleLimitNanos: 250 * ms)
        t.submit(u(6, bar, at: 0))
        XCTAssertEqual(t.take(cueOnScreen: true, targetNanos: 16 * ms, stall: true)?.reason, "delayed", "a stalled refresh hides even a fresh bar")
        XCTAssertEqual(t.take(cueOnScreen: true, targetNanos: 32 * ms)?.display, bar, "the next on-time refresh shows it")
        XCTAssertEqual(t.take(cueOnScreen: true, targetNanos: nil)?.reason, "delayed", "an unknown refresh time is not trusted")

        // …and the hidden state reaches feedback.jsonl with its reason.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bci-stale-\(UUID().uuidString).bciproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "stale")
        let writer = try await store.createLiveRun(LiveRunRecord(kind: .live, modelID: UUID(), recordingID: UUID(), runIDs: [], hopSamples: 16,
                                                                 abstainThreshold: 0.6, staleLimitMillis: 250, startedAt: Date()))
        let runner = LiveInferenceRunner(configuration: .init(model: Self.model, arraysPath: "/nonexistent", channelRows: [1], channelIDs: ["ch01"],
                                                              sampleRateHz: 125, timestampRow: nil, markerRow: nil),
                                         launch: nil, writer: writer, sourceState: { .streaming })
        await runner.presented(sequence: late.sequence, display: late.display, at: 900 * ms, reason: late.reason, measured: late.measured)
        let id = await writer.record.liveRunID
        let logged = try await store.feedback(liveRun: id).records
        XCTAssertEqual(logged, [FeedbackRecord(predictionSequence: 5, shown: false, side: nil, length: nil, words: "Signal delayed",
                                               presentedAtMonotonicNanos: 900 * ms, reason: "delayed")])
    }

    /// A prediction that arrives while the screen already shows the same thing (fixation) is
    /// not a fresh change when the cue later draws it: logged, not counted as latency.
    func testFrameState_aPredictionThatArrivedDuringNoCueIsNotFresh() {
        var s = FeedbackFrameState(staleLimitNanos: 250 * ms)
        s.submit(u(3, bar, at: 0))
        XCTAssertEqual(s.take(cueOnScreen: false, targetNanos: 10 * ms)?.measured, true)
        s.submit(u(4, bar, at: 20 * ms))
        XCTAssertNil(s.take(cueOnScreen: false, targetNanos: 30 * ms))
        XCTAssertEqual(s.drawn?.sequence, 4, "the screen is unchanged, but 4 is now behind it")
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 40 * ms), .init(sequence: 4, display: bar, reason: nil, measured: false))
        s.submit(u(5, notConfident, at: 50 * ms, reason: "abstain"))
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 60 * ms)?.measured, true, "a new prediction changing the screen still counts")
    }

    func testFeed_finishEndsWithOneStoppedRecord() async {
        let feed = FeedbackFeed(directions: [:])
        feed.submit(u(1, bar, at: 90))
        feed.presented(feed.take(cueOnScreen: true, targetNanos: 100)!, at: 100)
        feed.submit(u(1, .hidden(words: nil), at: 110, reason: "stopped"))          // the runner's last update
        feed.finish()
        feed.presented(.init(sequence: 1, display: bar, reason: nil, measured: true), at: 120)   // after finish: dropped
        var got: [FeedbackFeed.Report] = []
        for await r in feed.reports { got.append(r) }
        XCTAssertEqual(got, [.init(sequence: 1, display: bar, presentedAt: 100, reason: nil, measured: true),
                             .init(sequence: 1, display: .hidden(words: nil), presentedAt: nil, reason: "stopped", measured: false)],
                       "no frame showed the stop: logged without a guessed time")

        // A window that drew the stop itself: no second record.
        let drawn = FeedbackFeed(directions: [:])
        drawn.submit(u(2, bar, at: 0))
        drawn.presented(drawn.take(cueOnScreen: true, targetNanos: 10)!, at: 10)
        drawn.submit(u(2, .hidden(words: nil), at: 20, reason: "stopped"))
        drawn.presented(drawn.take(cueOnScreen: true, targetNanos: 30)!, at: 30)
        drawn.finish()
        var reasons: [String?] = []
        for await r in drawn.reports { reasons.append(r.reason) }
        XCTAssertEqual(reasons, [nil, "stopped"])
    }

    /// The operator's bar follows the participant's stale rule: too old at `now`, or hidden
    /// by a stall in the participant window, it reads "Signal delayed".
    func testMirror_followsTheStaleAndStallRule() {
        var s = FeedbackFrameState(staleLimitNanos: 250 * ms)
        XCTAssertNil(s.mirror(now: 0))
        s.submit(u(1, bar, at: 0))
        XCTAssertEqual(s.mirror(now: 200 * ms), bar)
        XCTAssertEqual(s.mirror(now: 260 * ms), .hidden(words: "Signal delayed"), "older than 250 ms")
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 10 * ms, stall: true)?.reason, "delayed")
        XCTAssertEqual(s.mirror(now: 10 * ms), .hidden(words: "Signal delayed"), "the participant sees a stall: so does the operator")
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 20 * ms)?.display, bar)
        XCTAssertEqual(s.mirror(now: 20 * ms), bar)
        s.submit(u(2, notConfident, at: 30 * ms, reason: "abstain"))
        XCTAssertEqual(s.mirror(now: 900 * ms), notConfident, "only a bar goes stale; words stay")

        // A stall hid bar 3; bar 4 arrives fresh and isn't drawn yet: no flicker to "delayed".
        var t = FeedbackFrameState(staleLimitNanos: 250 * ms)
        t.submit(u(3, bar, at: 0))
        XCTAssertEqual(t.take(cueOnScreen: true, targetNanos: 10 * ms, stall: true)?.reason, "delayed")
        let newer = FeedbackPolicy.Display.bar(side: "cue_left_hand", length: 0.7)
        t.submit(u(4, newer, at: 20 * ms))
        XCTAssertEqual(t.mirror(now: 25 * ms), newer, "judged by its own age, not the older bar's stall")
    }

    func testPanel_neverShowsABarTheParticipantSeesDelayed_andShowsStopped() {
        var s = LiveInferenceRunner.Status()
        s.validity = .valid; s.display = bar; s.score = 0.9; s.confidence = 0.71
        let delayed = state(s, mirror: .hidden(words: "Signal delayed"))
        XCTAssertNil(delayed.bar)
        XCTAssertEqual(delayed.state, "Signal delayed")
        XCTAssertEqual(delayed.tone, .warning)
        XCTAssertEqual(delayed.detail, LiveTestCopy.delayedDetail)
        XCTAssertTrue(LiveTestCopy.delayedDetail.hasSuffix("."), "a full sentence")
        XCTAssertNil(state(s, mirror: .some(nil)).bar, "no update in the feed yet: a status bar is not trusted")
        s.stopped = true
        let stopped = state(s, mirror: bar)
        XCTAssertEqual(stopped.state, "Stopped")
        XCTAssertNil(stopped.bar)
        XCTAssertEqual(stopped.tone, .info)
    }

    func testPanel_namesLinesMissingFromTheLogs() {
        var s = LiveInferenceRunner.Status()
        XCTAssertNil(panel(s).logWarning)
        s.feedbackWriteFailures = 2; s.predictionWriteFailures = 1
        XCTAssertEqual(panel(s).logWarning, "1 prediction and 2 feedback changes couldn't be written to the logs and are missing from them.")
        XCTAssertEqual(LiveRunCopy.logGaps(predictions: 0, feedback: 1), "1 feedback change couldn't be written to the logs and is missing from them.")
    }

    func testFrameState_neverStepsBackToAnOlderPrediction() {
        var s = FeedbackFrameState()
        s.submit(u(9, notConfident, at: 0))
        s.submit(u(8, bar, at: 0))
        XCTAssertEqual(s.take(cueOnScreen: true, targetNanos: 1)?.sequence, 9)
    }

    func testFeed_reportsLeaveInOrder_withUnknownTimesKept() async {
        let feed = FeedbackFeed(directions: [:])
        feed.submit(u(1, bar, at: 90))
        feed.presented(feed.take(cueOnScreen: true, targetNanos: 100)!, at: 100)
        feed.submit(u(2, notConfident, at: 110, reason: "abstain"))
        feed.presented(feed.take(cueOnScreen: true, targetNanos: 120)!, at: nil)
        feed.finish()
        var got: [FeedbackFeed.Report] = []
        for await r in feed.reports { got.append(r) }
        XCTAssertEqual(got, [.init(sequence: 1, display: bar, presentedAt: 100, reason: nil, measured: true),
                             .init(sequence: 2, display: notConfident, presentedAt: nil, reason: "abstain", measured: true)])
    }

    func testStop_hidesTheBarForGood() async {
        let runner = LiveInferenceRunner(configuration: .init(model: Self.model, arraysPath: "/nonexistent", channelRows: [1], channelIDs: ["ch01"],
                                                              sampleRateHz: 125, timestampRow: nil, markerRow: nil),
                                         launch: nil, writer: nil, sourceState: { .streaming })
        await runner.stop()
        var last: LiveInferenceRunner.Update?
        for await x in runner.updates { last = x }
        XCTAssertEqual(last?.display, .hidden(words: nil))
        XCTAssertEqual(last?.reason, "stopped")
    }

    func testDirections_needOneLeftAndOneRightArrow() {
        let graz = ProtocolDraft.grazDefault.classes
        XCTAssertEqual(FeedbackFeed.directions(classes: graz, modelLabels: ["cue_right_hand", "cue_left_hand"]),
                       ["cue_right_hand": 1, "cue_left_hand": -1], "arrows decide, whatever the LDA order")
        let mixed = [ProtocolClass(label: "a", displayName: "A", cue: .leftArrow), ProtocolClass(label: "b", displayName: "B", cue: .upArrow)]
        XCTAssertNil(FeedbackFeed.directions(classes: mixed, modelLabels: ["a", "b"]), "left + up: no opposite sides, refused")
        let same = [ProtocolClass(label: "a", displayName: "A", cue: .leftArrow), ProtocolClass(label: "b", displayName: "B", cue: .leftArrow)]
        XCTAssertNil(FeedbackFeed.directions(classes: same, modelLabels: ["a", "b"]), "both left: refused")
        XCTAssertNil(FeedbackFeed.directions(classes: graz, modelLabels: ["cue_left_hand", "other"]), "a class the protocol doesn't cue")
    }

    // MARK: Operator view copy

    private func panel(_ s: LiveInferenceRunner.Status, truth: [String: String] = [:], aborted: Set<String> = []) -> LiveFeedbackPanelModel {
        LiveFeedbackPanelModel(s, model: Self.model, protocolRecord: Self.protocolRecord, threshold: 0.6, truth: truth, aborted: aborted)
    }

    /// The 20 Hz state; `mirror` defaults to a fresh copy of the status's display.
    private func state(_ s: LiveInferenceRunner.Status, mirror: FeedbackPolicy.Display?? = nil) -> LiveFeedbackStateModel {
        LiveFeedbackStateModel(s, mirror: mirror ?? s.display, model: Self.model, protocolRecord: Self.protocolRecord,
                               directions: ["cue_left_hand": -1, "cue_right_hand": 1])
    }

    func testPanel_namesEveryStateInWords() {
        XCTAssertEqual(state(.init()).state, "Starting analysis…")
        var s = LiveInferenceRunner.Status()
        s.validity = .valid; s.display = bar; s.score = 0.9; s.confidence = 0.71
        let shown = state(s)
        XCTAssertEqual(shown.state, "Showing feedback")
        XCTAssertEqual(shown.bar, .init(direction: 1, length: 0.4))
        XCTAssertEqual(shown.prediction, "Right hand · model confidence 0.71 · score +0.90")
        XCTAssertEqual(shown.leftEnd, "◀ Left hand")
        XCTAssertEqual(shown.rightEnd, "Right hand ▶")
        s.display = .hidden(words: nil)
        XCTAssertEqual(state(s).state, "Valid · outside the feedback span")
        XCTAssertNil(state(s).bar)
        for (v, words, tone) in [(Validity.stale, "Signal delayed", LiveFeedbackStateModel.Tone.warning), (.disconnected, "Board disconnected", .danger),
                                 (.workerUnavailable, "Analysis stopped", .danger), (.insufficientWindow, "Waiting for enough signal", .info)] {
            s.validity = v; s.detail = "why"; s.display = .hidden(words: FeedbackPolicy.words(v))
            XCTAssertEqual(state(s).state, words)
            XCTAssertEqual(state(s).tone, tone)
            XCTAssertEqual(state(s).detail, "why", "the raw detail stays visible to the operator")
        }
    }

    func testPanel_abstainRateLatencyAndTrialOutcomes() {
        var s = LiveInferenceRunner.Status()
        XCTAssertEqual(panel(s).abstainLine, "No valid windows yet · threshold 0.60")
        XCTAssertEqual(panel(s).latencyLine, "Nothing measured yet")
        s.validHops = 40; s.abstainedHops = 9
        s.receiptToEmission = .init(count: 40, p50: 6.24, p95: 31.6, max: 48.2)
        s.outcomes = ["run01-t01": .chosen("cue_left_hand"), "run01-t02": .chosen("cue_left_hand"), "run01-t03": .abstained,
                      "run01-t04": .invalid(.stale, "prediction_late")]
        let m = panel(s, truth: ["run01-t01": "cue_left_hand", "run01-t02": "cue_right_hand", "run01-t03": "cue_left_hand",
                                 "run01-t04": "cue_right_hand", "run01-t05": "cue_left_hand", "run01-t06": "cue_right_hand"],
                      aborted: ["run01-t06"])
        XCTAssertEqual(m.abstainValue, "23 %")
        XCTAssertEqual(m.abstainLine, "of 40 valid windows were below the threshold of 0.60")
        XCTAssertEqual(m.latencyValue, "6.2 ms / 32 ms")
        XCTAssertEqual(m.latencyLine, "p50 / p95 receipt → prediction, max 48 ms (n = 40)")
        XCTAssertEqual(m.trials.map(\.outcome), ["Left hand · correct", "Left hand · wrong", "Abstained · model unsure",
                                                 "Invalid · Signal delayed", "Waiting for its window", "Aborted · not counted"])
        XCTAssertEqual(m.trials.map(\.correct), [true, false, nil, nil, nil, nil])
        XCTAssertEqual(m.trialsSummary, "4 of 6 trials decided: 1 correct, 1 wrong, 1 abstained, 1 invalid")
    }

    func testCopy_saysModelConfidence_neverIntentOrProbabilityClaims() {
        let all = [LiveTestCopy.confidenceNote, LiveTestCopy.latencyNote, LiveTestCopy.trialsNote, LiveTestCopy.previewPlaceholder]
        XCTAssertTrue(LiveTestCopy.confidenceNote.contains("not calibrated"))
        XCTAssertTrue(LiveTestCopy.confidenceNote.contains("not a probability of intent"))
        XCTAssertTrue(LiveTestCopy.latencyNote.contains("not measured"))
        for line in all { XCTAssertFalse(line.lowercased().contains("detects intent") || line.lowercased().contains("reads your mind"), line) }
    }

    // MARK: Cues reach the runner before their marker

    func testCueHost_givesTheRunnerEachCueBeforeTheHostRecordsIt() async throws {
        let model = Self.model
        let config = LiveInferenceRunner.Configuration(model: model, arraysPath: "/nonexistent", channelRows: [1], channelIDs: ["ch01"],
                                                       sampleRateHz: 125, timestampRow: nil, markerRow: nil)
        // No worker and no stream: the cue can't be placed, so it gets its outcome record at once.
        let runner = LiveInferenceRunner(configuration: config, launch: nil, writer: nil, sourceState: { .streaming })
        let inner = RecordingHost(runner: runner)
        let seen = Seen()
        let host = LiveCueHost(inner: inner, runner: runner, classLabels: ["cue_left_hand", "cue_right_hand"], cueSeconds: 4) { seen.add($0) }
        let cue = EventRecord(eventID: UUID(), sessionID: "s", runID: "run01", trialID: "run01-t01", label: "cue_left_hand", origin: "protocol",
                              intendedAtMonotonicNanos: 1, presentedAtMonotonicNanos: 2, sourceTimeNanos: nil, wallTime: Date(),
                              sampleAssociation: nil, timingUncertaintyNanos: nil)
        var fixation = cue
        fixation.label = "fixation"
        let first = await host.record([fixation], marker: 1, associateAt: 2)
        let second = await host.record([cue], marker: 10, associateAt: 2)
        XCTAssertTrue(first && second)
        XCTAssertEqual(inner.outcomesAtRecord, [0, 1], "the cue reached the runner before the host recorded (and marked) it")
        XCTAssertEqual(runner.status.outcomes["run01-t01"], .invalid(.insufficientWindow, "cue_lost_no_stream"))
        XCTAssertEqual(seen.labels, ["fixation", "cue_left_hand"])
        // A cue the window never reported: no guessed time, the trial is flagged.
        var unseen = cue
        unseen.trialID = "run01-t02"
        unseen.presentedAtMonotonicNanos = nil
        _ = await host.record([unseen], marker: nil, associateAt: 5)
        XCTAssertEqual(runner.status.outcomes["run01-t02"], .invalid(.insufficientWindow, "cue_not_presented"))
    }

    private final class Seen: @unchecked Sendable {
        private(set) var labels: [String] = []
        func add(_ events: [EventRecord]) { labels += events.map(\.label) }
    }

    private final class RecordingHost: ProtocolRunHost, @unchecked Sendable {
        let runner: LiveInferenceRunner
        var outcomesAtRecord: [Int] = []
        init(runner: LiveInferenceRunner) { self.runner = runner }
        func beginRun(runID: String, sessionID: String) async throws -> UUID { UUID() }
        func endRun() async {}
        func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool {
            outcomesAtRecord.append(runner.status.outcomes.count)
            return true
        }
        var isStreaming: Bool { true }
    }

    // MARK: A refused start

    func testStart_withAModelOfAnotherRate_isRefused_andLogsItsOneRecord() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-livefb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: scratch.appendingPathComponent("tiny.bciproj"))
        let launch = try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
        let e = EvaluationRunner(store: store, launch: launch)
        let ids = try await store.recordingIDs()
        var request = EvaluationRunner.Request(recordingID: try XCTUnwrap(ids.first), seed: 0)
        request.windowLengthSeconds = 2
        let state = await e.evaluateAndWait(request)
        await e.shutdown()
        guard case .done(let id) = state else { throw XCTSkip("evaluation failed: \(state)") }
        let replay = ReplayRunner(store: store, launch: launch)
        let model = try await replay.freeze(result: try await store.result(id: id), role: .reference, name: "Tiny")
        await replay.shutdown()

        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil)
        await session.connect()
        await session.startStreaming()
        defer { Task { await session.disconnect() } }
        let board = try XCTUnwrap(session.snapshot.board)
        let channels = zip(board.eegChannelRows, board.eegNames).enumerated().map { i, p in
            ChannelSpec(id: model.expectedChannelIDs[safe: i] ?? "x\(i)", label: p.1, kind: "eeg", unit: "uV", sourceRow: p.0)
        }
        var rec = AcquisitionSession.RecordingRequest(channels: channels, reference: "SRB2", montage: "undeclared")
        rec.recordingID = UUID()
        do {
            let classes = [ProtocolClass(label: model.classLabels[0], displayName: "L", cue: .leftArrow),
                           ProtocolClass(label: model.classLabels[1], displayName: "R", cue: .rightArrow)]
            var draft = ProtocolDraft.grazDefault
            draft.classes = classes
            _ = try await LiveFeedbackController.start(model: model, protocolRecord: ProtocolRecord(draft: draft, parent: nil), policy: FeedbackPolicy(), store: store,
                                                       launch: launch, session: session, board: board, request: rec)
            XCTFail("a model at another rate must be refused")
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, "channel_mismatch")
        }
        let runs = try await store.liveRuns().runs
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.recordingID, rec.recordingID)
        XCTAssertNotNil(run.endedAt)
        let preds = try await store.predictions(liveRun: run.liveRunID).records
        XCTAssertEqual(preds.map(\.validity), [.channelMismatch], "one record, before anything ran")
    }

    // MARK: Fixtures

    static let protocolRecord = ProtocolRecord(draft: .grazDefault, parent: nil)

    static let model = ModelRecord(
        modelID: UUID(), name: "Live", sourcePipelineID: UUID(), sourceResultID: UUID(), sourceRecordingID: UUID(), role: .reference,
        recipe: "csp_rlda_v1", featureKind: "csp_logvar", expectedChannelIDs: ["ch01"], expectedSampleRateHz: 125,
        bandpass: .init(lowHz: 8, highHz: 30, order: 4), window: .init(offsetSeconds: 0.5, lengthSeconds: 2), warmupSamples: 100,
        classLabels: ["cue_left_hand", "cue_right_hand"], trainingRunIDs: ["run01"], trainingSessionIDs: ["s"], fittedSHA256: String(repeating: "0", count: 64),
        configHash: "x", workerVersions: [:], frozenAt: Date(timeIntervalSince1970: 0))
}
