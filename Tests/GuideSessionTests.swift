import XCTest
@testable import BCIWorkspace

/// Brief 007 PR 3: the guide wired to a real `ProjectSession` (tiny fixture): visited marks,
/// the picker asked once, the snapshot from real state, and "Show me" navigation.
@MainActor
final class GuideSessionTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-guide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("tiny.bciproj")
        _ = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        UserDefaults().removePersistentDomain(forName: ProjectSession.testGuideSuite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults().removePersistentDomain(forName: ProjectSession.testGuideSuite)
        ProjectSession.guideDwell = .seconds(3)
    }

    private func open() async throws -> ProjectSession {
        // No worker: the guide never needs one.
        let store = try ProjectStore.open(at: project)
        return await ProjectSession.adopt(store, url: project, launch: nil)
    }

    func testDefaultsUnderTests_areNotTheAppsOwn() {
        XCTAssertNotNil(ProjectSession.guideDefaults)
        XCTAssertNotEqual(ProjectSession.guideDefaults, UserDefaults.standard)
    }

    func testPicker_asksOnceAndGoalPersistsAcrossReopen() async throws {
        let s = try await open()
        defer { Task { await s.shutdown() } }
        XCTAssertNil(s.guideProgress)
        XCTAssertFalse(s.showsGuideCard)
        s.askForGuideGoalIfNeeded()
        XCTAssertTrue(s.showsGuidePicker)
        XCTAssertFalse(s.guide.askedOnce, "asked is saved when the picker is answered, not when shown")
        s.guideNotNow()
        XCTAssertTrue(s.guide.askedOnce)
        s.askForGuideGoalIfNeeded()
        XCTAssertFalse(s.showsGuidePicker, "Not now: never asks again")
        s.presentGuidePicker()
        s.chooseGuideGoal(.example)
        XCTAssertTrue(s.showsGuideCard)

        let again = try await open()
        defer { Task { await again.shutdown() } }
        XCTAssertEqual(again.guideKey, s.guideKey)
        XCTAssertEqual(again.guide.goal, .example)
        again.hideGuide()
        XCTAssertFalse(again.showsGuideCard)
        again.showGuide()
        XCTAssertTrue(again.showsGuideCard)
    }

    func testMarks_comeFromWhatIsOnScreen() async throws {
        let s = try await open()
        defer { Task { await s.shutdown() } }
        s.chooseGuideGoal(.example)
        let id = try XCTUnwrap(s.selectedRecordingID)
        XCTAssertTrue(s.guide.marks.contains(.recordingOpened), "the selected recording's detail is shown")
        XCTAssertFalse(s.guide.marks.contains(.quality(id)))
        XCTAssertEqual(s.guideSnapshot.recordings.map(\.isLive), [false], "the fixture is imported data")
        s.recordingTab = .quality
        XCTAssertTrue(s.guide.marks.contains(.quality(id)))
        let p = try XCTUnwrap(s.guideProgress)
        XCTAssertEqual(p.rows.map(\.state), [.done, .done, .current, .todo, .todo])
        s.skipGuideStep(.viewMontage)
        XCTAssertEqual(s.guideProgress?.current?.id, .evaluate)
        XCTAssertEqual(s.guideProgress?.rows[2].state, .skipped)
    }

    func testShowMe_navigatesToTheStepsSectionAndTab() async throws {
        let s = try await open()
        defer { Task { await s.shutdown() } }
        s.section = .pipelines
        s.showGuideTarget(GuideStep.step(.checkSignal))
        XCTAssertEqual(s.section, .recordings)
        XCTAssertEqual(s.recordingTab, .quality)
        s.showGuideTarget(GuideStep.step(.chooseProtocol))
        XCTAssertEqual(s.section, .protocols)
        s.showGuideTarget(GuideStep.step(.checkReplay))
        XCTAssertEqual(s.section, .pipelines)
    }
}

