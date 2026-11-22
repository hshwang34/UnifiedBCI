import XCTest
@testable import BCIWorkspace

/// Brief 007 PR 2: the four goals' steps, their completion rules (decision #45: never done
/// unless true, skipped ≠ done), and per-project persistence. Pure logic.
final class GuideModelTests: XCTestCase {
    private typealias S = GuideSnapshot
    private let imported = UUID(), live = UUID(), cued = UUID()
    private let importedResult = UUID(), cuedResult = UUID(), liveRun = UUID()

    private func rec(_ id: UUID, live: Bool = false, cued: Bool = false) -> S.Recording { .init(id: id, isLive: live || cued, isCued: cued) }

    private func states(_ goal: GuideGoal, _ s: S, marks: Set<GuideMark> = [], skipped: Set<GuideStep.ID> = []) -> [GuideProgress.StepState] {
        GuideProgress(goal: goal, snapshot: s, marks: marks, skipped: skipped).rows.map(\.state)
    }

    // MARK: Steps and copy

    func testGoals_haveTheBriefsSteps() {
        XCTAssertEqual(GuideGoal.example.steps, [.openRecording, .checkSignal, .viewMontage, .evaluate, .readResult])
        XCTAssertEqual(GuideGoal.record.steps, [.connect, .confirmMap, .checkLiveSignal, .record, .reviewQuality])
        XCTAssertEqual(GuideGoal.train.steps.count, 5)
        XCTAssertEqual(GuideGoal.live.steps, GuideGoal.train.steps + [.freeze, .checkReplay, .runLive, .readLiveRun])
        XCTAssertEqual(GuideGoal.allCases.map(\.title), ["See how it works on the example", "Record EEG from a headset",
                                                         "Train and check a decoder", "Run live feedback with a participant"])
    }

    func testEveryStep_hasOneSentenceAndATarget() {
        for id in GuideStep.ID.allCases {
            let step = GuideStep.step(id)
            XCTAssertEqual(step.id, id)
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertTrue(step.instruction.hasSuffix("."), "\(id)")
            XCTAssertEqual(step.instruction.filter { $0 == "." }.count, 1, "one sentence: \(id)")
        }
        XCTAssertEqual(GuideStep.step(.checkSignal).target, GuideTarget(section: .recordings, recordingTab: .quality, anchor: .qualityTab))
        XCTAssertEqual(GuideStep.step(.checkReplay).target.section, .pipelines)
        XCTAssertEqual(GuideStep.step(.readLiveRun).target.anchor, .liveRunCard)
        XCTAssertTrue(GuideStep.step(.recordRuns).instruction.contains("4"), "decision #37: 4 runs recommended")
    }

    // MARK: Example

    func testExample_freshProjectHasNothingDone() {
        XCTAssertEqual(states(.example, S(recordings: [rec(imported)])), [.current, .todo, .todo, .todo, .todo])
    }

