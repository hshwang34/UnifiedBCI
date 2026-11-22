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
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func open() async throws -> ProjectSession {
        // No worker: the guide never needs one.
        let store = try ProjectStore.open(at: project)
        return await ProjectSession.adopt(store, url: project, launch: nil)
    }

    func testDefaultsUnderTests_areNotTheAppsOwn() {
        XCTAssertNotEqual(ProjectSession.guideDefaults, UserDefaults.standard)
    }

    func testPicker_asksOnceAndGoalPersistsAcrossReopen() async throws {
        let s = try await open()
        defer { Task { await s.shutdown() } }
        XCTAssertNil(s.guideProgress)
        XCTAssertFalse(s.showsGuideCard)
        s.askForGuideGoalIfNeeded()
        XCTAssertTrue(s.showsGuidePicker)
        s.guideNotNow()
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

/// Brief 007 PR 4: Show me rings the step's control for about 2 s, and the card gives the
/// disabled control's own reason.
@MainActor
final class GuideShowMeTests: XCTestCase {
    func testSpotlight_ringsThenClears() async {
        let s = GuideSpotlight()
        s.duration = .milliseconds(50)
        s.highlight(.recordButton, after: .zero)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(s.anchor, .recordButton)
        let first = s.token
        await s.awaitHighlight()
        XCTAssertNil(s.anchor)
        s.highlight(.recordButton, after: .zero)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(s.token, first, "ringing the same control again restarts the ring")
        s.clear()
        XCTAssertNil(s.anchor)
        XCTAssertEqual(GuideSpotlight.duration, .seconds(2))
    }

    func testEveryAnchor_isSomeStepsTarget() {
        let used = Set(GuideStep.ID.allCases.map { GuideStep.step($0).target.anchor })
        XCTAssertEqual(used, Set(GuideAnchor.allCases))
    }

    func testShowMe_ringsAndOpensTheInspectorForEvaluate() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-showme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        let s = await ProjectSession.adopt(store, url: project, launch: nil)
        defer { Task { await s.shutdown() } }
        s.spotlight.duration = .seconds(1)
        s.showInspector = false
        s.section = .results
        s.showGuideTarget(GuideStep.step(.evaluate))
        XCTAssertEqual(s.section, .recordings)
        XCTAssertTrue(s.showInspector)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(s.spotlight.anchor, .evaluateButton, "rung after the navigation delay")
        await s.spotlight.awaitHighlight()
        XCTAssertNil(s.spotlight.anchor, "cleared after the duration")
    }

    func testDisabledReason_isTheControlsTooltip() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-showme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        let s = await ProjectSession.adopt(store, url: project, launch: nil)
        defer { Task { await s.shutdown() } }
        // Nothing frozen: Replay's reason is Live Test's "no models" line.
        XCTAssertEqual(s.guideDisabledReason(.checkReplay), LiveRunCopy.noModels)
        XCTAssertEqual(s.guideDisabledReason(.runLive), s.liveStartDisabledReason)
        XCTAssertNotNil(s.guideDisabledReason(.runLive))
        // No board: Record isn't on screen, so the card claims no reason for it.
        XCTAssertNil(s.guideDisabledReason(.record))
        // The fixture has enough runs: Evaluate can run.
        XCTAssertTrue(s.canEvaluate)
        XCTAssertNil(s.guideDisabledReason(.evaluate))
        s.liveShown = true   // the Live row selected, even with no board (no live row)
        XCTAssertEqual(s.guideDisabledReason(.evaluate), GuideCopy.liveScreenShown)
        s.liveShown = false
        s.selectedRecordingID = nil
        XCTAssertEqual(s.guideDisabledReason(.evaluate), GuideCopy.selectRecording)
        XCTAssertEqual(s.evaluateDisabledReason, GuideCopy.selectRecording)
    }
}

/// Review of PR 4: Evaluate's disabled reason names the actual condition, branch by branch.
final class EvaluateReasonTests: XCTestCase {
    private func reason(recording: Bool = true, running: Bool = false, live: Bool = false, liveRun: Bool = false, enough: Bool = true) -> String? {
        GuideCopy.evaluateDisabledReason(hasRecording: recording, isRunning: running, liveShown: live, isLiveRunning: liveRun,
                                         enoughRuns: enough) { "RUNS" }
    }

    func testEachBranchHasItsOwnReason() {
        XCTAssertNil(reason())
        XCTAssertEqual(reason(recording: false), GuideCopy.selectRecording)
        XCTAssertEqual(reason(running: true), "An evaluation is running.")
        XCTAssertEqual(reason(live: true), GuideCopy.liveScreenShown)
        XCTAssertEqual(reason(liveRun: true), LiveRunCopy.pausedDuringLive)
        XCTAssertEqual(reason(enough: false), "RUNS")
    }

    func testRunCountSentenceOnlyWhenRunsAreMissing() {
        for (r, run, l, lr) in [(false, false, false, false), (true, true, false, false), (true, false, true, false), (true, false, false, true)] {
            XCTAssertNotEqual(reason(recording: r, running: run, live: l, liveRun: lr, enough: false), "RUNS")
        }
    }
}
