import XCTest
@testable import BCIWorkspace

/// Brief 006 PR 5: Freeze for live use…, frozen models under Pipelines, Replay… and the
/// parity view, driven through the session the screens use (real store and worker).
@MainActor
final class FrozenModelScreenTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!
    private var workspace: Workspace!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-frozen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("tiny.bciproj")
        _ = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        workspace = Workspace(recents: InMemoryRecentDocuments(), launch: try XCTUnwrap(WorkerLaunch.locate(), "run scripts/bootstrap.sh"))
    }

    override func tearDown() async throws {
        for url in Array(workspace.sessions.keys) { await workspace.close(url) }
        try? FileManager.default.removeItem(at: scratch)
    }

    func testFreezeListReplayAndParityView() async throws {
        let session = try await workspace.session(for: project)
        guard case .done = await session.evaluateAndWait() else { return XCTFail("\(session.runner.state)") }
        await session.awaitSelectedResult()
        let stored = try XCTUnwrap(session.selectedResult)
        XCTAssertTrue(session.frozen.models.isEmpty)

        // The sheet names the evidence and the fit; Freeze closes it and lists the model.
        session.showFreeze(stored)
        let draft = try XCTUnwrap(session.frozen.freezeDraft)
        XCTAssertTrue(draft.sheet.evidence.hasPrefix("This model's evidence is its held-out result: balanced accuracy "), draft.sheet.evidence)
        XCTAssertNotNil(draft.sheet.windowSuggestion, "a 3.5 s window gets the 2 s suggestion (decision #40)")
        XCTAssertEqual(draft.name, draft.sheet.defaultName)
        session.frozen.freezeDraft?.name = "  Tiny model  "
        let model = try XCTUnwrap(await session.freeze())
        XCTAssertEqual(model.name, "Tiny model")
        XCTAssertNil(session.frozen.freezeDraft)
        XCTAssertNil(session.frozen.sheet)
        // A closing sheet's text field writes its draft back once more: it must stay closed.
        session.frozen.updateFreezeDraft(draft)
        XCTAssertNil(session.frozen.freezeDraft)
        XCTAssertNil(session.frozen.sheet)
        XCTAssertEqual(session.notice, .frozen(name: "Tiny model"))
        XCTAssertEqual(session.noticeText(.frozen(name: "Tiny model")), "Frozen as \u{201C}Tiny model\u{201D}. It is listed under Pipelines.")
        XCTAssertEqual(session.frozen.models.map(\.modelID), [model.modelID])
        XCTAssertEqual(session.frozen.selectedModelID, model.modelID)
        let row = try XCTUnwrap(session.frozen.rows(results: session.results).first)
        XCTAssertTrue(row.source.hasPrefix("CSP + shrinkage LDA · from the result of "), row.source)
        XCTAssertEqual(row.usage, "Not used in a live run yet")
        XCTAssertEqual(FrozenModelRowModel.facts(model).map(\.label),
                       ["Channels", "Sample rate", "Band-pass", "Window", "Filter warm-up", "Classes", "Training runs", "Frozen", "Arrays SHA-256"])

        // The same fit again: the sheet stays open with the store's reason.
        session.showFreeze(stored)
        XCTAssertNil(await session.freeze())
        let refused = try XCTUnwrap(session.frozen.freezeDraft?.error)
        XCTAssertTrue(refused.hasPrefix("Not frozen: this fit is already frozen as \u{201C}Tiny model\u{201D}"), refused)
        session.frozen.freezeDraft = nil

        // Replay…: a bad threshold is refused in the sheet before anything runs.
        session.showReplay(recording: session.selectedRecordingID)
        XCTAssertEqual(session.frozen.replayDraft?.modelID, model.modelID)
        XCTAssertEqual(session.frozen.replayDraft?.thresholdText, "0.60")
        session.frozen.replayDraft?.thresholdText = "abc"
        let none = await session.replay()
        XCTAssertNil(none)
        XCTAssertEqual(session.frozen.replayDraft?.error,
                       "The abstention threshold must be at least 0.50 and below 1.00 (model confidence is never below 0.50).")
        XCTAssertFalse(session.frozen.replayDraft?.started ?? true)

        session.frozen.replayDraft?.thresholdText = "0.7"
        let state = await session.replay()
        guard case .done(let id) = state else { return XCTFail("\(String(describing: state))") }
        XCTAssertNil(session.frozen.replayDraft)
        XCTAssertTrue(session.showPipelinesAfterSheet)
        session.replaySheetClosed()
        XCTAssertEqual(session.section, .pipelines)
        XCTAssertEqual(session.frozen.selectedReplayID, id)
        await session.frozen.awaitLoads()
        let replay = try XCTUnwrap(session.frozen.selectedReplay)
        XCTAssertEqual(replay.abstainThreshold, 0.7)
        let predictions = try XCTUnwrap(session.frozen.parityPredictions)
        XCTAssertEqual(predictions.id, id)
        let view = try XCTUnwrap(ParityViewModel(record: replay, sampleRateHz: model.expectedSampleRateHz, predictions: predictions.records))
        XCTAssertTrue(view.passed)
        let n = predictions.records.filter { $0.windowKind == "cue_locked" }.count
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(view.cueLocked, "Cue-locked trial windows: \(n) of \(n) match offline (the windows each trial is scored on)")
        let valid = predictions.records.filter { $0.validity == .valid }
        let abstained = valid.filter { $0.action == .abstain }.count
        XCTAssertEqual(view.abstentions, "At threshold 0.70: \(abstained) of \(valid.count) valid windows abstained (model confidence below 0.70)")
        XCTAssertTrue(ReplayCopy.replayRow(replay, recording: "Tiny").hasSuffix(" · Tiny · matches"))
    }

    func testCopyForStatesRowsAndAParityWithoutPredictions() {
        XCTAssertEqual(ReplayCopy.state(.running(.replaying)), "Replaying chunk by chunk at five chunkings…")
        XCTAssertNil(ReplayCopy.state(.idle))
        XCTAssertEqual(ReplayCopy.state(.cancelled), "Cancelled — nothing saved.")
        XCTAssertEqual(ReplayCopy.state(.refused(code: "invalid_model", message: "model file changed since it was frozen")),
                       "This model's file changed since it was frozen, so it can't be trusted. Freeze the result again.")
        XCTAssertEqual(ReplayCopy.freezeFailed(WorkerError(code: "worker_exited", message: "gone")),
                       "The analysis worker couldn't check the model (gone). Nothing was frozen.")

        let record = LiveRunRecord(kind: .replay, modelID: UUID(), recordingID: UUID(), runIDs: [], hopSamples: 16, abstainThreshold: 0.6,
                                   staleLimitMillis: nil, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   parity: .init(passed: false, windowsCompared: 10, deviations: [.init(quantity: "score", observed: 2e-8, allowed: 1e-8)],
                                                 boundaryWindows: 1, firstValidWindowStop: [-1], chunkings: ["1"], cueLockedCompared: 4,
                                                 mismatches: ["chunks of 1: decision differs at segment 0, window ending at sample 99"]),
                                   summary: .init(predictions: 10, byValidity: ["valid": 6, "insufficient_window": 4], abstained: 2))
        let view = ParityViewModel(record: record, sampleRateHz: 125)!
        XCTAssertEqual(view.headline, "Streaming differs from offline")
        XCTAssertFalse(view.tolerances[0].within)
        XCTAssertEqual(view.cueLocked, "Cue-locked trial windows compared: 4")
        XCTAssertEqual(view.abstentions, "At threshold 0.60: 2 of 6 valid windows abstained (model confidence below 0.60)")
        XCTAssertEqual(view.boundary, "1 window on the decision boundary (listed, not counted as differences)")
        XCTAssertEqual(view.firstValid, "segment 1: no valid window")
        XCTAssertEqual(ReplayCopy.replayRow(record, recording: "R"), "2027-01-15 08:00 UTC · R · differs")
    }
}
