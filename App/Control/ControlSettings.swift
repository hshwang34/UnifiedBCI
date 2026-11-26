import AppKit
import Foundation
import SwiftUI

/// Agent control toggles (brief 008, decisions #47 and #48). Both are off by default, and
/// stored in the app's defaults (per user, never in a project).
struct ControlSettings {
    static let enabledKey = "BCIAgentControlEnabled"
    static let hardwareKey = "BCIAgentHardwareAllowed"

    var defaults: UserDefaults

    static var standard: ControlSettings { .init(defaults: .standard) }

    var enabled: Bool {
        get { read(Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var hardwareAllowed: Bool {
        get { read(Self.hardwareKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hardwareKey) }
    }

    /// Release reads only what the person saved (Settings or the `bci enable` dialog), never a
    /// launch-argument override, so nothing but the person turns control on. Debug also takes
    /// `-BCIAgentControlEnabled YES` for smoke runs (`scripts/agent_smoke.sh`).
    private func read(_ key: String) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: key)
        #else
        guard defaults === UserDefaults.standard, let id = Bundle.main.bundleIdentifier else { return defaults.bool(forKey: key) }
        return defaults.persistentDomain(forName: id)?[key] as? Bool ?? false
        #endif
    }
}

/// Owns the server and turns it on or off as the setting changes.
@MainActor
final class AgentControl {
    let router: ControlRouter
    private var server: ControlServer?
    private var observer: NSObjectProtocol?
    private(set) var lastError: String?

    init(workspace: Workspace) {
        router = ControlRouter(workspace: workspace)
    }

    func start() {
        reconcile()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func reconcile() {
        let on = ControlSettings.standard.enabled
        if on, server == nil {
            let router = router
            let s = ControlServer(dispatch: { request, connection in
                let client = connection.client
                Task { @MainActor in
                    await router.handle(request, client: client, connection: connection.id.uuidString) { connection.send($0) }
                }
            }, closed: { _ in Task { @MainActor in AgentActivity.shared.connectionClosed() } })
            do {
                try s.start(appVersion: ControlServer.appVersion)
                server = s
                lastError = nil
            } catch {
                lastError = "\(error)"
                NSLog("BCI Workspace: agent control did not start: %@", "\(error)")
            }
        } else if !on, let s = server {
            s.stop()
            server = nil
        }
    }

    var socketPath: String? { server?.socketPath }

    /// `bciworkspace://enable-control` (`bci enable`): asks before turning control on.
    func handle(url: URL) {
        guard url.scheme == ControlProtocol.urlScheme, url.host == "enable-control" else { return }
        NSApp.activate()
        if ControlSettings.standard.enabled { return }
        let alert = NSAlert()
        alert.messageText = "Allow coding agents to control BCI Workspace?"
        alert.informativeText = """
        A tool on this Mac (bci, used by Claude Code or Codex) asked to drive the app: open projects, evaluate, record and run protocols. \
        Everything it does shows in the app, human steps stay with you, and hardware needs a separate setting. Turn it off any time in Settings ▸ Agent Control.
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if alert.runModal() == .alertFirstButtonReturn { ControlSettings.standard.enabled = true }
    }
}

/// Settings ▸ Agent Control.
struct AgentControlSettingsView: View {
    @AppStorage(ControlSettings.enabledKey) private var enabled = false
    @AppStorage(ControlSettings.hardwareKey) private var hardware = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow coding agents to control BCI Workspace", isOn: $enabled)
                Text("Claude Code, Codex and other agents drive the app through the bci command or its MCP mode. Everything they do shows in the app's windows and is logged in the project (logs/agent-actions.jsonl).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow agents to use hardware", isOn: $hardware)
                    .disabled(!enabled)
                Text("Lets an agent connect a serial board. You confirm each port once per launch, and you start every cued run yourself. The synthetic board and the Demo never need this.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Command-line tool") {
                Text(Self.installCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text("Then: claude mcp add bci -- ~/.local/bin/bci mcp").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    static var installCommand: String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bci").path
        return "\"\(helper)\" install"
    }
}