    func testExample_ticksFromMarksAndResults() {
        var s = S(recordings: [rec(imported)])
        var marks: Set<GuideMark> = [.recordingOpened, .quality(imported)]
        XCTAssertEqual(states(.example, s, marks: marks), [.done, .done, .current, .todo, .todo])
        marks.insert(.montageViewed)
        s.resultRecordings = [importedResult: imported]
        XCTAssertEqual(states(.example, s, marks: marks), [.done, .done, .done, .done, .current])
        marks.insert(.result(importedResult))
        let p = GuideProgress(goal: .example, snapshot: s, marks: marks, skipped: [])
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.finishedMessage, GuideCopy.allDone)
    }

    func testExample_neverDoneUnlessTrue() {
        // A mark for a recording or result that no longer exists doesn't count.
        let gone = UUID()
        let s = S(recordings: [rec(imported)])
        XCTAssertEqual(states(.example, s, marks: [.quality(gone), .result(gone)]), [.current, .todo, .todo, .todo, .todo])
        // "Opened" with no recording left is not done.
        XCTAssertEqual(states(.example, S(), marks: [.recordingOpened]).first, .current)
    }

    // MARK: Record

    func testRecord_followsTheLiveBoard() {
        var s = S(recordings: [rec(imported)])
        XCTAssertEqual(states(.record, s), [.current, .todo, .todo, .todo, .todo], "imported data is not a live recording")
        s.streaming = true
        XCTAssertEqual(states(.record, s), [.done, .current, .todo, .todo, .todo])
        s.mapDeclared = true
        XCTAssertEqual(states(.record, s), [.done, .done, .current, .todo, .todo], "10 s of preview is a mark, set by the session")
        XCTAssertEqual(states(.record, s, marks: [.previewWatched]), [.done, .done, .done, .current, .todo])
    }

    func testRecord_neverDoneUnlessTrue() {
        // A declared map counts only while streaming.
        let s = S(mapDeclared: true)
        XCTAssertEqual(states(.record, s), [.current, .todo, .todo, .todo, .todo])
        // Quality opened on imported data doesn't review a live recording.
        let s2 = S(recordings: [rec(imported), rec(live, live: true)])
        XCTAssertEqual(states(.record, s2, marks: [.quality(imported), .previewWatched]), [.done, .done, .done, .done, .current])
    }

    func testRecord_savedRecordingKeepsConnectStepsDoneAfterDisconnect() {
        let s = S(recordings: [rec(live, live: true)])
        XCTAssertEqual(states(.record, s, marks: [.quality(live)]), [.done, .done, .current, .done, .done])
    }

    // MARK: Train

    func testTrain_cuedRunsOnly() {
        var s = S(recordings: [rec(imported)], resultRecordings: [importedResult: imported])
        XCTAssertEqual(states(.train, s, marks: [.result(importedResult)]), [.current, .todo, .todo, .todo, .todo],
                       "a result on imported data doesn't train a cued decoder")
        s.streaming = true
        XCTAssertEqual(states(.train, s), [.done, .current, .todo, .todo, .todo], "the default protocol always exists; that isn't choosing one")
        XCTAssertEqual(states(.train, s, marks: [.protocolsVisited]), [.done, .done, .current, .todo, .todo])
        s.recordings.append(rec(cued, cued: true))
        XCTAssertEqual(states(.train, s), [.done, .done, .done, .current, .todo])
        s.resultRecordings[cuedResult] = cued
        XCTAssertEqual(states(.train, s), [.done, .done, .done, .done, .current])
        XCTAssertTrue(GuideProgress(goal: .train, snapshot: s, marks: [.result(cuedResult)], skipped: []).isFinished)
    }

    // MARK: Live feedback

    func testLive_freezeReplayLiveRun() {
        var s = S(recordings: [rec(cued, cued: true)], resultRecordings: [cuedResult: cued])
        let marks: Set<GuideMark> = [.result(cuedResult)]
        XCTAssertEqual(states(.live, s, marks: marks).suffix(4), [.current, .todo, .todo, .todo])
        s.frozenModelCount = 1
        XCTAssertEqual(states(.live, s, marks: marks).suffix(4), [.done, .current, .todo, .todo])
        s.replayParityPassed = true
        s.liveRunIDs = [liveRun]
        XCTAssertEqual(states(.live, s, marks: marks).suffix(4), [.done, .done, .done, .current])
        XCTAssertTrue(GuideProgress(goal: .live, snapshot: s, marks: marks.union([.liveRunCard(liveRun)]), skipped: []).isFinished)
    }

    func testLive_failedParityIsNotDone() {
        let s = S(frozenModelCount: 1, replayParityPassed: false)
        XCTAssertFalse(GuideRules.isDone(.checkReplay, s, marks: []))
        XCTAssertFalse(GuideRules.isDone(.readLiveRun, s, marks: [.liveRunCard(liveRun)]), "card of a run that isn't stored")
    }

    // MARK: Skipped is not done

    func testSkipped_isNotDoneAndMovesCurrentOn() {
        let s = S(recordings: [rec(imported)])
        let p = GuideProgress(goal: .example, snapshot: s, marks: [], skipped: [.openRecording, .checkSignal])
        XCTAssertEqual(p.rows.map(\.state), [.skipped, .skipped, .current, .todo, .todo])
        XCTAssertEqual(p.doneCount, 0)
        XCTAssertEqual(p.stepLine, "Step 3 of 5")
        XCTAssertEqual(p.rows[0].accessibilityLabel, "Open a recording, skipped")
    }

    func testSkipped_thenDoneShowsDone() {
        let s = S(recordings: [rec(imported)])
        let p = GuideProgress(goal: .example, snapshot: s, marks: [.recordingOpened], skipped: [.openRecording])
        XCTAssertEqual(p.rows[0].state, .done)
    }

    func testAllSkipped_finishesWithoutClaimingDone() {
        let p = GuideProgress(goal: .record, snapshot: S(), marks: [], skipped: Set(GuideGoal.record.steps))
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.doneCount, 0)
        XCTAssertEqual(p.finishedMessage, "Guide finished, 5 steps skipped.")
        XCTAssertEqual(p.stepLine, "0 of 5 done")
    }

    // MARK: Persistence

    private func store() -> (GuideStore, () -> Void) {
        let name = "bci-guide-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (GuideStore(defaults: d), { d.removePersistentDomain(forName: name) })
    }

    func testStore_roundTripsPerProject() {
        let (store, cleanup) = store()
        defer { cleanup() }
        let a = GuideStore.projectKey(name: "A", created: Date(timeIntervalSinceReferenceDate: 1.5))
        let b = GuideStore.projectKey(name: "A", created: Date(timeIntervalSinceReferenceDate: 2.5))
        XCTAssertNotEqual(a, b, "two example copies (same name, own creation time) are separate")
        XCTAssertEqual(store.load(a), GuideState())
        XCTAssertTrue(store.load(a).shouldAsk)
        var state = GuideState()
        state.choose(.live)
        state.skipped = [.freeze]
        state.collapsed = true
        state.marks = [.recordingOpened, .quality(live), .result(cuedResult), .liveRunCard(liveRun), .montageViewed, .previewWatched]
        store.save(state, for: a)
        XCTAssertEqual(store.load(a), state)
        XCTAssertFalse(store.load(a).shouldAsk)
        XCTAssertEqual(store.load(b), GuideState())
    }

    func testStore_notNowAsksOnce() {
        var state = GuideState()
        state.askedOnce = true
        XCTAssertFalse(state.shouldAsk)
        XCTAssertNil(state.goal)
    }

    func testStore_unknownValuesAreKeptNotFatal() throws {
        let (store, cleanup) = store()
        defer { cleanup() }
        let defaults = try XCTUnwrap(store.defaults)
        let json = #"{"version":2,"goal":"compare","skipped":["freeze","teleport"],"hidden":true,"marks":["quality:not-a-uuid","montage","x:y"]}"#
        defaults.set(Data(json.utf8), forKey: GuideStore.keyPrefix + "p")
        var s = store.load("p")
        XCTAssertNil(s.goal)
        XCTAssertEqual(s.skipped, [.freeze])
        XCTAssertTrue(s.hidden)
        XCTAssertEqual(s.marks, [.montageViewed])
        // An older build writes back what it didn't understand (and a newer version number).
        s.marks.insert(.recordingOpened)
        store.save(s, for: "p")
        let raw = try JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: GuideStore.keyPrefix + "p"))) as? [String: Any]
        XCTAssertEqual(raw?["goal"] as? String, "compare")
        XCTAssertEqual(raw?["version"] as? Int, 2)
        XCTAssertEqual(raw?["skipped"] as? [String], ["freeze", "teleport"])
        XCTAssertEqual(Set(raw?["marks"] as? [String] ?? []), ["quality:not-a-uuid", "montage", "x:y", "recording"])
        defaults.set("garbage", forKey: GuideStore.keyPrefix + "q")
        XCTAssertEqual(store.load("q"), GuideState())
    }

    func testStore_withoutDefaultsIsMemoryOnly() {
        let store = GuideStore(defaults: nil)
        var s = GuideState()
        s.choose(.train)
        store.save(s, for: "p")
        XCTAssertEqual(store.load("p"), GuideState())
    }

    func testProjectKey_isTheStoredMillisecondInstant() throws {
        // `ProjectStore.create` holds the raw Date(); project.json stores it to the millisecond.
        let raw = Date(timeIntervalSinceReferenceDate: 785_000_000.123_456_7)
        let stored = try ContractJSON.decoder().decode(Date.self, from: ContractJSON.encoder().encode(raw))
        XCTAssertNotEqual(raw, stored)
        XCTAssertEqual(GuideStore.projectKey(name: "P", created: raw), GuideStore.projectKey(name: "P", created: stored))
    }

    func testChoosingAnotherGoal_clearsSkips() {
        var s = GuideState()
        s.choose(.example)
        s.skipped = [.checkSignal]
        s.choose(.example)
        XCTAssertEqual(s.skipped, [.checkSignal], "the same goal keeps its skips")
        s.choose(.record)
        XCTAssertEqual(s.skipped, [])
        s.skipped = [.connect]
        s.unskip(.connect)
        XCTAssertEqual(s.skipped, [])
    }

    // MARK: The card's step window

    func testWindow_foldsDoneThenCurrentAndNextTwo() {
        let s = S(recordings: [rec(cued, cued: true)], resultRecordings: [cuedResult: cued])
        let p = GuideProgress(goal: .live, snapshot: s, marks: [.protocolsVisited, .result(cuedResult)], skipped: [])
        let w = p.window(showsAll: false)
        XCTAssertEqual(w.foldedDone, 5)
        XCTAssertEqual(w.rows.map(\.id), [.freeze, .checkReplay, .runLive])
        XCTAssertEqual(w.more, 1)
        XCTAssertEqual(GuideCopy.folded(done: w.foldedDone, skipped: 0), "5 done")
        XCTAssertEqual(p.window(showsAll: true).rows.count, 9)
        XCTAssertFalse(p.window(showsAll: true).hasFold)
    }

    func testWindow_foldsSkipsAndFinishedFoldsAll() {
        let p = GuideProgress(goal: .example, snapshot: S(recordings: [rec(imported)]), marks: [.recordingOpened], skipped: [.checkSignal])
        let w = p.window(showsAll: false)
        XCTAssertEqual(w.foldedDone, 1)
        XCTAssertEqual(w.foldedSkipped, [.checkSignal])
        XCTAssertEqual(w.rows.first?.state, .current)
        XCTAssertEqual(GuideCopy.folded(done: 1, skipped: 1), "1 done · 1 skipped")
        let done = GuideProgress(goal: .record, snapshot: S(), marks: [], skipped: Set(GuideGoal.record.steps))
        XCTAssertEqual(done.window(showsAll: false).rows, [])
        XCTAssertEqual(done.window(showsAll: false).foldedSkipped.count, 5)
    }

    func testNewlyDone_listsStepsThatTickedOff() {
        let before = GuideProgress(goal: .example, snapshot: S(recordings: [rec(imported)]), marks: [.recordingOpened], skipped: [])
        let after = GuideProgress(goal: .example, snapshot: S(recordings: [rec(imported)]), marks: [.recordingOpened, .quality(imported)], skipped: [])
        XCTAssertEqual(after.newlyDone(since: before.doneIDs).map(\.id), [.checkSignal])
        XCTAssertEqual(GuideCopy.stepDone(GuideStep.step(.checkSignal)), "Step done: Check its signal")
    }

    func testMarks_rawValuesRoundTrip() {
        let id = UUID()
        for m in [GuideMark.recordingOpened, .montageViewed, .previewWatched, .protocolsVisited, .quality(id), .result(id), .liveRunCard(id)] {
            XCTAssertEqual(GuideMark(rawValue: m.rawValue), m)
        }
    }
}
