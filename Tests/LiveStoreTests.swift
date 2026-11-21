import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 3: frozen models (`models/`), live runs and replays (`live/`).
final class LiveStoreTests: XCTestCase {
    private var scratch: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try ProjectStore.create(at: scratch.appendingPathComponent("l.bciproj"), name: "L")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    private let npzBytes = Data("PK\u{03}\u{04}arrays".utf8)

    private func recording(session: String?) async throws -> UUID {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let m = RecordingManifest(
            recordingID: id, sessionID: session, runID: "r1", createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0),
                       ChannelSpec(id: "ch01", label: "C4", kind: "eeg", unit: "uV", sourceRow: 1)],
            reference: "none", montage: "unspecified",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0), boardConfiguration: .init(requested: [:], readback: [:]), chunks: [],
            segments: [.init(index: 0, sessionID: session, runID: "r1", startedAtWall: t0, startedAtMonotonicNanos: 0,
                             endedAtMonotonicNanos: 1, endReason: .stopped, detectedGaps: [])])
        _ = try await store.createRecording(m)
        return id
    }

    private func result(recording: UUID, configuration: [String: String]? = nil) async throws -> ResultMeta {
        let staging = try await store.stagingDirectory()
        let npz = staging.appendingPathComponent(ProjectStore.fittedFileName)
        try npzBytes.write(to: npz)
        let config = configuration ?? ["window_offset_s": "0.5", "window_length_s": "2.0", "bandpass_low_hz": "8.0", "bandpass_high_hz": "30.0",
                                       "bandpass_order": "4", "label_left": "cue_left", "label_right": "cue_right", "baseline": "logvar_rlda_v1"]
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1", configuration: config, expectedChannelIDs: ["ch00", "ch01"],
                                      expectedSampleRateHz: 125, preprocessingStatePolicy: "reset_on_segment_start", trainingRecordingIDs: [recording],
                                      splitManifest: #"{"training_runs":["r1","r9"],"holdout_runs":["r2"]}"#, dependencyVersions: [:], seed: 0,
                                      fittedParametersFile: nil, configHash: "cfg")
        let evaluation = Data("{}".utf8)
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: recording, createdAt: Date(), seed: 0, configHash: "cfg",
                              evaluationSHA256: AtomicFile.sha256Hex(evaluation), durationsSeconds: [:], workerVersions: ["worker": "1"],
                              workerOrigin: "test", reproductionOf: nil, divergedFrom: nil)
        _ = try await store.storeResult(evaluationJSON: evaluation, meta: meta, pipeline: pipeline, fittedArraysFile: npz)
        return meta
    }

    private func validation(classes: [Int] = [0, 1], sha: String? = nil) -> ModelValidation {
        ModelValidation(model: "reference", featureKind: "csp_log_power", nChannels: 2, nFeatures: 4, filterWarmupSamples: 93,
                        ldaClasses: classes, sha256: sha ?? AtomicFile.sha256Hex(npzBytes))
    }

    private func prediction(_ start: Int, validity: Validity = .valid) -> PredictionRecord {
        PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: .init(start: start, count: 250), score: 0.4, validity: validity,
                         emittedAtMonotonicNanos: Int64(start), action: .chosen("cue_right"), feedbackPresentedAtMonotonicNanos: nil,
                         validityDetail: validity == .valid ? nil : "window_spans_detected_gap", acquisitionReceiptMonotonicNanos: 5,
                         workerComputeNanos: 7, confidence: 0.6, windowKind: "hop", feedbackEligible: true)
    }

    // MARK: Freeze

    func testFreeze_recordsWhatTheModelExpectsAndItsEvidence() async throws {
        let rec = try await recording(session: "S1")
        let meta = try await result(recording: rec)
        let model = try await store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference, name: "  MI 2 s  ",
                                           validation: validation(), now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(model.name, "MI 2 s")
        XCTAssertEqual(model.recipe, "csp_rlda_v1")
        XCTAssertEqual(model.expectedChannelIDs, ["ch00", "ch01"])
        XCTAssertEqual(model.window, .init(offsetSeconds: 0.5, lengthSeconds: 2.0))
        XCTAssertEqual(model.bandpass, .init(lowHz: 8, highHz: 30, order: 4))
        XCTAssertEqual(model.warmupSamples, 93)
        XCTAssertEqual(model.classLabels, ["cue_left", "cue_right"])
        XCTAssertEqual(model.trainingRunIDs, ["r1", "r9"])
        XCTAssertEqual(model.trainingSessionIDs, ["S1", nil], "a run the recording doesn't hold has no known session")
        XCTAssertEqual(model.fittedSHA256, AtomicFile.sha256Hex(npzBytes))
        XCTAssertEqual(model.workerVersions, ["worker": "1"])
        let listed = try await store.models()
        XCTAssertEqual(listed.models, [model])
        XCTAssertEqual(listed.unreadable, 0)
        let arrays = await store.arraysURL(for: model)
        let fitted = await store.fittedArraysURL(pipelineID: meta.pipelineID)
        XCTAssertEqual(arrays, fitted, "the arrays stay in the pipeline directory")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("models").path)
        XCTAssertEqual(leftovers, [model.modelID.uuidString])
    }

    func testFreeze_baselineUsesItsOwnRecipeAndLDAClassOrder() async throws {
        let meta = try await result(recording: try await recording(session: nil))
        let model = try await store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .baseline, name: "Baseline",
                                           validation: validation(classes: [1, 0]))
        XCTAssertEqual(model.recipe, "logvar_rlda_v1")
        XCTAssertEqual(model.classLabels, ["cue_right", "cue_left"], "labels follow the LDA's class order")
        XCTAssertEqual(model.trainingSessionIDs, [nil, nil])
    }

    func testFreeze_refusesChangedArraysWrongResultDuplicatesAndBadConfiguration() async throws {
        let rec = try await recording(session: "S1")
        let meta = try await result(recording: rec)
        let other = try await result(recording: rec)
        await assertRefused("changed since", try await self.store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference,
                                                                         name: "M", validation: self.validation(sha: String(repeating: "0", count: 64))))
        await assertRefused("not produced by", try await self.store.freeze(pipeline: meta.pipelineID, result: other.resultID, role: .reference,
                                                                           name: "M", validation: self.validation()))
        await assertRefused("classes", try await self.store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference,
                                                                   name: "M", validation: self.validation(classes: [0, 2])))
        await assertRefused("name", try await self.store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference,
                                                                name: " \u{202E} ", validation: self.validation()))
        _ = try await store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference, name: "M", validation: validation())
        await assertRefused("already frozen", try await self.store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference,
                                                                          name: "M2", validation: self.validation()))
        let bare = try await result(recording: rec, configuration: ["window_offset_s": "0.5"])
        await assertRefused("configuration", try await self.store.freeze(pipeline: bare.pipelineID, result: bare.resultID, role: .reference,
                                                                         name: "M", validation: self.validation()))
        let count = try await store.models().models.count
        XCTAssertEqual(count, 1)
    }

    func testModels_skipHostileFiles() async throws {
        let meta = try await result(recording: try await recording(session: nil))
        let good = try await store.freeze(pipeline: meta.pipelineID, result: meta.resultID, role: .reference, name: "M", validation: validation())
        let models = store.directory.appendingPathComponent("models")
        let json = try Data(contentsOf: models.appendingPathComponent(good.modelID.uuidString).appendingPathComponent("model.json"))
        // Same bytes under another id's directory; a bad hash; and a symlinked directory.
        let moved = models.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        try json.write(to: moved.appendingPathComponent("model.json"))
        var bad = good
        bad.modelID = UUID(); bad.fittedSHA256 = "../../etc"
        let badDir = models.appendingPathComponent(bad.modelID.uuidString)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: false)
        try ContractJSON.encoder().encode(bad).write(to: badDir.appendingPathComponent("model.json"))
        try FileManager.default.createSymbolicLink(at: models.appendingPathComponent(UUID().uuidString), withDestinationURL: moved)
        let listed = try await store.models()
        XCTAssertEqual(listed.models.map(\.modelID), [good.modelID])
        XCTAssertEqual(listed.unreadable, 2, "a symbolic link is not a child at all")
    }

    // MARK: Live runs

    func testLiveRun_appendsWithSequencesFinishesOnceAndCountsPerModel() async throws {
        let model = UUID()
        let run = LiveRunRecord(kind: .live, modelID: model, recordingID: UUID(), runIDs: ["R1"], hopSamples: 16, abstainThreshold: 0.6,
                                staleLimitMillis: 250, startedAt: Date(timeIntervalSince1970: 10))
        let writer = try await store.createLiveRun(run)
        let s0 = try await writer.append(prediction(0))
        let s1 = try await writer.append(prediction(16, validity: .insufficientWindow))
        try await writer.append(FeedbackRecord(predictionSequence: s1, shown: false, side: nil, length: nil, words: "Waiting for enough signal",
                                               presentedAtMonotonicNanos: 99))
        XCTAssertEqual([s0, s1], [0, 1])
        try await writer.finish(endedAt: Date(timeIntervalSince1970: 20), summary: .init(predictions: 2, byValidity: ["valid": 1, "insufficient_window": 1], abstained: 0),
                                latency: nil, replayCheck: .init(windowsCompared: 2, windowsMatched: 2, differingSequences: []))
        do {
            try await writer.finish(endedAt: Date(), summary: nil, latency: nil, replayCheck: nil)
            XCTFail("a live run is finished once")
        } catch {}

        let listed = try await store.liveRuns()
        XCTAssertEqual(listed.runs.count, 1)
        XCTAssertEqual(listed.runs[0].endedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(listed.runs[0].replayCheck?.windowsMatched, 2)
        let preds = try await store.predictions(liveRun: run.liveRunID)
        XCTAssertEqual(preds.records.map(\.sequence), [0, 1])
        XCTAssertEqual(preds.records[1].validityDetail, "window_spans_detected_gap")
        XCTAssertNil(preds.records[0].feedbackPresentedAtMonotonicNanos, "presentation lives in feedback.jsonl")
        let feedback = try await store.feedback(liveRun: run.liveRunID)
        XCTAssertEqual(feedback.records.first?.words, "Waiting for enough signal")
        let used = try await store.liveRunCount(model: model)
        XCTAssertEqual(used, 1)
    }

    func testLogs_tolerateATruncatedLastLineOnly() async throws {
        let run = LiveRunRecord(kind: .live, modelID: UUID(), recordingID: UUID(), runIDs: [], hopSamples: 16, abstainThreshold: 0.6,
                                staleLimitMillis: 250, startedAt: Date())
        let writer = try await store.createLiveRun(run)
        try await writer.append(prediction(0))
        try await writer.append(prediction(16))
        let url = writer.directory.appendingPathComponent(ProjectStore.predictionsFileName)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"pipelineID":"#.utf8))     // killed mid-write
        try handle.close()
        let read = try await store.predictions(liveRun: run.liveRunID)
        XCTAssertEqual(read.records.count, 2)
        XCTAssertTrue(read.lastLineTruncated)

        // The same garbage followed by a newline is a damaged line, not a truncation.
        try (try Data(contentsOf: url) + Data("\n".utf8)).write(to: url)
        do {
            _ = try await store.predictions(liveRun: run.liveRunID)
            XCTFail("a malformed complete line is an error")
        } catch {}
        let none = try await store.feedback(liveRun: run.liveRunID)
        XCTAssertEqual(none.records, [])
    }

    func testReplay_isStoredCompleteWithItsPredictions() async throws {
        let parity = LiveRunRecord.ParityReport(passed: true, windowsCompared: 40, deviations: [.init(quantity: "score", observed: 1e-12, allowed: 1e-8)],
                                                boundaryWindows: 0, firstValidWindowStop: [343], chunkings: ["1", "7", "random"])
        let replay = LiveRunRecord(kind: .replay, modelID: UUID(), recordingID: UUID(), runIDs: ["R1"], hopSamples: 16, abstainThreshold: 0.6,
                                   staleLimitMillis: nil, startedAt: Date(), endedAt: Date(), parity: parity)
        var p = prediction(0)
        p.sequence = 0; p.emittedAtMonotonicNanos = nil; p.offline = .init(validity: .valid, score: 0.4)
        try await store.storeReplay(replay, predictions: [p])
        let listed = try await store.liveRuns()
        XCTAssertEqual(listed.runs.first?.parity, parity)
        let preds = try await store.predictions(liveRun: replay.liveRunID)
        XCTAssertEqual(preds.records, [p])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("live").path)
        XCTAssertEqual(names, [replay.liveRunID.uuidString], "assembled in a temp directory and renamed")
        do {
            try await store.storeReplay(replay, predictions: [])
            XCTFail("a stored replay is never replaced")
        } catch {}
        do {
            _ = try await store.createLiveRun(replay)
            XCTFail("a replay is not a live run")
        } catch {}
    }

    private func assertRefused<T>(_ fragment: String, _ body: @autoclosure () async throws -> T, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected a refusal mentioning \(fragment)", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(fragment), "\(error)", line: line)
        }
    }
}
