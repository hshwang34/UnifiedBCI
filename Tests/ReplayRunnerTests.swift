import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 4: freeze → replay on the tiny fixture with the real worker, the live
/// wrappers, and the freeze / parity / error copy.
@MainActor
final class ReplayRunnerTests: XCTestCase {
    private var scratch: URL!
    private var store: ProjectStore!
    private var recordingID: UUID!
    private var runners: [ReplayRunner] = []
    private var evaluators: [EvaluationRunner] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: scratch.appendingPathComponent("tiny.bciproj"))
        let ids = try await store.recordingIDs()
        recordingID = try XCTUnwrap(ids.first)
    }

    override func tearDown() async throws {
        for r in runners { await r.shutdown() }
        for e in evaluators { await e.shutdown() }
        try? FileManager.default.removeItem(at: scratch)
    }

    private func launch() throws -> WorkerLaunch { try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh") }

    private func makeRunner() throws -> ReplayRunner {
        let r = ReplayRunner(store: store, launch: try launch())
        runners.append(r)
        return r
    }

    /// One real evaluation of the fixture, stored.
    private func evaluated() async throws -> StoredResult {
        let e = EvaluationRunner(store: store, launch: try launch())
        evaluators.append(e)
        guard case .done(let id) = await e.evaluateAndWait(.init(recordingID: recordingID, seed: 0)) else { throw XCTSkip("evaluation failed: \(e.state)") }
        return try await store.result(id: id)
    }

    func testFreezeThenReplay_streamingMatchesOfflineAndIsStored() async throws {
        let result = try await evaluated()
        let runner = try makeRunner()
        let model = try await runner.freeze(result: result, role: .reference, name: "Tiny")
        XCTAssertEqual(model.expectedChannelIDs.count, 8)
        XCTAssertEqual(model.classLabels, ["cue_left_fist", "cue_right_fist"])
        XCTAssertGreaterThan(model.warmupSamples, 0)

        let state = await runner.replay(model: model, recordingID: recordingID, cueLengthSeconds: 4.0)
        guard case .done(let id) = state else { return XCTFail("\(state)") }
        let runs = try await store.liveRuns().runs
        let stored = try XCTUnwrap(runs.first { $0.liveRunID == id })
        XCTAssertEqual(stored.kind, .replay)
        let parity = try XCTUnwrap(stored.parity)
        XCTAssertTrue(parity.passed, "\(parity)")
        XCTAssertEqual(parity.deviations.map(\.quantity), ["bandpassed_uv", "features", "score"])
        XCTAssertTrue(parity.deviations.allSatisfy { ($0.observed ?? .infinity) <= $0.allowed })
        XCTAssertEqual(parity.firstValidWindowStop.count, 3, "one per segment")
        XCTAssertGreaterThan(parity.cueLockedCompared ?? 0, 0, "cue-locked trial windows are compared too")
        XCTAssertEqual(parity.mismatches, [])
        XCTAssertEqual(parity.storedChunking, "1")
        XCTAssertEqual(stored.hopSamples, WorkerClient.hopSamples)

        let preds = try await store.predictions(liveRun: id).records
        XCTAssertEqual(preds.map(\.sequence), Array(0..<preds.count).map { $0 })
        XCTAssertTrue(preds.allSatisfy { $0.emittedAtMonotonicNanos == nil && $0.pipelineID == model.sourcePipelineID })
        for p in preds where p.offline?.validity == .valid {
            XCTAssertEqual(p.score ?? .nan, p.offline?.score ?? .nan, accuracy: 1e-8, "streamed vs offline score")
        }
        let valid = preds.filter { $0.validity == .valid }
        XCTAssertFalse(valid.isEmpty)
        XCTAssertTrue(valid.allSatisfy { ($0.confidence ?? 0) >= 0.5 })
        XCTAssertTrue(valid.allSatisfy { $0.predictedClass == (($0.score ?? 0) > 0 ? 1 : 0) }, "the worker's class is stored")
        XCTAssertTrue(valid.allSatisfy { $0.action.kind == (($0.confidence ?? 0) >= 0.6 ? .class : .abstain) })
        XCTAssertTrue(preds.filter { $0.validity != .valid }.allSatisfy { $0.action == .abstain })

        let view = try XCTUnwrap(ParityViewModel(record: stored, sampleRateHz: model.expectedSampleRateHz))
        XCTAssertEqual(view.headline, "Live path matches offline")      // brief 011: a verdict first
        XCTAssertTrue(view.tolerances[0].text.hasPrefix("Band-passed samples: largest difference "), view.tolerances[0].text)
        XCTAssertTrue(view.tolerances[0].text.hasSuffix("allowed 1 × 10⁻⁸ µV"), view.tolerances[0].text)
        XCTAssertTrue(view.windows.hasPrefix("\(parity.windowsCompared) windows compared"))
        XCTAssertTrue(view.firstValid.hasPrefix("segment 1: first valid window ends at "), view.firstValid)
        XCTAssertEqual(view.chunkings, "Re-chunked as 1-sample, 7-sample, 13-sample, 125-sample, a seeded random mix pieces")

        // Same fit again: refused by the store, nothing new written.
        do {
            _ = try await runner.freeze(result: result, role: .reference, name: "Again")
            XCTFail("a fit is frozen once")
        } catch {
            XCTAssertTrue("\(error)".contains("already frozen"), "\(error)")
        }
    }

    func testReplay_refusesChangedArraysAndMismatchedChannels() async throws {
        let result = try await evaluated()
        let runner = try makeRunner()
        let model = try await runner.freeze(result: result, role: .baseline, name: "Base")
        var reordered = model
        reordered.expectedChannelIDs.swapAt(0, 1)
        let mismatch = await runner.replay(model: reordered, recordingID: recordingID)
        guard case .refused(let code, let message) = mismatch else { return XCTFail("\(mismatch)") }
        XCTAssertEqual(code, "channel_mismatch")
        let words = ModelErrorText.describe(code: code, message: message)
        XCTAssertTrue(words.hasPrefix("This recording doesn't match the model: same channels in a different order"), words)
        XCTAssertTrue(words.hasSuffix("Nothing is reordered or resampled."))

        let npz = await store.arraysURL(for: model)
        var bytes = try Data(contentsOf: npz)
        bytes.append(0)
        try bytes.write(to: npz)
        let changed = await runner.replay(model: model, recordingID: recordingID)
        guard case .refused(let code2, let message2) = changed else { return XCTFail("\(changed)") }
        XCTAssertEqual(code2, "invalid_model")
        XCTAssertEqual(ModelErrorText.describe(code: code2, message: message2),
                       "This model's file changed since it was frozen, so it can't be trusted. Freeze the result again.")
        for t in [0.4, 1.0, Double.nan] {
            let bad = await runner.replay(model: model, recordingID: recordingID, abstainThreshold: t)
            guard case .refused("invalid_threshold", let words) = bad else { return XCTFail("\(t): \(bad)") }
            XCTAssertEqual(ModelErrorText.describe(code: "invalid_threshold", message: words),
                           "The abstention threshold must be at least 0.50 and below 1.00 (model confidence is never below 0.50).")
        }
        let stored = try await store.liveRuns().runs
        XCTAssertEqual(stored, [], "a refused replay stores nothing")
    }

    func testLiveWrappers_splitLongPushesAndMatchTheReplay() async throws {
        let result = try await evaluated()
        let runner = try makeRunner()
        let model = try await runner.freeze(result: result, role: .reference, name: "Live")
        let client = WorkerClient(launch: try launch())
        _ = try await client.start()
        defer { Task { await client.shutdown() } }
        let handle = try await store.recording(id: recordingID)
        let arrays = await store.arraysURL(for: model).path
        let info = try await client.liveOpen(model: model, arraysPath: arrays, channelIDs: handle.manifest.channels.map(\.id),
                                             sampleRateHz: handle.manifest.timing.nominalSampleRateHz)
        XCTAssertEqual(info.window.hopSamples, 16)
        XCTAssertEqual(info.window.warmupSamples, model.warmupSamples)

        // Segment 0 as one 1,300-sample push: three calls (512 + 512 + 276).
        var rows = Array(repeating: [Double](), count: handle.manifest.channels.count)
        for entry in handle.chunks(inSegment: 0) {
            let values = try handle.chunk(entry)
            for (i, ch) in handle.manifest.channels.enumerated() {
                rows[i] += values[(ch.sourceRow * entry.sampleCount)..<((ch.sourceRow + 1) * entry.sampleCount)]
            }
            if rows[0].count >= 1_300 { break }
        }
        rows = rows.map { Array($0.prefix(1_300)) }
        let results = try await client.livePush(session: info.session, segment: 0, firstSample: 0, rows: rows,
                                                gaps: [LiveGap(afterSample: 600, evidence: "sequence_skip")])
        XCTAssertEqual(results.map(\.nSamples), [512, 1_024, 1_300])
        let hops = results.flatMap(\.predictions).filter { $0.kind == "hop" }
        XCTAssertTrue((80...82).contains(hops.count), "a window every 16 samples: \(hops.count)")
        XCTAssertTrue(hops.contains { $0.detail == "window_spans_detected_gap" }, "the gap travelled with its piece")
        // A non-finite value anywhere is refused before any piece is sent: the session stays
        // where it was and the next push continues at sample 1,300.
        var poisoned = rows
        poisoned[3][900] = .nan
        do {
            _ = try await client.livePush(session: info.session, segment: 0, firstSample: 1_300, rows: poisoned)
            XCTFail("non-finite samples are refused")
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, "non_finite_samples")
        }
        let more = try await client.livePush(session: info.session, segment: 0, firstSample: 1_300, rows: rows.map { Array($0.prefix(16)) })
        XCTAssertEqual(more.map(\.nSamples), [1_316])
        _ = try await client.liveClose(session: info.session)
        do {
            _ = try await client.livePush(session: info.session, segment: 0, firstSample: 1_300, rows: rows)
            XCTFail("a closed session refuses pushes")
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, "bad_request")
        }
    }

    func testFreezeIsRefusedWhileAReplayRuns_andAClassThatDisagreesWithItsScoreIsAnError() async throws {
        let result = try await evaluated()
        let runner = try makeRunner()
        let model = try await runner.freeze(result: result, role: .reference, name: "R")
        let replay = Task { await runner.replay(model: model, recordingID: recordingID) }
        while !runner.isBusy { await Task.yield() }
        do {
            _ = try await runner.freeze(result: result, role: .baseline, name: "B")
            XCTFail("freeze waits for the replay")
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, "busy")
        }
        guard case .done = await replay.value else { return XCTFail("\(runner.state)") }

        let line = #"{"segment":0,"kind":"hop","window_start":0,"window_stop":16,"validity":"valid","detail":null,"score":0.7,"#
            + #""confidence":0.67,"predicted_class":0,"trial_id":null,"feedback_eligible":false,"gap":null}"#
        let p = try WorkerClient.snakeDecoder().decode(WorkerPrediction.self, from: Data(line.utf8))
        XCTAssertThrowsError(try ReplayRunner.record(p, model: model, threshold: 0.6, sequence: 0))
    }

    func testFreezeSheetCopy() throws {
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1",
                                      configuration: ["window_offset_s": "0.5", "window_length_s": "3.5", "bandpass_low_hz": "8.0", "bandpass_high_hz": "30.0",
                                                      "bandpass_order": "4", "label_left": "cue_left_hand", "label_right": "cue_right_hand"],
                                      expectedChannelIDs: ["ch00", "ch01"], expectedSampleRateHz: 125, preprocessingStatePolicy: "reset_on_segment_start",
                                      trainingRecordingIDs: [], splitManifest: "{}", dependencyVersions: [:], seed: 0, fittedParametersFile: nil, configHash: "h")
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                              seed: 0, configHash: "h", evaluationSHA256: "", durationsSeconds: [:], workerVersions: [:], workerOrigin: "test",
                              reproductionOf: nil, divergedFrom: nil)
        let m = FreezeSheetModel(result: StoredResult(meta: meta, evaluationJSON: Data(), pipeline: pipeline), report: nil, role: .reference,
                                 sessions: ["S1"], cueLengthSeconds: 4.0)
        XCTAssertEqual(m.feedbackSpan, "Feedback can't show: the 0.5 s offset and the 3.5 s window fill the whole 4.0 s cue.")
        // Brief 011: phrased as guidance for next time (decision #40 unchanged).
        XCTAssertEqual(m.windowSuggestion, "Next time, evaluate with a 2 s window for live feedback: feedback would then show for 1.5 s of each cue. "
                       + "This model's 3.5 s window leaves less of the cue for feedback; it can still be frozen.")
        XCTAssertEqual(m.rows.map(\.label), ["Model", "Training runs", "Channels", "Sample rate", "Band-pass", "Window", "Classes"])
        XCTAssertEqual(m.rows[2].value, "2, in this order: ch00, ch01")
        XCTAssertEqual(m.rows[4].value, "8.0–30.0 Hz, causal, order 4")
        XCTAssertEqual(m.rows[5].value, "3.5 s starting 0.5 s after the cue")
        XCTAssertEqual(m.evidence, "This model's evidence is the held-out result it was frozen from. Freezing adds no new evidence.")
        XCTAssertTrue(m.confidenceNote.contains("not calibrated and is not a probability of intent"))
        XCTAssertEqual(FreezeSheetModel.span(offset: 0.5, length: 2.0, cue: 4.0),
                       "Feedback can show for 1.5 s of each 4.0 s cue (only windows wholly inside the imagery period).")
        XCTAssertEqual([Fmt.scientific(1e-8), Fmt.scientific(3.24e-12), Fmt.scientific(0), Fmt.scientific(9.96e-7)], ["1 × 10⁻⁸", "3.2 × 10⁻¹²", "0", "1 × 10⁻⁶"])
    }
}
