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
        s.streamingSeconds = 9.9
        XCTAssertEqual(states(.record, s), [.done, .done, .current, .todo, .todo])
        s.streamingSeconds = 10
        XCTAssertEqual(states(.record, s), [.done, .done, .done, .current, .todo])
    }

    func testRecord_neverDoneUnlessTrue() {
        // A declared map or a long stream count only while streaming.
        let s = S(mapDeclared: true, streamingSeconds: 60)
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
        s.protocolCount = 1
        XCTAssertEqual(states(.train, s), [.done, .done, .current, .todo, .todo])
        s.recordings.append(rec(cued, cued: true))
        XCTAssertEqual(states(.train, s), [.done, .done, .done, .current, .todo])
        s.resultRecordings[cuedResult] = cued
        XCTAssertEqual(states(.train, s), [.done, .done, .done, .done, .current])
        XCTAssertTrue(GuideProgress(goal: .train, snapshot: s, marks: [.result(cuedResult)], skipped: []).isFinished)
    }

    // MARK: Live feedback

    func testLive_freezeReplayLiveRun() {
        var s = S(recordings: [rec(cued, cued: true)], resultRecordings: [cuedResult: cued], protocolCount: 1)
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

    func testStore_unknownValuesAreDroppedNotFatal() throws {
        let (store, cleanup) = store()
        defer { cleanup() }
        let json = #"{"goal":"compare","skipped":["freeze","teleport"],"hidden":true,"marks":["quality:not-a-uuid","montage","x:y"]}"#
        store.defaults.set(Data(json.utf8), forKey: GuideStore.keyPrefix + "p")
        let s = store.load("p")
        XCTAssertNil(s.goal)
        XCTAssertEqual(s.skipped, [.freeze])
        XCTAssertTrue(s.hidden)
        XCTAssertEqual(s.marks, [.montageViewed])
        store.defaults.set("garbage", forKey: GuideStore.keyPrefix + "q")
        XCTAssertEqual(store.load("q"), GuideState())
    }

    func testMarks_rawValuesRoundTrip() {
        let id = UUID()
        for m in [GuideMark.recordingOpened, .montageViewed, .previewWatched, .quality(id), .result(id), .liveRunCard(id)] {
            XCTAssertEqual(GuideMark(rawValue: m.rawValue), m)
        }
    }
}
