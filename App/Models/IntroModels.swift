import Foundation

// The first-run intro (brief 003, decisions #13 and #14): its copy, its navigation, the
// first-run flag, the motion policy and the deterministic maths behind the neural field.
// Views stay thin: everything here is testable without rendering.

// MARK: - Steps

struct IntroStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case whatItDoes, honestUncertainty, tryExample, hardwarePhase2 }

    let kind: Kind
    let title: String
    let body: String
    var id: Kind { kind }

    /// VoiceOver: the title, then the body (brief 003, VoiceOver criterion).
    var accessibilityLabel: String { "\(title). \(body)" }
}

enum IntroModel {
    static let steps: [IntroStep] = [
        IntroStep(kind: .whatItDoes,
                  title: "Experiments you can reproduce",
                  body: "Import a recording, inspect its channels and events, and evaluate a decoding pipeline. Recordings, pipelines and results stay unchanged in one project folder, so any result can be run again and checked."),
        // Decision #8 wording: the interval is called an accuracy CI (trial-level), never a
        // balanced-accuracy interval, and nothing here promises a level of performance.
        IntroStep(kind: .honestUncertainty,
                  title: "Every result shows its uncertainty",
                  body: "A session gives a few dozen trials, so one number can't pin accuracy down. Results show the accuracy with its 95 % interval and the chance level beside it. A wide interval is the honest answer, not a fault."),
        IntroStep(kind: .tryExample,
                  title: "Try it without hardware",
                  body: "Explore an example opens a public motor-imagery recording (PhysioNet EEGMMIDB, subject S001, 16 channels over the motor strip) in a new project. Nothing to connect."),
        IntroStep(kind: .hardwarePhase2,
                  title: "Live hardware arrives in phase 2",
                  body: "Recording from an OpenBCI Cyton + Daisy board comes in phase 2. Until then, every screen works on recorded data."),
    ]

    /// Step 2's range, labelled as an illustration. A real Clopper-Pearson interval for 28 of
    /// 45 trials (scipy.stats.beta: 0.465–0.762), so even the example arithmetic is honest;
    /// it includes chance, which is the point of the step.
    enum Illustration {
        static let correct = 28, trials = 45
        static let value = 28.0 / 45.0
        static let interval = 0.465...0.762
        static let chance = 0.5
        static var caption: String {
            "Illustration, not a result: Accuracy \(Fmt.fixed(value)) · 95 % CI \(Fmt.fixed(interval.lowerBound))–\(Fmt.fixed(interval.upperBound)) (trial-level, n = \(trials)). This interval includes chance."
        }
        static let accessibilityLabel = "Illustrative accuracy interval"
    }

    /// The Return / Next button's title on step `index`.
    static func nextTitle(at index: Int) -> String { index >= steps.count - 1 ? "Get Started" : "Next" }

    static func position(_ index: Int) -> String { "Step \(index + 1) of \(steps.count)" }

    /// What VoiceOver announces when a step appears.
    static func announcement(_ index: Int) -> String { "\(position(index)). \(steps[index].accessibilityLabel)" }

    /// Which 10-10 sites glow on each step. The example step lights exactly the bundled
    /// recording's 16 channels, so the intro's map matches the Recording screen's head.
    static let exampleLabels = ["FC3", "FC1", "FC2", "FC4", "C5", "C3", "C1", "Cz", "C2", "C4", "C6", "CP3", "CP1", "CPz", "CP2", "CP4"]

    static func litLabels(for kind: IntroStep.Kind) -> Set<String>? {
        switch kind {
        case .whatItDoes, .honestUncertainty: return nil         // nil = every site
        case .tryExample: return Set(exampleLabels)
        case .hardwarePhase2: return []
        }
    }

    /// The head's view on each step; the stage orbits between them (snaps under Reduce Motion).
    static func orbit(for kind: IntroStep.Kind) -> Orbit {
        switch kind {
        case .whatItDoes: return Orbit.default
        case .honestUncertainty: return Orbit(yaw: -72, pitch: 16)
        case .tryExample: return Orbit.Preset.top.orbit
        case .hardwarePhase2: return Orbit(yaw: 32, pitch: 8)
        }
    }

