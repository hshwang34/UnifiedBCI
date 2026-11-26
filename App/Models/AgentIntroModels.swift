import Foundation

/// Brief 008: how the app introduces agent control. New users meet it as the intro's last
/// step; people who had already seen the intro get a one-time card on the welcome screen.
enum AgentIntroCopy {
    static let title = "Works with your coding agent"
    static let body = "Claude Code, Codex and other agents can run BCI Workspace for you through the bci command or MCP: evaluate, record and run protocols. It's off until you allow it in Settings. Every step shows here, and the steps that need a person stay with you."
    static let symbol = "terminal"
    static let chipTitle = "Agent control"
    static let chipDetail = "bci · bci mcp · off until you allow it"

    static let cardBadge = "New"
    static let cardTitle = "Works with your coding agent"
    static let cardDetail = "Let Claude Code or Codex drive the app. Off until you allow it."
    static let cardAction = "Set Up…"
    static let cardClose = "Not now"
}

/// The welcome card shows once: to someone who has seen the intro (so not on a first run,
/// whose intro already ends on the agents step), until it's dismissed or control is on.
struct AgentIntroCard {
    static let key = "BCIHasSeenAgentControlIntro"
    let defaults: UserDefaults

    func shouldShow() -> Bool {
        defaults.bool(forKey: FirstRun.key) && !defaults.bool(forKey: Self.key) && !defaults.bool(forKey: ControlSettings.enabledKey)
    }

    func markSeen() { defaults.set(true, forKey: Self.key) }
}
