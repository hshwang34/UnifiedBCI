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

/// Copy and geometry of the participant window (brief 005, "Participant window"): neutral
/// dark background, centred white fixation cross, the arrow drawn over it, blank rest. No
/// branding, controls, numbers or feedback. Sizes are fractions of the display's shorter side so
/// the cues read the same from across a room on any display.
enum CueWindowModel {
    /// Background and ink as sRGB 0…1. Near-black and near-white: ~18:1, calm rather than glaring.
    static let background: (r: Double, g: Double, b: Double) = (0.075, 0.082, 0.098)
    static let ink: (r: Double, g: Double, b: Double) = (0.93, 0.94, 0.95)

    static let crossArm = 0.075          // half-length of each arm, × shorter side
    static let crossStroke = 0.012
    static let arrowLength = 0.30        // tip to tail, × shorter side
    static let arrowShaft = 0.035
    static let arrowHead = 0.14          // head width, × shorter side
    static let arrowHeadLength = 0.11
    static let instructionsSize = 0.034  // font size, × shorter side
    static let instructionsWidth = 0.62  // × width

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
}
