import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 8: a live run end to end on the Demo playback source with the real worker
/// (the live-vs-replay check must agree), and the live-run card's evidence, interval,
/// replay check and setup rules.
@MainActor
final class LiveRunTests: XCTestCase {

    // MARK: End to end

    /// Bundled example → 2 s evaluation → frozen model; Demo stream; two cued runs with live
    /// inference (recorded samples only); Finish; replay through the same model; compare.
    /// The model's rate is set to the stream's (125 Hz): the arrays are a real, validated
    /// model, so the whole path runs; what its scores mean on resampled EEG is not tested.
    func testLiveRunOnDemo_replayCheckAgrees_andTheCardReadsIt() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-liverun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let example = try XCTUnwrap(BundledExample.locate(in: .main))
        let store = try ProjectStore.importBundledExample(from: example, into: scratch.appendingPathComponent("ex.bciproj"))
        let launch = try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
        let e = EvaluationRunner(store: store, launch: launch)
        let ids = try await store.recordingIDs()
        var request = EvaluationRunner.Request(recordingID: try XCTUnwrap(ids.first), seed: 0)
        request.windowLengthSeconds = 2
        let state = await e.evaluateAndWait(request)
        await e.shutdown()
        guard case .done(let resultID) = state else { return XCTFail("evaluation failed: \(state)") }
        let replayer = ReplayRunner(store: store, launch: launch)
        let stored = try await replayer.freeze(result: try await store.result(id: resultID), role: .reference, name: "Example")

        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo(), "the build phase copies build/demo into Resources/Demo")
        let session = AcquisitionSession(source: .playback(file: csv, loop: true), projectDirectory: store.directory)
        await session.connect()
        await session.startStreaming()
        let board = try XCTUnwrap(session.snapshot.board)
        var model = stored
        model.expectedSampleRateHz = Double(board.samplingRate)
        let channels = zip(model.expectedChannelIDs, board.eegChannelRows).map { ChannelSpec(id: $0, label: $0, kind: "eeg", unit: "uV", sourceRow: $1) }
        var rec = AcquisitionSession.RecordingRequest(channels: channels, reference: "SRB2", montage: "undeclared")
        rec.recordingID = UUID()
        // The protocol cues the model's own classes, so live and stored outcomes line up.
        let classes = [ProtocolClass(label: model.classLabels[0], displayName: "Left", cue: .leftArrow),
                       ProtocolClass(label: model.classLabels[1], displayName: "Right", cue: .rightArrow)]
        let p = try await store.createProtocolVersion(ProtocolDraft(name: "Live e2e", classes: classes,
                                                                    timing: .init(fixationMs: 300, cueMs: 2700, restMinMs: 200, restMaxMs: 300),
                                                                    trialsPerClass: 2, runsPerSession: 2, instructions: "Test."), basedOn: nil)
        let live = try await LiveFeedbackController.start(model: model, protocolRecord: p, policy: try FeedbackPolicy(threshold: 0.6), store: store,
                                                          launch: launch, session: session, board: board, request: rec)
        let host = live.host(wrapping: AcquisitionRunHost(session: session, request: rec, store: store))
        var o = ProtocolRunner.Options()
        o.startLead = 400_000_000
        for (i, runID) in ["run01", "run02"].enumerated() {
            let run = ProtocolRunner(protocol: p, runID: runID, sessionID: "live-session", runIndex: i, sessionSeed: 3, host: host,
                                     display: TimedDisplay(), store: store, options: o)
            run.begin()
            let end = await run.run()
            XCTAssertEqual(end.state, .ended(aborted: false), runID)
            try await Task.sleep(for: .milliseconds(400))       // between runs: nothing recorded, nothing pushed
        }
        XCTAssertEqual(session.snapshot.recordingID, rec.recordingID, "the recording got the id the live run named")
        _ = await session.stopRecording()
        await live.stop { m, recording, threshold, cue in
            let s = await replayer.replay(model: m, recordingID: recording, abstainThreshold: threshold, cueLengthSeconds: cue)
            guard case .done(let id) = s else { return .failure(.init(reason: "\(s)")) }
            return .success((try? await store.predictions(liveRun: id).records) ?? [])
        }
        await replayer.shutdown()
        await session.disconnect()

        XCTAssertEqual(live.phase, .ended)
        XCTAssertNil(live.checkProblem)
        let check = try XCTUnwrap(live.replayCheck)
        XCTAssertGreaterThan(check.windowsCompared, 50)
        XCTAssertEqual(check.windowsMatched, check.windowsCompared, "live matched replay; differing: \(check.differingSequences)")
        let runs = try await store.liveRuns().runs
        let run = try XCTUnwrap(runs.first { $0.kind == .live })
        XCTAssertEqual(run.replayCheck, check)
        XCTAssertEqual(run.runIDs, ["run01", "run02"])
        XCTAssertEqual(run.abstainThreshold, 0.6)
        XCTAssertNotNil(run.endedAt)
        let preds = try await store.predictions(liveRun: run.liveRunID).records
        XCTAssertEqual(Set(preds.compactMap { $0.inputSampleRange == nil ? nil : $0.inputSegment }), [0, 1], "one worker segment per recorded run")
        XCTAssertEqual(live.truth.count, 8)
        XCTAssertEqual(preds.filter { $0.windowKind == "cue_locked" }.count, 8, "one cue-locked window per trial")
        print("live e2e latency: \(run.latency.map { "\($0)" } ?? "none")")

        // The card, from what the store holds.
        let frozen = FrozenModelsController(store: store, launch: nil)
        await frozen.reload()
        await frozen.loadInputs(run)
        let inputs = try XCTUnwrap(frozen.liveInputs[run.liveRunID])
        XCTAssertEqual(inputs.truth.count, 8)
        XCTAssertEqual(inputs.sessions, ["live-session", "live-session"])
        XCTAssertNotNil(inputs.offline)
        let card = LiveRunCardModel(run: run, model: stored, inputs: inputs, name: ClassDisplay.name)
        XCTAssertTrue(card.replayLine.hasPrefix("Live matched replay: \(check.windowsMatched) of \(check.windowsCompared) windows"))
        XCTAssertTrue(card.comparison.contains("held-out result: balanced accuracy"))
        XCTAssertTrue(["cross-session", "unknown-session"].contains(card.evidence))
    }

    // MARK: Clopper-Pearson

    func testClopperPearson_matchesTheWorker() throws {
        // scipy.stats.beta.ppf values (the worker's clopper_pearson).
        let a = try XCTUnwrap(ClopperPearson.interval(successes: 7, trials: 10))
        XCTAssertEqual(a.lowerBound, 0.34754, accuracy: 1e-4)
        XCTAssertEqual(a.upperBound, 0.93326, accuracy: 1e-4)
        let b = try XCTUnwrap(ClopperPearson.interval(successes: 0, trials: 5))
        XCTAssertEqual(b.lowerBound, 0)
        XCTAssertEqual(b.upperBound, 0.52182, accuracy: 1e-4)
        let c = try XCTUnwrap(ClopperPearson.interval(successes: 8, trials: 8))
        XCTAssertEqual(c.lowerBound, 0.63058, accuracy: 1e-4)
        XCTAssertEqual(c.upperBound, 1)
        XCTAssertNil(ClopperPearson.interval(successes: 3, trials: 0))
        XCTAssertNil(ClopperPearson.interval(successes: 4, trials: 3), "hostile counts never trap")
    }

    // MARK: Live vs replay

    private func pred(_ seq: Int, stop: Int, score: Double?, validity: Validity = .valid, detail: String? = nil, segment: Int = 0) -> PredictionRecord {
        PredictionRecord(pipelineID: UUID(), inputSegment: segment, inputSampleRange: .init(start: stop - 250, count: 250), score: score, validity: validity,
                         emittedAtMonotonicNanos: nil, action: .abstain, feedbackPresentedAtMonotonicNanos: nil, sequence: seq,
                         validityDetail: detail, windowKind: "hop")
    }

    func testReplayCheck_withinToleranceMatches_elseListed() {
        let replay = [pred(0, stop: 300, score: 0.5), pred(1, stop: 316, score: -0.2), pred(2, stop: 332, score: nil, validity: .insufficientWindow),
                      pred(3, stop: 348, score: 1.0)]
        var condition = pred(9, stop: 0, score: nil, validity: .stale)
        condition.inputSampleRange = nil
        let live = [pred(0, stop: 300, score: 0.5 + 5e-9),                              // within 1e-8
                    pred(1, stop: 316, score: -0.2, validity: .stale, detail: "prediction_late"),  // late: compared as scored
                    pred(2, stop: 332, score: nil, validity: .insufficientWindow),
                    pred(3, stop: 348, score: 1.0 + 1e-6),                              // outside
                    pred(4, stop: 364, score: 0.1),                                     // no replay window
                    condition]
        let c = LiveReplayCheck.compare(live: live, replay: replay)
        XCTAssertEqual(c.windowsCompared, 5, "condition records score nothing")
        XCTAssertEqual(c.windowsMatched, 3)
        XCTAssertEqual(c.differingSequences, [3, 4])
        XCTAssertEqual(LiveReplayCheck.compare(live: [pred(0, stop: 300, score: 0.5, segment: 1)], replay: replay).windowsMatched, 0, "segments must agree")
    }

    // MARK: The card

    private static let model = LiveFeedbackViewTests.model

    private func run(check: LiveRunRecord.ReplayCheck? = .init(windowsCompared: 120, windowsMatched: 120, differingSequences: []),
                     ended: Bool = true) -> LiveRunRecord {
        LiveRunRecord(kind: .live, modelID: Self.model.modelID, recordingID: UUID(), runIDs: ["run01"], hopSamples: 16, abstainThreshold: 0.6,
                      staleLimitMillis: 250, startedAt: Date(timeIntervalSince1970: 0), endedAt: ended ? Date(timeIntervalSince1970: 60) : nil,
                      latency: .init(receiptToEmission: .init(count: 100, p50: 4.2, p95: 12.4, max: 40), bufferWait: nil, emissionToPresentation: nil),
                      replayCheck: check)
    }

    private func cue(_ trial: String, score: Double?, validity: Validity = .valid, abstain: Bool = false, detail: String? = nil) -> PredictionRecord {
        var p = PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: .init(start: 0, count: 250), score: score, validity: validity,
                                 emittedAtMonotonicNanos: nil, action: abstain || score == nil ? .abstain : .chosen(score! > 0 ? "cue_right_hand" : "cue_left_hand"),
                                 feedbackPresentedAtMonotonicNanos: nil, validityDetail: detail, windowKind: "cue_locked", trialID: trial)
        p.confidence = score.map { 1 / (1 + exp(-abs($0))) }
        return p
    }

    private func inputs(sessions: [String?] = ["new"]) -> LiveRunInputs {
        LiveRunInputs(cueLocked: [cue("t1", score: -2), cue("t2", score: 1.5), cue("t3", score: 0.2, abstain: true), cue("t4", score: -0.1, abstain: true),
                                  cue("t5", score: nil, validity: .stale, detail: "prediction_late")],
                      truth: ["t1": "cue_left_hand", "t2": "cue_right_hand", "t3": "cue_left_hand", "t4": "cue_right_hand",
                              "t5": "cue_left_hand", "t6": "cue_right_hand", "t7": "cue_left_hand"],
                      aborted: ["t7"], sessions: sessions,
                      offline: .init(balancedAccuracy: 0.68, accuracy: 0.7, interval: 0.51...0.84, trials: 14, createdAt: Date()))
    }

    func testCard_scoresEveryValidTrial_namesTheRest_andComparesWithOffline() {
        let m = LiveRunCardModel(run: run(), model: Self.model, inputs: inputs(), name: ClassDisplay.name)
        // t1 ✓, t2 ✓, t3 (abstained, favours right, truth left) ✗, t4 (abstained, favours left, truth right) ✗.
        XCTAssertEqual(m.balancedAccuracyValue, "0.50")
        XCTAssertTrue(m.accuracyLine.hasPrefix("Accuracy 0.50 · 95 % CI 0.07–0.93 (trial-level, n = 4)"), m.accuracyLine)
        XCTAssertEqual(m.trialsLine, "n = 4 valid trials in 1 run · 2 below the 0.60 threshold")
        XCTAssertEqual(m.excluded, ["1 trial: Signal delayed (prediction late)", "1 trial: no window was logged", "1 aborted trial not counted"])
        XCTAssertEqual(m.cells.map(\.count), [1, 1, 1, 1])
        XCTAssertEqual(m.comparison, "The frozen model's held-out result: balanced accuracy 0.68 (accuracy 0.70, 95 % CI 0.51–0.84, n = 14).")
        XCTAssertEqual(m.evidence, "cross-session")
        XCTAssertEqual(m.replayLine, "Live matched replay: 120 of 120 windows within tolerance.")
        XCTAssertEqual(m.latency.first?.value, "p50 4.2 ms · p95 12 ms · max 40 ms (n = 100)")
        XCTAssertEqual(m.largerClass?.sentence, "Interval includes the larger-class rate.")
        let all = [m.title, m.accuracyLine, m.trialsLine, m.comparison, m.replayLine, m.evidenceSentence, LiveRunCopy.scoringNote] + m.excluded
        for line in all {
            for banned in ["working", "success", "intent detect", "probability"] { XCTAssertFalse(line.lowercased().contains(banned), "\(banned): \(line)") }
        }
    }

    func testCard_sessionEvidenceAndReplayStates() {
        XCTAssertEqual(LiveRunCardModel(run: run(), model: Self.model, inputs: inputs(sessions: ["s"]), name: { $0 }).evidence, "same-session")
        XCTAssertEqual(LiveRunCardModel(run: run(), model: Self.model, inputs: inputs(sessions: [nil]), name: { $0 }).evidence, "unknown-session")
        let differs = LiveRunCardModel(run: run(check: .init(windowsCompared: 10, windowsMatched: 8, differingSequences: [4, 7])), model: Self.model,
                                       inputs: inputs(), name: { $0 })
        XCTAssertEqual(differs.replayLine, "Live and replay differ in 2 of 10 windows (predictions 4, 7). That is a bug to report, not a result.")
        XCTAssertEqual(differs.replayOK, false)
        XCTAssertEqual(LiveRunCardModel(run: run(check: nil, ended: false), model: Self.model, inputs: inputs(), name: { $0 }).replayLine,
                       "The run ended with the app; it was not replayed.")
        let empty = LiveRunCardModel(run: run(), model: Self.model, inputs: .init(cueLocked: [], truth: [:], aborted: [], sessions: [], offline: nil), name: { $0 })
        XCTAssertEqual(empty.balancedAccuracyValue, "–")
        XCTAssertEqual(empty.accuracyLine, "No valid trials, so no accuracy.")
        XCTAssertEqual(empty.comparison, "The frozen model's held-out result couldn't be read.")
    }

    // MARK: Setup

    func testSetup_thresholdAndMismatchRules() {
        var form = LiveTestForm()
        XCTAssertEqual(form.thresholdText, "0.60", "decision #39 default")
        XCTAssertEqual(try form.policy.get().threshold, 0.6)
        for bad in ["0.4", "1", "abc", "nan"] {
            form.thresholdText = bad
            guard case .failure = form.policy else { return XCTFail(bad) }
        }
        form.thresholdText = " 0.75 "
        XCTAssertEqual(try form.policy.get().threshold, 0.75)
        let m = Self.model
        XCTAssertNil(LiveRunCopy.mismatch(model: m, channelIDs: ["ch01"], rateHz: 125))
        XCTAssertTrue(LiveRunCopy.mismatch(model: m, channelIDs: ["ch01"], rateHz: 250)!.contains("Nothing is resampled"))
        XCTAssertTrue(LiveRunCopy.mismatch(model: m, channelIDs: ["ch02"], rateHz: 125)!.contains("missing ch01"))
        var two = m
        two.expectedChannelIDs = ["a", "b"]
        XCTAssertTrue(LiveRunCopy.mismatch(model: two, channelIDs: ["b", "a"], rateHz: 125)!.contains("another order"))
    }
}
