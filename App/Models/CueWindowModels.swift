import Foundation

/// One connected display as the participant-window picker sees it. Built from `NSScreen` in
/// the app, by hand in tests.
struct CueDisplayInfo: Equatable, Sendable, Identifiable {
    /// `CGDirectDisplayID`; can change when a display is re-plugged, so memory also keeps the name.
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    /// The display the operator's project window is on.
    let isOperator: Bool
}

/// Where the participant window goes (decision #36): a second display when one is connected,
/// otherwise full-screen on the only display with the operator working by keyboard. The
/// picker in Start run… remembers the last choice; a remembered display that is gone falls
/// back to the default.
struct CueDisplayChoice: Equatable, Sendable {
    let display: CueDisplayInfo
    /// The participant window covers the operator's window: aborts work by keyboard only.
    var sharesOperatorDisplay: Bool { display.isOperator }
}

enum CueDisplayPicker {
    struct Remembered: Codable, Equatable, Sendable {
        let id: UInt32
        let name: String
    }

    /// The default for `displays` given what was last chosen. Nil only with no display at all.
    static func choose(from displays: [CueDisplayInfo], remembered: Remembered?) -> CueDisplayChoice? {
        if let r = remembered,
           let match = displays.first(where: { $0.id == r.id && $0.name == r.name })
                ?? displays.first(where: { $0.name == r.name }) {
            return CueDisplayChoice(display: match)
        }
        if let second = displays.first(where: { !$0.isOperator }) { return CueDisplayChoice(display: second) }
        return displays.first.map(CueDisplayChoice.init(display:))
    }

    static let defaultsKey = "BCICueDisplay"

    static func remembered(in defaults: UserDefaults) -> Remembered? {
        // Our own small value, but still read defensively: a damaged entry means "none".
        guard let data = defaults.data(forKey: defaultsKey), data.count < 4096 else { return nil }
        return try? JSONDecoder().decode(Remembered.self, from: data)
    }

