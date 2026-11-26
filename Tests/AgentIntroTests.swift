import XCTest
@testable import BCIWorkspace

/// Brief 008: agent control in the intro (its last step) and the one-time welcome card.
@MainActor
final class AgentIntroTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "bci-tests-agent-intro")
        defaults.removePersistentDomain(forName: "bci-tests-agent-intro")
    }

    func testIntroEndsOnAgentsStepThatSaysItIsOffByDefault() {
        let last = IntroModel.steps.last!
        XCTAssertEqual(last.kind, .agents)
        XCTAssertTrue(last.body.contains("off until you allow it"))
        XCTAssertTrue(last.body.contains("stay with you"), "human steps stay with the person (decision #48)")
        XCTAssertEqual(IntroModel.nextTitle(at: IntroModel.steps.count - 1), "Get Started")
        XCTAssertNil(IntroModel.litLabels(for: .agents))
    }

    func testCardShowsOnceToPeopleWhoSawTheIntroBefore() {
        let card = AgentIntroCard(defaults: defaults)
        XCTAssertFalse(card.shouldShow(), "a first run sees the intro's agents step instead")
        defaults.set(true, forKey: FirstRun.key)
        XCTAssertTrue(card.shouldShow())
        defaults.set(true, forKey: ControlSettings.enabledKey)
        XCTAssertFalse(card.shouldShow(), "never once control is on")
        defaults.removeObject(forKey: ControlSettings.enabledKey)
        card.markSeen()
        XCTAssertFalse(card.shouldShow(), "dismissed for good")
    }

    func testWorkspaceDecidesTheCardWithTheFirstRunGate() {
        defaults.set(true, forKey: FirstRun.key)
        let returning = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        XCTAssertFalse(returning.presentIntroIfFirstRun(FirstRun(defaults: defaults)))
        XCTAssertTrue(returning.showsAgentCard)

        defaults.removePersistentDomain(forName: "bci-tests-agent-intro")
        let first = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        XCTAssertTrue(first.presentIntroIfFirstRun(FirstRun(defaults: defaults)))
        XCTAssertFalse(first.showsAgentCard)
        first.welcomeAppeared()
        XCTAssertTrue(defaults.bool(forKey: AgentIntroCard.key), "the intro itself counts as seeing it")
    }
}