    /// The example step labels its 16 sites, as the Recording screen does.
    static func showsLabels(_ kind: IntroStep.Kind) -> Bool { kind == .tryExample }
}

// MARK: - Navigation

enum IntroKey: Equatable { case leftArrow, rightArrow, returnKey, escape }

enum IntroCommand: Equatable { case back, next, skip }

/// Which screen the Welcome window shows, and where keyboard focus lands.
struct WelcomeFlow: Equatable {
    enum Mode: Equatable { case welcome, intro(step: Int) }
    enum Focus: Equatable { case exploreExample }

    private(set) var mode: Mode = .welcome
    /// Set when the intro ends, so "Explore an example" takes focus (brief 003).
    private(set) var focus: Focus?
    /// Bumped on every start, so a replay restarts the animation clock instead of overlapping.
    private(set) var generation = 0

    var step: Int? { if case .intro(let s) = mode { return s } else { return nil } }
    var isIntro: Bool { step != nil }

    static func command(for key: IntroKey) -> IntroCommand {
        switch key {
        case .leftArrow: return .back
        case .rightArrow, .returnKey: return .next
        case .escape: return .skip
        }
    }

    mutating func start(at step: Int = 0) {
        mode = .intro(step: min(max(step, 0), IntroModel.steps.count - 1))
        focus = nil
        generation += 1
    }

    mutating func apply(_ command: IntroCommand) {
        guard let s = step else { return }
        switch command {
        case .back: mode = .intro(step: max(0, s - 1))
        case .next: if s >= IntroModel.steps.count - 1 { finish() } else { mode = .intro(step: s + 1) }
        case .skip: finish()
        }
    }

    mutating func finish() {
        mode = .welcome
        focus = .exploreExample
    }

    mutating func consumeFocus() { focus = nil }
}

/// The first-run flag (lead default 6): set when the intro is first presented, so quitting
/// mid-intro never replays it; a replay from Help never clears it.
struct FirstRun {
    static let key = "BCIHasSeenWelcomeTour"
    let defaults: UserDefaults

    /// `reset` is the Debug `-BCIResetFirstRun YES`. A garbage stored value reads as false
    /// (`bool(forKey:)`), which shows the intro once rather than crashing.
    func shouldPresent(reset: Bool = false) -> Bool { reset || !defaults.bool(forKey: Self.key) }

    func markPresented() { defaults.set(true, forKey: Self.key) }

    /// Starts the intro in `flow` if this is a first run (or Debug asks for a step or a
    /// reset), and sets the flag in the same moment. Returns whether it presented.
    @discardableResult
    func presentIfNeeded(flow: inout WelcomeFlow, reset: Bool = false, introStep: Int? = nil) -> Bool {
        if let introStep {
            flow.start(at: introStep)
        } else if shouldPresent(reset: reset) {
            flow.start(at: 0)
        } else {
            return false
        }
        markPresented()
        return true
    }
}

// MARK: - Motion policy

/// What the intro may animate, from the accessibility settings and Low Power Mode.
struct MotionPolicy: Equatable {
    var reduceMotion = false
    var reduceTransparency = false
    var lowPower = false
    var occluded = false

    static let fullParticles = 64
    static let lowPowerParticles = 20

    /// Reduce Motion: no drift, trace or morph; still, designed frames (brief 003).
    var animates: Bool { !reduceMotion }
    /// The timeline runs only when something moves and the window is visible.
    var timelinePaused: Bool { reduceMotion || occluded }
    var particleCount: Int { reduceMotion ? 0 : lowPower ? Self.lowPowerParticles : Self.fullParticles }
    var morphsGlass: Bool { !reduceMotion && !reduceTransparency }
    var solidSurfaces: Bool { reduceTransparency }
    /// The time a still frame is drawn at: chosen so the electrode wave reads well.
    static let stillTime = 1.15
}

// MARK: - Neural field

/// Deterministic animation maths: everything is a pure function of time and a seed, so a
/// frame holds no mutable state and a still frame is just one fixed time.
enum NeuralField {
    struct Particle: Equatable {
        /// Indices into the lit nodes.
        let from: Int, to: Int
        /// 0…1 along the arc.
        let progress: Double
        /// 0…1, fading in and out over the trip.
        let opacity: Double
        /// −1…1: which side the arc bows to, and how far.
        let bow: Double
        let size: Double
    }

