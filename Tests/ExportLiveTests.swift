import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 9: the export carries the frozen models and live runs that belong to the
/// exported result (`live.json`), byte for byte, and names whatever it had to leave out.
final class ExportLiveTests: XCTestCase {
    private var scratch: URL!
    private var store: ProjectStore!
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-export-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try ProjectStore.create(at: scratch.appendingPathComponent("x.bciproj"), name: "x", now: at)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: Fixtures

    /// One recording of one chunk, one channel, run `run-0` in session `S`.
    private func recording() async throws -> UUID {
        let m = RecordingManifest(
            recordingID: UUID(), sessionID: "S", runID: "run-0", createdAt: at,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0)],
            reference: "SRB2", montage: "undeclared",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: at), boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [],
            segments: [.init(index: 0, sessionID: "S", runID: "run-0", startedAtWall: at, startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])])
        let writer = try await store.createRecording(m)
        try await writer.append(ChunkPayload(samples: [1, 2, 3, 4], rowCount: 1, sampleCount: 4, segment: 0, firstSampleIndex: 0, drainedAtMonotonicNanos: 0))
        return m.recordingID
    }

    /// A result on `recording` whose fitted arrays are `arrays`, and a model frozen from it.
    private func frozen(on recording: UUID, arrays: String) async throws -> (meta: ResultMeta, model: ModelRecord) {
        let staging = try await store.stagingDirectory()
        let npz = staging.appendingPathComponent(ProjectStore.fittedFileName)
        let bytes = Data("PK\u{03}\u{04}\(arrays)".utf8)
        try bytes.write(to: npz)
        let config = ["window_offset_s": "0.5", "window_length_s": "2.0", "bandpass_low_hz": "8.0", "bandpass_high_hz": "30.0",
                      "bandpass_order": "4", "label_left": "left", "label_right": "right"]
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1", configuration: config, expectedChannelIDs: ["ch00"],
                                      expectedSampleRateHz: 125, preprocessingStatePolicy: "reset_on_segment_start", trainingRecordingIDs: [recording],
                                      splitManifest: #"{"training_runs":["run-0"]}"#, dependencyVersions: [:], seed: 0,
                                      fittedParametersFile: nil, configHash: "cfg")
        let evaluation = Data("{}".utf8)
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: recording, createdAt: at, seed: 0, configHash: "cfg",
                              evaluationSHA256: AtomicFile.sha256Hex(evaluation), durationsSeconds: [:], workerVersions: ["worker": "1"],
                              workerOrigin: "test", reproductionOf: nil, divergedFrom: nil)
        _ = try await store.storeResult(evaluationJSON: evaluation, meta: meta, pipeline: pipeline, fittedArraysFile: npz)
        let validation = ModelValidation(model: "reference", featureKind: "csp_log_power", nChannels: 1, nFeatures: 2, filterWarmupSamples: 93,
                                         ldaClasses: [0, 1], sha256: AtomicFile.sha256Hex(bytes))
        let model = try await store.freeze(pipeline: pipeline.pipelineID, result: meta.resultID, role: .reference, name: "M \(arrays)",
                                           validation: validation, now: at)
        return (meta, model)
    }

    private func prediction(_ start: Int) -> PredictionRecord {
        PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: .init(start: start, count: 250), score: 0.4, validity: .valid,
                         emittedAtMonotonicNanos: Int64(start), action: .chosen("right"), feedbackPresentedAtMonotonicNanos: nil,
                         validityDetail: nil, acquisitionReceiptMonotonicNanos: 5, workerComputeNanos: 7, confidence: 0.6,
                         windowKind: "hop", feedbackEligible: true)
    }

    /// A finished live run of `model` on `recording` with two predictions and one feedback line.
    @discardableResult
    private func liveRun(model: UUID, recording: UUID) async throws -> LiveRunRecord {
        let run = LiveRunRecord(kind: .live, modelID: model, recordingID: recording, runIDs: ["run-0"], hopSamples: 16, abstainThreshold: 0.6,
                                staleLimitMillis: 250, startedAt: at)
        let writer = try await store.createLiveRun(run)
        let s = try await writer.append(prediction(0))
        try await writer.append(prediction(16))
        try await writer.append(FeedbackRecord(predictionSequence: s, shown: false, side: nil, length: nil, words: "Waiting for enough signal",
                                               presentedAtMonotonicNanos: 9, reason: "invalid"))
        try await writer.finish(endedAt: at.addingTimeInterval(60), summary: .init(predictions: 2, byValidity: ["valid": 2], abstained: 0),
                                latency: nil, replayCheck: nil)
        return await writer.record
    }

    @discardableResult
    private func replay(model: UUID, recording: UUID) async throws -> LiveRunRecord {
        let r = LiveRunRecord(kind: .replay, modelID: model, recordingID: recording, runIDs: ["run-0"], hopSamples: 16, abstainThreshold: 0.6,
                              staleLimitMillis: nil, startedAt: at, endedAt: at)
        var p = prediction(0)
        p.sequence = 0
        try await store.storeReplay(r, predictions: [p])
        return r
    }

    private func evidence(_ out: URL) throws -> ExportedLiveEvidence {
        try ContractJSON.decoder().decode(ExportedLiveEvidence.self, from: Data(contentsOf: out.appendingPathComponent(ProjectStore.liveExportFileName)))
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return out
    }

    /// Result R on recording A with model M; M's live run on B; a replay of M on A; model M3
    /// (from a result on C) live on A; and model M2 (another result on A) live on D, which
    /// belongs to neither the result nor its recording.
    private func scene() async throws -> (result: ResultMeta, included: [ModelRecord], runs: [LiveRunRecord], excluded: [UUID]) {
        let a = try await recording(), c = try await recording()
        let (r, m) = try await frozen(on: a, arrays: "m")
        let (_, m2) = try await frozen(on: a, arrays: "m2")
        let (_, m3) = try await frozen(on: c, arrays: "m3")
        let onB = try await liveRun(model: m.modelID, recording: UUID())
        let replayA = try await replay(model: m.modelID, recording: a)
        let m3OnA = try await liveRun(model: m3.modelID, recording: a)
        let m2OnD = try await liveRun(model: m2.modelID, recording: UUID())
        return (r, [m, m3], [onB, replayA, m3OnA], [m2.modelID, m2OnD.liveRunID])
    }

    // MARK: Tests

    func testRoundTrip_copiesExactlyTheModelsAndRunsThatBelongToTheResult() async throws {
        let (result, models, runs, excluded) = try await scene()
        let out = scratch.appendingPathComponent("export")
        let summary = try await store.export(result: result.resultID, to: out)
        XCTAssertEqual(summary, ExportSummary(modelsFromOtherResults: 1, liveRunsOnOtherRecordings: 1))
        XCTAssertNil(ExportNoticeText.leftOut(summary))
        XCTAssertEqual(ExportNoticeText.added(summary), "Also includes 1 model frozen from another result and 1 live run on another recording.")
        let files = try tree(out)
        let e = try evidence(out)
        XCTAssertEqual(Set(e.models.map(\.modelID)), Set(models.map(\.modelID)))
        XCTAssertEqual(Set(e.liveRuns.map(\.liveRunID)), Set(runs.map(\.liveRunID)))
        XCTAssertEqual([e.unreadableModels, e.unreadableLiveRuns], [0, 0])
        XCTAssertEqual(e.unverifiedModels, [])
        XCTAssertEqual(e.unverifiedLiveRuns, [])
        for id in excluded { XCTAssertFalse(files.keys.contains { $0.contains(id.uuidString) }, "\(id) belongs to another result") }

        let project = store.directory
        for f in e.models {
            let bytes = try XCTUnwrap(files[f.file])
            XCTAssertEqual(bytes, try Data(contentsOf: project.appendingPathComponent(f.file)), "model.json byte for byte")
            XCTAssertEqual(f.sha256, AtomicFile.sha256Hex(bytes))
            let record = try ContractJSON.decoder().decode(ModelRecord.self, from: bytes)
            XCTAssertEqual(record, models.first { $0.modelID == f.modelID })
            let arrays = try XCTUnwrap(files[f.arrays])
            XCTAssertEqual(f.arrays, "arrays/\(record.fittedSHA256).npz")
            XCTAssertEqual(AtomicFile.sha256Hex(arrays), record.fittedSHA256, "arrays are named by and match their hash")
        }
        for r in e.liveRuns {
            let stored = try XCTUnwrap(runs.first { $0.liveRunID == r.liveRunID })
            XCTAssertEqual(r.recordingIncluded, stored.recordingID == result.recordingID)
            XCTAssertEqual(try ContractJSON.decoder().decode(LiveRunRecord.self, from: try XCTUnwrap(files[r.run.file])), stored)
            let preds = try JSONLines<PredictionRecord>.parse(try XCTUnwrap(files[r.predictions.file]), name: "p")
            let original = try await store.predictions(liveRun: r.liveRunID)
            XCTAssertEqual(preds.records, original.records)
            XCTAssertEqual(r.predictions.records, original.records.count)
            XCTAssertEqual(r.predictions.lastLineTruncated, false)
            for f in [r.run, r.predictions] + (r.feedback.map { [$0] } ?? []) {
                XCTAssertEqual(try XCTUnwrap(files[f.file]), try Data(contentsOf: project.appendingPathComponent(f.file)), "\(f.file) byte for byte")
                XCTAssertEqual(f.sha256, AtomicFile.sha256Hex(try XCTUnwrap(files[f.file])))
            }
            if stored.kind == .live {
                let feedback = try JSONLines<FeedbackRecord>.parse(try XCTUnwrap(files[try XCTUnwrap(r.feedback).file]), name: "f")
                XCTAssertEqual(feedback.records.map(\.reason), ["invalid"])
            } else {
                XCTAssertNil(r.feedback, "a replay has no feedback log")
            }
        }
    }

    func testNotice_namesWhatWasAddedBeyondTheRecording() {
        XCTAssertNil(ExportNoticeText.added(ExportSummary()))
        XCTAssertEqual(ExportNoticeText.added(ExportSummary(modelsFromOtherResults: 1, liveRunsOnOtherRecordings: 2)),
                       "Also includes 1 model frozen from another result and 2 live runs on other recordings.")
        XCTAssertEqual(ExportNoticeText.added(ExportSummary(modelsFromOtherResults: 3)), "Also includes 3 models frozen from other results.")
        XCTAssertEqual(ExportNoticeText.added(ExportSummary(liveRunsOnOtherRecordings: 1)), "Also includes 1 live run on another recording.")
        let url = URL(fileURLWithPath: "/tmp/out")
        XCTAssertEqual(ExportNoticeText.exported(url, leftOut: "1 live run folder couldn't be read and was left out.",
                                                 added: "Also includes 1 live run on another recording."),
                       "Exported to /tmp/out. Also includes 1 live run on another recording. 1 live run folder couldn't be read and was left out.")
        XCTAssertFalse(ProjectSession.Notice.exported(url, leftOut: nil, added: "Also includes 1 live run on another recording.").isPersistent,
                       "an addition is information, not a warning")
    }

    func testTwoExportsAreByteIdentical() async throws {
        let (result, _, _, _) = try await scene()
        let a = scratch.appendingPathComponent("a"), b = scratch.appendingPathComponent("b")
        try await store.export(result: result.resultID, to: a)
        try await store.export(result: result.resultID, to: b)
        let (ta, tb) = (try tree(a), try tree(b))
        XCTAssertEqual(ta, tb)
        XCTAssertEqual(ta.keys.filter { $0.hasPrefix("arrays/") }.count, 2)
    }

    func testAProjectWithoutModelsOrLiveRunsHasNoLiveFile() async throws {
        let a = try await recording()
        let (result, _) = try await frozen(on: a, arrays: "m")
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("models"))
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result.resultID, to: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(ProjectStore.liveExportFileName).path))
    }

    func testHostileProject_skipsAndNamesWhatItLeftOut() async throws {
        let (result, models, runs, _) = try await scene()
        let fm = FileManager.default
        let project = store.directory
        // M3's arrays changed after freezing: M3 and its run on A are left out.
        let m3 = models[1]
        try Data("PK changed".utf8).write(to: project.appendingPathComponent("pipelines/\(m3.sourcePipelineID.uuidString)/fitted.npz"))
        // M's live run on B: its feedback log has a damaged line in the middle.
        let onB = project.appendingPathComponent("live/\(runs[0].liveRunID.uuidString)")
        let feedback = onB.appendingPathComponent(ProjectStore.feedbackFileName)
        try (Data("garbage\n".utf8) + Data(contentsOf: feedback)).write(to: feedback)
        // The replay of M on A: predictions.jsonl swapped for a symbolic link to a file outside.
        let outside = scratch.appendingPathComponent("secret.jsonl")
        try Data("secret\n".utf8).write(to: outside)
        let replayDir = project.appendingPathComponent("live/\(runs[1].liveRunID.uuidString)")
        try fm.removeItem(at: replayDir.appendingPathComponent(ProjectStore.predictionsFileName))
        try fm.createSymbolicLink(at: replayDir.appendingPathComponent(ProjectStore.predictionsFileName), withDestinationURL: outside)
        // A model folder that is a link, one with garbage, one oversized; a live folder that is a FIFO.
        try fm.createSymbolicLink(at: project.appendingPathComponent("models/\(UUID().uuidString)"),
                                  withDestinationURL: project.appendingPathComponent("models/\(models[0].modelID.uuidString)"))
        let junk = project.appendingPathComponent("models/\(UUID().uuidString)")
        try fm.createDirectory(at: junk, withIntermediateDirectories: false)
        try Data("{not json".utf8).write(to: junk.appendingPathComponent("model.json"))
        let big = project.appendingPathComponent("models/\(UUID().uuidString)")
        try fm.createDirectory(at: big, withIntermediateDirectories: false)
        try Data(count: ModelRecord.maxFileBytes + 1).write(to: big.appendingPathComponent("model.json"))
        XCTAssertEqual(mkfifo(project.appendingPathComponent("live/\(UUID().uuidString)").path, 0o644), 0)
        try Data("stray".utf8).write(to: project.appendingPathComponent("live/notes.txt"))

        let out = scratch.appendingPathComponent("export")
        let summary = try await store.export(result: result.resultID, to: out)
        let files = try tree(out)
        let e = try evidence(out)
        XCTAssertEqual(e.models.map(\.modelID), [models[0].modelID], "only M survives")
        XCTAssertEqual(e.unverifiedModels, [m3.modelID])
        XCTAssertEqual(e.unverifiedLiveRuns, [runs[2].liveRunID])
        XCTAssertEqual(e.liveRuns, [])
        XCTAssertEqual(e.unreadableModels, 3, "link, garbage, oversized")
        XCTAssertEqual(e.unreadableLiveRuns, 3, "damaged feedback, linked predictions, FIFO; the stray file is not an entry")
        XCTAssertFalse(files.values.contains(Data("secret\n".utf8)), "a link is never followed")
        XCTAssertFalse(files.keys.contains { $0.contains(m3.fittedSHA256) || $0.contains(m3.modelID.uuidString) })
        XCTAssertEqual(summary, ExportSummary(unverifiedModels: 1, unreadableModels: 3, unverifiedLiveRuns: 1, unreadableLiveRuns: 3))
        XCTAssertEqual(ExportNoticeText.leftOut(summary),
                       "1 frozen model was left out because its model file is missing or changed since it was frozen. "
                       + "3 frozen model folders couldn't be read and were left out. "
                       + "1 live run was left out because its model couldn't be exported. "
                       + "3 live run folders couldn't be read and were left out.")
    }

    func testLinkedTopLevelFoldersAreReportedNotFollowed() async throws {
        let (result, _, _, _) = try await scene()
        let project = store.directory
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: project.appendingPathComponent("live"), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("live"), withDestinationURL: elsewhere)
        let out = scratch.appendingPathComponent("export")
        let summary = try await store.export(result: result.resultID, to: out)
        let e = try evidence(out)
        XCTAssertEqual(e.liveRuns, [])
        XCTAssertEqual(e.unreadableLiveRuns, 1)
        XCTAssertEqual(e.models.count, 1, "M is still exported; M3 belongs only through a run that could not be read")
        XCTAssertEqual(summary.unreadableLiveRuns, 1)
    }

    /// The logs are read from exactly the folder whose run.json was checked: a run whose folder
    /// is spelled in lower case, or is a symbolic link to a folder outside, is never read.
    func testLowercaseAndLinkedRunFolders_areNotRead() async throws {
        let a = try await recording()
        let (result, m) = try await frozen(on: a, arrays: "m")
        let fm = FileManager.default
        let live = store.directory.appendingPathComponent("live")
        // A lower-case copy of a real run whose logs hold a secret.
        let lowerRun = try await liveRun(model: m.modelID, recording: a)
        let lowerDir = live.appendingPathComponent(lowerRun.liveRunID.uuidString.lowercased())
        try fm.moveItem(at: live.appendingPathComponent(lowerRun.liveRunID.uuidString), to: scratch.appendingPathComponent("tmp-move"))
        try fm.moveItem(at: scratch.appendingPathComponent("tmp-move"), to: lowerDir)
        try Data("secret-lower\n".utf8).write(to: lowerDir.appendingPathComponent(ProjectStore.feedbackFileName))
        // A run folder that is a link to a copy outside the project.
        let linkedRun = try await liveRun(model: m.modelID, recording: a)
        let outside = scratch.appendingPathComponent("outside-run")
        try fm.moveItem(at: live.appendingPathComponent(linkedRun.liveRunID.uuidString), to: outside)
        try Data("secret-link\n".utf8).write(to: outside.appendingPathComponent(ProjectStore.predictionsFileName))
        try fm.createSymbolicLink(at: live.appendingPathComponent(linkedRun.liveRunID.uuidString), withDestinationURL: outside)
        // A lower-case model folder.
        let models = store.directory.appendingPathComponent("models")
        let modelJSON = try Data(contentsOf: models.appendingPathComponent("\(m.modelID.uuidString)/model.json"))
        var other = m
        other.modelID = UUID()
        let lowerModel = models.appendingPathComponent(other.modelID.uuidString.lowercased())
        try fm.createDirectory(at: lowerModel, withIntermediateDirectories: false)
        try ContractJSON.encoder().encode(other).write(to: lowerModel.appendingPathComponent("model.json"))
        XCTAssertFalse(modelJSON.isEmpty)

        let out = scratch.appendingPathComponent("export")
        let summary = try await store.export(result: result.resultID, to: out)
        let e = try evidence(out)
        let files = try tree(out)
        XCTAssertEqual(e.liveRuns, [])
        XCTAssertEqual(e.unreadableLiveRuns, 2, "the lower-case folder and the linked one")
        XCTAssertEqual(e.models.map(\.modelID), [m.modelID])
        XCTAssertEqual(e.unreadableModels, 1, "a lower-case model folder is not read")
        XCTAssertFalse(files.values.contains { String(decoding: $0, as: UTF8.self).contains("secret") })
        XCTAssertFalse(files.keys.contains { $0.contains(other.modelID.uuidString) || $0.lowercased().contains(lowerRun.liveRunID.uuidString.lowercased()) })
        XCTAssertEqual(summary.unreadableLiveRuns, 2)
    }

    func testTruncatedLastLineIsCopiedAndFlagged() async throws {
        let a = try await recording()
        let (result, m) = try await frozen(on: a, arrays: "m")
        let run = try await liveRun(model: m.modelID, recording: a)
        let url = store.directory.appendingPathComponent("live/\(run.liveRunID.uuidString)/\(ProjectStore.predictionsFileName)")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"pipelineID":"#.utf8))
        try handle.close()
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result.resultID, to: out)
        let r = try XCTUnwrap(try evidence(out).liveRuns.first)
        XCTAssertEqual(r.predictions.records, 2)
        XCTAssertEqual(r.predictions.lastLineTruncated, true)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(r.predictions.file)), try Data(contentsOf: url))
    }
}
