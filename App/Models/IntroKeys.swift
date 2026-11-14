import SwiftUI

/// The keys the intro and the welcome screen act on (brief 003), in one place so the views
/// and the tests use the same wiring. Only the first press counts (`phases: .down`): holding
/// Return on "Get Started" must not then open the Explore panel on the welcome screen, and a
/// held → must not run past the last step.
enum IntroKeys {
    static let phases: KeyPress.Phases = .down

    /// Handled by the intro's `onKeyPress`. Esc is Skip's `.cancelAction` shortcut instead
    /// (`skipCommand`), so it works wherever focus is.
    static let introKeys: [KeyEquivalent] = [.leftArrow, .rightArrow, .return]

    /// Activate the focused "Explore an example" card after the intro.
    static let activateKeys: [KeyEquivalent] = [.return, .space]

    static func introKey(_ key: KeyEquivalent) -> IntroKey? {
        switch key {
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .return: return .returnKey
        case .escape: return .escape
        default: return nil
        }
    }

    /// What a press of `key` does in the intro, or nil when the intro ignores it.
    static func command(for key: KeyEquivalent) -> IntroCommand? { introKey(key).map(WelcomeFlow.command(for:)) }

    /// What Skip (and so Esc) sends.
    static let skipCommand = WelcomeFlow.command(for: .escape)
}