    /// SplitMix64: a tiny stable hash for per-particle randomness.
    static func hash(_ a: UInt64, _ b: UInt64 = 0) -> UInt64 {
        var z = a &* 0x9E37_79B9_7F4A_7C15 &+ b &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func unit(_ h: UInt64) -> Double { Double(h >> 11) / Double(1 << 53) }

    /// `count` particles, each travelling between two of `nodes` lit electrodes, at time `t`.
    static func particles(at t: Double, count: Int, nodes: Int, seed: UInt64 = 7) -> [Particle] {
        guard nodes >= 2, count > 0 else { return [] }
        return (0..<count).map { i in
            let h = hash(seed, UInt64(i))
            let period = 2.2 + 2.6 * unit(hash(h, 1))
            let phase = unit(hash(h, 2)) * period
            let cycle = ((t + phase) / period).rounded(.down)
            let u = (t + phase) / period - cycle
            let hc = hash(h, UInt64(bitPattern: Int64(cycle)))
            let from = Int(hc % UInt64(nodes))
            var to = Int(hash(hc, 3) % UInt64(nodes - 1))
            if to >= from { to += 1 }
            let eased = u * u * (3 - 2 * u)
            return Particle(from: from, to: to, progress: eased, opacity: sin(.pi * u),
                            bow: unit(hash(hc, 4)) * 2 - 1, size: 1.5 + 2 * unit(hash(h, 5)))
        }
    }

    /// The synthetic trace at x ∈ 0…1, in −1…1: an alpha-band rhythm whose amplitude drops
    /// in the middle third (the event-related desynchronization motor imagery looks for), over
    /// slow drift. Illustrative, not data.
    static func trace(_ x: Double) -> Double {
        let envelope = 1 - 0.6 * exp(-pow((x - 0.55) / 0.12, 2))
        let alpha = sin(2 * .pi * 11 * x) * 0.55 * envelope
        let beta = sin(2 * .pi * 23 * x + 1.3) * 0.16
        let drift = sin(2 * .pi * 1.3 * x + 0.4) * 0.22
        return max(-1, min(1, alpha + beta + drift))
    }

    static let tracePeriod = 5.0

    /// How much of the trace is drawn at `t`: 0→1 over 80 % of the period, then held.
    static func traceProgress(at t: Double, period: Double = tracePeriod) -> Double {
        let u = t.truncatingRemainder(dividingBy: period) / period
        return min(1, max(0, u / 0.8))
    }

    /// An electrode's glow at `t`: a wave spreading out from the vertex, 0…1.
    /// `distance` is the site's distance from Cz in the scene (metres).
    static func glow(distance: Double, at t: Double) -> Double {
        let w = sin(2 * .pi * (t / 2.4 - distance * 7))
        return 0.35 + 0.65 * pow(max(0, w), 2)
    }
}

// MARK: - Frame timing

/// Frame intervals of the intro's timeline, for the 60 fps criterion (brief 003). Each
/// interval is also emitted as an os_signpost (`IntroFrameClock`), so Instruments can
/// show the same numbers.
struct FrameStats: Equatable {
    private(set) var intervals: [Double] = []   // milliseconds
    static let budget = 1000.0 / 60

    mutating func add(_ ms: Double) { if ms.isFinite, ms > 0 { intervals.append(ms) } }

    var count: Int { intervals.count }
    var mean: Double { intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count) }
    var max: Double { intervals.max() ?? 0 }

    func percentile(_ p: Double) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted()
        let rank = Int((p / 100 * Double(sorted.count - 1)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }

    /// Intervals longer than 1.5 frames: at least one frame missed.
    var dropped: Int { intervals.filter { $0 > Self.budget * 1.5 }.count }

    var summary: String {
        "frames \(count) · mean \(Fmt.fixed(mean)) ms · p50 \(Fmt.fixed(percentile(50))) ms · p99 \(Fmt.fixed(percentile(99))) ms · max \(Fmt.fixed(max)) ms · dropped(>25 ms) \(dropped)"
    }
}