    static func remember(_ display: CueDisplayInfo, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(Remembered(id: display.id, name: display.name)) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

/// Copy and geometry of the participant window (brief 005 "Participant window", redesigned in
/// brief 010): neutral dark background, a centred fixation cross that the cue *replaces*
/// (decision #57: never drawn over it), blank rest. No branding, controls or numbers during
/// trials; feedback only in a live run (brief 006: the bar under the cue). Sizes are fractions
/// of the display's shorter side so the cues read the same from across a room on any display.
enum CueWindowModel {
    /// Background and ink as sRGB 0…1. Near-black and near-white: ~18:1, calm rather than glaring.
    static let background: (r: Double, g: Double, b: Double) = (0.075, 0.082, 0.098)
    static let ink: (r: Double, g: Double, b: Double) = (0.93, 0.94, 0.95)
    /// Secondary copy on the cards between trials (instructions footer, pause, break).
    static let inkSecondaryAlpha = 0.66
    static let inkSecondaryAlphaHighContrast = 0.9

    static let crossArm = 0.075          // half-length of each arm, × shorter side
    static let crossStroke = 0.012       // drawn with round ends
    static let arrowLength = 0.30        // the cue glyph's longer side, × shorter side
    // The drawn fallback arrow, used only if the SF Symbol can't be rendered.
    static let arrowShaft = 0.035
    static let arrowHead = 0.14          // head width, × shorter side
    static let arrowHeadLength = 0.11
    static let instructionsSize = 0.034  // font size, × shorter side
    static let instructionsWidth = 0.62  // × width

    // Live feedback (brief 006, decision #27): a bar under the cue, clear of every arrow.
    static let feedbackDrop = 0.24       // bar centre below the screen centre, × shorter side
    static let feedbackHalfWidth = 0.30  // full confidence reaches this far from the centre line
    static let feedbackHeight = 0.034    // a capsule; its ends are round
    static let feedbackTick = 0.07       // the centre line's height
    static let feedbackMinimum = 0.006   // a just-confident bar is still visible
    /// The same minimum as a fraction of the half-width (the operator's gauge uses it too).
    static var feedbackMinimumFraction: Double { feedbackMinimum / feedbackHalfWidth }
    static let feedbackTrackAlpha = 0.16
    static let feedbackTrackAlphaHighContrast = 0.32
    static let feedbackWordsSize = 0.032
    static let feedbackWordsAlpha = 0.78
    /// The bar's own colour (decision #59): a calm blue, ~9:1 on the background, so it never
    /// reads as part of the white cue glyph.
    static let feedbackBar: (r: Double, g: Double, b: Double) = (0.45, 0.72, 1.0)

    /// Cards between trials fade in this long (never a measured phase; Reduce Motion: instant).
    static let cardFadeSeconds = 0.45

    static func displayLabel(_ d: CueDisplayInfo) -> String {
        "\(d.name) (\(d.width) × \(d.height))" + (d.isOperator ? " · this window's display" : "")
    }

    static let sharedDisplayNote = "The participant window will cover this window. Use the keyboard: Space starts, Esc aborts the trial, ⌘. aborts the run."

    /// Debug preview (`-BCICueWindowPreview`) instructions.
    static let previewInstructions = "Watch the cross. When an arrow appears, imagine squeezing that hand until it goes away."

    static func symbolAngle(_ cue: CueSymbol) -> Double {
        switch cue {
        case .rightArrow: return 0
        case .upArrow: return .pi / 2
        case .leftArrow: return .pi
        case .downArrow: return -.pi / 2
        }
    }

    /// The SF Symbol each cue is drawn with (decision #57): a solid, rounded arrow shape,
    /// pre-rendered at layout so the cue's onset only reveals a finished layer.
    static func cueGlyph(_ cue: CueSymbol) -> String {
        switch cue {
        case .leftArrow: return "arrowshape.left.fill"
        case .rightArrow: return "arrowshape.right.fill"
        case .upArrow: return "arrowshape.up.fill"
        case .downArrow: return "arrowshape.down.fill"
        }
    }
}

// MARK: Between trials (brief 010)

/// What the participant window shows outside the measured phases, set by the run controller.
/// Only ever drawn over the background (instructions or blank frames), never with a cross or cue.
enum ParticipantScreen: Equatable, Sendable {
    /// Before the run's first trial, until Space.
    case instructions
    case paused
    /// A run ended and another is left. `completed` counts started runs.
    case betweenRuns(completed: Int, endedEarly: Bool)
    case sessionDone
}

/// The run around the participant screen: where it is in the session and what each cue means.
struct ParticipantRunContext: Equatable, Sendable {
    struct Legend: Hashable, Sendable, Identifiable {
        let name: String
        let cue: CueSymbol
        var id: String { cue.rawValue }
    }

    var runIndex: Int
    var runsPerSession: Int
    var legend: [Legend]

    init(runIndex: Int, runsPerSession: Int, protocolRecord p: ProtocolRecord) {
        self.runIndex = runIndex
        self.runsPerSession = runsPerSession
        // Left before right, up before down, so the legend reads like the screen.
        let order: [CueSymbol] = [.leftArrow, .upArrow, .downArrow, .rightArrow]
        legend = p.classes.map { Legend(name: $0.displayName, cue: $0.cue) }
            .sorted { (order.firstIndex(of: $0.cue) ?? 0) < (order.firstIndex(of: $1.cue) ?? 0) }
    }

    init(runIndex: Int, runsPerSession: Int, legend: [Legend]) {
        self.runIndex = runIndex; self.runsPerSession = runsPerSession; self.legend = legend
    }
}

/// One card the participant reads between trials. Progress (runs done) shows here only, never
/// during fixation, cue or rest (decision #58).
struct ParticipantCardModel: Hashable {
    enum Kind: Hashable { case instructions, paused, betweenRuns, done }
    enum Dot: Hashable { case done, current, pending }

    let kind: Kind
    let eyebrow: String?
    /// An SF Symbol above the title (static: the participant window never animates a symbol).
    let symbol: String?
    let title: String?
    let body: String
    let legend: [ParticipantRunContext.Legend]
    let footer: String?
    let runs: [Dot]

    static let instructionsFooter = "Keep your eyes on the centre of the screen. The run starts when the operator is ready."
    static let pausedTitle = "Paused"
    static let pausedBody = "Relax and stay seated. The run continues when the operator resumes it."
    static let runDoneTitle = "Run complete"
    static let runEndedTitle = "Run ended"
    static let breakBody = "Take a short break: blink, look around and relax your hands. The next run starts when the operator is ready."
    static let doneTitle = "All runs done"
    static let doneBody = "Thank you. You can relax now."

    static func runOf(_ i: Int, _ n: Int) -> String { "Run \(i) of \(n)" }

    static func dots(done: Int, current: Int?, total: Int) -> [Dot] {
        (0..<max(0, min(total, 20))).map { i in i < done ? .done : i == current ? .current : .pending }
    }

    /// The card for a frame. `instructionsText`: the frame is the protocol's instructions;
    /// nil: the frame is blank. A blank frame shows a card only between runs or while paused.
    static func make(instructionsText: String?, screen: ParticipantScreen?, context c: ParticipantRunContext?) -> ParticipantCardModel? {
        let total = c?.runsPerSession ?? 0
        if let text = instructionsText {
            guard screen == .instructions else { return nil }      // Space pressed: the card goes
            return .init(kind: .instructions, eyebrow: c.map { runOf($0.runIndex + 1, $0.runsPerSession) }, symbol: nil, title: nil,
                         body: text, legend: c?.legend ?? [], footer: instructionsFooter,
                         runs: c.map { dots(done: $0.runIndex, current: $0.runIndex, total: total) } ?? [])
        }
        switch screen {
        case nil, .instructions?:
            return nil
        case .paused?:
            return .init(kind: .paused, eyebrow: nil, symbol: "pause.circle", title: pausedTitle, body: pausedBody,
                         legend: [], footer: nil, runs: [])
        case .betweenRuns(let completed, let early)?:
            return .init(kind: .betweenRuns, eyebrow: c.map { runOf(completed, $0.runsPerSession) }, symbol: early ? "stop.circle" : "checkmark.circle",
                         title: early ? runEndedTitle : runDoneTitle, body: breakBody, legend: [], footer: nil,
                         runs: dots(done: completed, current: nil, total: total))
        case .sessionDone?:
            return .init(kind: .done, eyebrow: nil, symbol: "checkmark.seal", title: doneTitle, body: doneBody,
                         legend: [], footer: nil, runs: dots(done: total, current: nil, total: total))
        }
    }
}
