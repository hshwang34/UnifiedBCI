import XCTest
@testable import BCIWorkspace

/// Brief 003 part A (test plan §A, items 1–13, and §C edge cases): the intro's steps and
/// copy, navigation and keys, the first-run flag, the motion policy, the neural-field maths
/// and the frame statistics. Pure logic; no rendering.
@MainActor
final class IntroTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bci-intro-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Criterion 1, 5, 6 — first run (lead default 6)

    func testFirstRun_presentsOnceAndMarksOnPresentation() {
        let firstRun = FirstRun(defaults: defaults)
        XCTAssertTrue(firstRun.shouldPresent())
        firstRun.markPresented()
        // E2/E6: quitting mid-intro after presentation never replays it.
        XCTAssertFalse(FirstRun(defaults: defaults).shouldPresent())
        XCTAssertTrue(firstRun.shouldPresent(reset: true), "-BCIResetFirstRun forces it")
    }

    func testFirstRun_garbageValueDoesNotCrash() {
        defaults.set("garbage", forKey: FirstRun.key)
        XCTAssertTrue(FirstRun(defaults: defaults).shouldPresent())
        defaults.set(Data([1, 2, 3]), forKey: FirstRun.key)
        XCTAssertTrue(FirstRun(defaults: defaults).shouldPresent())
    }

    func testPresentIfNeeded_setsTheFlagOnPresentationAndNeverTwice() {
        let firstRun = FirstRun(defaults: defaults)
        var flow = WelcomeFlow()
        XCTAssertTrue(firstRun.presentIfNeeded(flow: &flow))
        XCTAssertEqual(flow.mode, .intro(step: 0))
        XCTAssertTrue(defaults.bool(forKey: FirstRun.key), "set the moment it is presented, not when it ends")
        // A later launch (a fresh flow) does not present again.
        var next = WelcomeFlow()
        XCTAssertFalse(FirstRun(defaults: defaults).presentIfNeeded(flow: &next))
        XCTAssertEqual(next.mode, .welcome)
        // Debug: a step or a reset forces it.
        XCTAssertTrue(firstRun.presentIfNeeded(flow: &next, introStep: 2))
        XCTAssertEqual(next.mode, .intro(step: 2))
        var reset = WelcomeFlow()
        XCTAssertTrue(firstRun.presentIfNeeded(flow: &reset, reset: true))
    }

    func testWorkspaceGate_decidesOncePerLaunch() {
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        XCTAssertTrue(workspace.presentIntroIfFirstRun(FirstRun(defaults: defaults)))
        workspace.welcomeFlow.apply(.skip)
        // The Welcome window reopening asks again: no second intro, even with a reset.
        XCTAssertFalse(workspace.presentIntroIfFirstRun(FirstRun(defaults: defaults), reset: true))
        XCTAssertEqual(workspace.welcomeFlow.mode, .welcome)
    }

    func testReplay_restartsAtStepZeroAndKeepsTheFlag() {
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        workspace.presentIntroIfFirstRun(FirstRun(defaults: defaults))
        workspace.welcomeFlow.apply(.next); workspace.welcomeFlow.apply(.next)
        let generation = workspace.welcomeFlow.generation
        // Help > Show Welcome Tour, mid-intro (E4) and after it (E5).
        workspace.showWelcomeTour()
        XCTAssertEqual(workspace.welcomeFlow.mode, .intro(step: 0))
        XCTAssertEqual(workspace.welcomeFlow.generation, generation + 1)
        workspace.welcomeFlow.apply(.skip)
        workspace.showWelcomeTour()
        XCTAssertEqual(workspace.welcomeFlow.mode, .intro(step: 0))
        XCTAssertTrue(workspace.sessions.isEmpty, "a replay opens no project")
        XCTAssertFalse(FirstRun(defaults: defaults).shouldPresent(), "a replay never clears the flag")
    }

    // MARK: Criterion 2 — four steps

    func testSteps_orderAndContent() {
        XCTAssertEqual(IntroModel.steps.map(\.kind), [.whatItDoes, .honestUncertainty, .tryExample, .hardwarePhase2])
        for s in IntroModel.steps {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertFalse(s.body.isEmpty)
            // VoiceOver: title then body.
            XCTAssertEqual(s.accessibilityLabel, "\(s.title). \(s.body)")
        }
        XCTAssertTrue(IntroModel.steps[3].body.contains("phase 2"))
        XCTAssertTrue(IntroModel.steps[2].body.contains("Explore an example"))
        XCTAssertEqual(IntroModel.announcement(1), "Step 2 of 4. \(IntroModel.steps[1].accessibilityLabel)")
        XCTAssertEqual(IntroModel.nextTitle(at: 0), "Next")
        XCTAssertEqual(IntroModel.nextTitle(at: 3), "Get Started")
    }

    // MARK: Criterion 13 — decision #8 wording, a range and no claim

    func testUncertaintyStep_wordingRules() {
        let step = IntroModel.steps[1]
        let text = (step.title + " " + step.body + " " + IntroModel.Illustration.caption).lowercased()
        for claim in ["balanced accuracy", "balanced-accuracy", "accurate", "reliable", "guarantee", "state-of-the-art",
                      "high accuracy", "best", "%  accuracy", "outperform", "proven"] {
            XCTAssertFalse(text.contains(claim), claim)
        }
        // Decision #8 form: "Accuracy Y · 95 % CI a–b (trial-level, n)".
        let caption = IntroModel.Illustration.caption
        XCTAssertTrue(caption.hasPrefix("Illustration, not a result"), caption)
        XCTAssertTrue(caption.contains("Accuracy 0.62 · 95 % CI 0.47–0.76 (trial-level, n = 45)"), caption)
        // A range that includes chance, around the point estimate.
        let i = IntroModel.Illustration.interval
        XCTAssertTrue(i.contains(IntroModel.Illustration.value))
        XCTAssertTrue(i.contains(IntroModel.Illustration.chance))
        XCTAssertEqual(IntroModel.Illustration.value, Double(IntroModel.Illustration.correct) / Double(IntroModel.Illustration.trials))
        for s in IntroModel.steps { XCTAssertFalse(s.body.lowercased().contains("neuralink"), "decision #9: own motifs only") }
    }

    // MARK: Criteria 3, 4 — navigation and keys

    /// What the views actually wire: the intro's onKeyPress keys, Skip's command (Esc), the
    /// welcome card's activation keys, and first-press-only phases for all of them.
    func testKeys_asWired() {
        XCTAssertEqual(IntroKeys.introKeys.map(IntroKeys.command(for:)), [.back, .next, .next])
        XCTAssertEqual(IntroKeys.skipCommand, .skip)
        XCTAssertNil(IntroKeys.command(for: .space), "space is not an intro key")
        XCTAssertEqual(IntroKeys.activateKeys, [.return, .space])
        // A held key never repeats: no running past the last step, and a held Return on
        // "Get Started" can't then open the Explore panel.
        XCTAssertEqual(IntroKeys.phases, .down)
        XCTAssertFalse(IntroKeys.phases.contains(.repeat))
        var flow = WelcomeFlow()
        flow.start(at: 3)
        flow.apply(IntroKeys.command(for: .return)!)
        XCTAssertEqual(flow.mode, .welcome)
        XCTAssertEqual(flow.focus, .exploreExample)
    }

    func testNext_fourTimesEndsOnWelcomeWithExploreFocused() {
        var flow = WelcomeFlow()
        flow.start()
        for expected in 1..<4 {
            flow.apply(.next)
            XCTAssertEqual(flow.step, expected)
        }
        flow.apply(.next)
        XCTAssertEqual(flow.mode, .welcome)
        XCTAssertEqual(flow.focus, .exploreExample)
        flow.consumeFocus()
        XCTAssertNil(flow.focus)
        // Commands outside the intro do nothing.
        flow.apply(.next)
        XCTAssertEqual(flow.mode, .welcome)
    }

    func testBack_clampsAtFirstStep() {
        var flow = WelcomeFlow()
        flow.start()
        flow.apply(.back)
        XCTAssertEqual(flow.step, 0)
        flow.apply(.next); flow.apply(.next); flow.apply(.back)
        XCTAssertEqual(flow.step, 1)
    }

    func testSkip_fromEveryStepLandsOnWelcome() {
        for step in 0..<IntroModel.steps.count {
            var flow = WelcomeFlow()
            flow.start(at: step)
            flow.apply(WelcomeFlow.command(for: .escape))
            XCTAssertEqual(flow.mode, .welcome, "step \(step)")
            XCTAssertEqual(flow.focus, .exploreExample)
        }
    }

    func testStart_clampsAndRestarts() {
        var flow = WelcomeFlow()
        flow.start(at: 99)
        XCTAssertEqual(flow.step, 3)
        flow.start(at: -4)
        XCTAssertEqual(flow.step, 0)
        // E4: a replay during the intro restarts at step 0 with a new clock generation.
        flow.apply(.next)
        let generation = flow.generation
        flow.start()
        XCTAssertEqual(flow.step, 0)
        XCTAssertEqual(flow.generation, generation + 1)
    }

    // MARK: Criteria 6, 8, 9 — motion policy

    func testPolicy_reduceMotionStillsEverything() {
        let p = MotionPolicy(reduceMotion: true)
        XCTAssertFalse(p.animates)
        XCTAssertTrue(p.timelinePaused)
        XCTAssertEqual(p.particleCount, 0)
        XCTAssertFalse(p.morphsGlass)
    }

    func testPolicy_lowPowerOcclusionTransparency() {
        let full = MotionPolicy()
        XCTAssertTrue(full.animates)
        XCTAssertFalse(full.timelinePaused)
        XCTAssertEqual(full.particleCount, MotionPolicy.fullParticles)
        XCTAssertTrue(full.morphsGlass)
        XCTAssertLessThan(MotionPolicy(lowPower: true).particleCount, full.particleCount, "E11")
        XCTAssertTrue(MotionPolicy(occluded: true).timelinePaused, "E10")
        let rt = MotionPolicy(reduceTransparency: true)
        XCTAssertTrue(rt.solidSurfaces)
        XCTAssertFalse(rt.morphsGlass)
    }

    func testStepsUseTheSharedTableAndHead() {
        // Criterion 21: the example step lights the bundled recording's own 16 sites, all of
        // which are rows of the same table the montage view places from.
        let lit = IntroModel.litLabels(for: .tryExample)!
        XCTAssertEqual(lit, Set(MontageTests.exampleLabels))
        XCTAssertTrue(lit.allSatisfy { StandardPositions.byLabel[$0] != nil })
        XCTAssertEqual(IntroModel.orbit(for: .tryExample), Orbit.Preset.top.orbit)
        XCTAssertNil(IntroModel.litLabels(for: .whatItDoes))
        XCTAssertEqual(IntroModel.litLabels(for: .hardwarePhase2), [])
    }

    // MARK: Criterion 6 — neural field maths

    func testParticles_deterministicAndInBounds() {
        for t in stride(from: 0.0, to: 30, by: 0.37) {
            let a = NeuralField.particles(at: t, count: 64, nodes: 16)
            XCTAssertEqual(a, NeuralField.particles(at: t, count: 64, nodes: 16))
            XCTAssertEqual(a.count, 64)
            for p in a {
                XCTAssertTrue((0..<16).contains(p.from) && (0..<16).contains(p.to))
                XCTAssertNotEqual(p.from, p.to)
                XCTAssertTrue((0...1).contains(p.progress))
                XCTAssertTrue((0...1).contains(p.opacity))
                XCTAssertTrue((-1...1).contains(p.bow))
            }
        }
        XCTAssertNotEqual(NeuralField.particles(at: 1, count: 8, nodes: 16, seed: 1), NeuralField.particles(at: 1, count: 8, nodes: 16, seed: 2))
        XCTAssertTrue(NeuralField.particles(at: 1, count: 8, nodes: 1).isEmpty)
        XCTAssertTrue(NeuralField.particles(at: 1, count: 0, nodes: 16).isEmpty)
    }

    func testTrace_boundedAndProgressMonotonic() {
        for i in 0...1000 { XCTAssertTrue((-1...1).contains(NeuralField.trace(Double(i) / 1000))) }
        var last = -1.0
        for t in stride(from: 0.0, to: NeuralField.tracePeriod * 0.999, by: 0.01) {
            let p = NeuralField.traceProgress(at: t)
            XCTAssertGreaterThanOrEqual(p, last)
            XCTAssertTrue((0...1).contains(p))
            last = p
        }
        XCTAssertEqual(NeuralField.traceProgress(at: NeuralField.tracePeriod * 0.9), 1)
        for t in stride(from: 0.0, to: 10, by: 0.1) {
            XCTAssertTrue((0...1).contains(NeuralField.glow(distance: 0.05, at: t)))
        }
    }

    // MARK: Criterion 7 — frame statistics

    func testFrameStats() {
        var s = FrameStats()
        XCTAssertEqual(s.percentile(99), 0)
        for _ in 0..<98 { s.add(1000.0 / 60) }
        s.add(33.4)
        s.add(.nan)
        s.add(-1)
        XCTAssertEqual(s.count, 99)
        XCTAssertEqual(s.dropped, 1)
        XCTAssertEqual(s.max, 33.4)
        XCTAssertEqual(s.percentile(50), 1000.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(s.percentile(100), 33.4)
        XCTAssertTrue(s.summary.contains("dropped(>25 ms) 1"), s.summary)
    }
}
