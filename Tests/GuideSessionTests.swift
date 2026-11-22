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