/// Fixes from the review of PRs 3 and 4 (brief 007).
@MainActor
final class GuideReviewFixTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-guidefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: ProjectSession.testGuideSuite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults().removePersistentDomain(forName: ProjectSession.testGuideSuite)
        ProjectSession.guideDwell = .seconds(3)
    }

    private func tiny() async throws -> ProjectSession {
        let project = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        return await ProjectSession.adopt(store, url: project, launch: nil)
    }

    /// New Project → choose a goal → close → reopen: the state is still there.
    func testNewProject_guideStateSurvivesReopen() async throws {
        let url = scratch.appendingPathComponent("New.bciproj")
        let created = try ProjectStore.create(at: url, name: "New")
        let s = await ProjectSession.adopt(created, url: url, launch: nil)
        s.chooseGuideGoal(.record)
        s.skipGuideStep(.connect)
        await s.shutdown()
        let again = try await ProjectSession.open(at: url, launch: nil)
        defer { Task { await again.shutdown() } }
        XCTAssertEqual(again.guideKey, s.guideKey)
        XCTAssertEqual(again.guide.goal, .record)
        XCTAssertEqual(again.guide.skipped, [.connect])
    }

    func testChooseProtocol_needsProtocolsVisited() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.chooseGuideGoal(.train)
        XCTAssertFalse(GuideRules.isDone(.chooseProtocol, s.guideSnapshot, marks: s.guide.marks))
        // Show me or a restored section: on screen, but not yet seen.
        ProjectSession.guideDwell = .milliseconds(500)
        var key = false
        s.guideWindowState = { key ? .key : .notKey }
        s.showGuideTarget(GuideStep.step(.chooseProtocol))
        XCTAssertEqual(s.section, .protocols)
        XCTAssertFalse(s.guide.marks.contains(.protocolsVisited))
        key = true
        await s.awaitGuideDwell()
        XCTAssertTrue(GuideRules.isDone(.chooseProtocol, s.guideSnapshot, marks: s.guide.marks), "3 s (here 0.5 s) in the key window")
    }

    func testChooseProtocol_userSelectionCountsAtOnce() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.section = .protocols
        XCTAssertFalse(s.guide.marks.contains(.protocolsVisited))
        s.userSelectedProtocol(nil)
        XCTAssertTrue(s.guide.marks.contains(.protocolsVisited))
    }

    func testDwell_stopsWhenTheWindowIsGoneOrTheSessionCloses() async throws {
        ProjectSession.guideDwell = .seconds(60)
        let s = try await tiny()
        s.guideWindowState = { .gone }
        s.section = .results
        s.selectedResultID = UUID()
        await s.awaitGuideDwell()   // returns at once: no window, no endless polling
        s.guideWindowState = { .notKey }
        s.selectedResultID = UUID()
        await s.shutdown()
        await s.awaitGuideDwell()   // shutdown cancels it
    }

    func testStepDone_notAnnouncedOnLoadOrGoalChange() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.chooseGuideGoal(.example)   // "Open a recording" is already done on load
        XCTAssertEqual(s.guideStepsNewlyDone(), [], "the first settled snapshot announces nothing")
        s.recordingTab = .quality
        XCTAssertEqual(s.guideStepsNewlyDone().map(\.id), [.checkSignal])
        XCTAssertEqual(s.guideStepsNewlyDone(), [])
        s.chooseGuideGoal(.record)
        XCTAssertEqual(s.guideStepsNewlyDone(), [], "a goal change is a new baseline")
    }

    func testReadResult_notOnAutoNavigation_onlyAfterDwellInKeyWindowOrUserSelection() async throws {
        ProjectSession.guideDwell = .milliseconds(500)
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        let a = UUID(), b = UUID()
        var key = false
        s.guideWindowState = { key ? .key : .notKey }
        // Auto-navigation (as after Evaluate): no mark while the window isn't key.
        s.section = .results
        s.selectedResultID = a
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(s.guide.marks.contains(.result(a)))
        // Key long enough: read.
        key = true
        await s.awaitGuideDwell()
        XCTAssertTrue(s.guide.marks.contains(.result(a)))
        // Moving away before the dwell ends: not read.
        s.selectedResultID = b
        try? await Task.sleep(for: .milliseconds(200))
        s.section = .recordings
        await s.awaitGuideDwell()
        XCTAssertFalse(s.guide.marks.contains(.result(b)))
        // The user's own selection counts at once.
        s.section = .results
        s.userSelectedResult(b)
        XCTAssertTrue(s.guide.marks.contains(.result(b)))
    }

    func testPicker_neverOverAnotherSheet() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.protocolEditor = nil
        s.showsConnectSheet = true
        XCTAssertTrue(s.isSheetUp)
        s.askForGuideGoalIfNeeded()
        s.presentGuidePicker()
        XCTAssertFalse(s.showsGuidePicker)
        s.showsConnectSheet = false
        s.presentGuidePicker()
        XCTAssertTrue(s.showsGuidePicker)
    }

    func testSkips_undoAndClearOnGoalChange() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.chooseGuideGoal(.example)
        s.skipGuideStep(.checkSignal)
        XCTAssertEqual(s.lastSkippedGuideStep, .checkSignal)
        s.unskipGuideStep(.checkSignal)
        XCTAssertEqual(s.guide.skipped, [])
        XCTAssertNil(s.lastSkippedGuideStep)
        s.skipGuideStep(.checkSignal)
        s.chooseGuideGoal(.record)
        XCTAssertEqual(s.guide.skipped, [])
        XCTAssertNil(s.lastSkippedGuideStep)
    }

    func testSkipThenSkip_onlyTheLastIsUndoable() async throws {
        let s = try await tiny()
        defer { Task { await s.shutdown() } }
        s.chooseGuideGoal(.record)
        s.skipGuideStep(.connect)
        XCTAssertEqual(s.lastSkippedGuideStep, .connect)
        s.skipGuideStep(.confirmMap)
        XCTAssertEqual(s.lastSkippedGuideStep, .confirmMap, "skip A then skip B: only B can be undone from the card")
        XCTAssertEqual(s.guide.skipped, [.connect, .confirmMap])
        // The current step changing for any other reason also ends the undo.
        s.unskipGuideStep(.confirmMap)
        s.skipGuideStep(.confirmMap)
        s.chooseGuideGoal(.record)
        XCTAssertEqual(s.lastSkippedGuideStep, .confirmMap, "same goal: still the current step after the skip")
    }
}
