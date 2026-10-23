import AppKit
import SwiftUI

/// Scenes (UI spec §1): a Welcome window that is the only thing shown at launch
/// (decision #7), and one window per project. Not `DocumentGroup`: the store is
/// append-only with atomic commits and owns persistence; there is no dirty state to save.
@main
struct BCIWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var feasibility = FeasibilityModel()

    var body: some Scene {
        Window("Welcome", id: "welcome") {
            WelcomeView()
                .environment(appDelegate.workspace)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .commands { WorkspaceCommands(workspace: appDelegate.workspace) }

        WindowGroup("Project", for: URL.self) { $url in
            ProjectWindowRoot(url: url)
                .environment(appDelegate.workspace)
        }
        .defaultSize(width: 1280, height: 780)
        // A relaunch shows the Welcome window only; projects open when the user opens them.
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Phase 0 Feasibility", id: "feasibility") {
            FeasibilityView(model: feasibility)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = Workspace(recents: SystemRecentDocuments(), launch: WorkerLaunch.locate())

    /// Closing the last project window leaves the app running; Welcome stays reachable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = Array(workspace.sessions.values)
        guard !sessions.isEmpty else { return .terminateNow }
        var replied = false
        func reply() {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            for s in sessions { await s.shutdown() }
            reply()
        }
        // A worker that does not answer must not keep the app from quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply() }
        return .terminateLater
    }
}

/// Menus per UI spec §1. Per-project items act on the key window's session.
struct WorkspaceCommands: Commands {
    let workspace: Workspace
    @FocusedValue(\.projectSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { workspace.newProjectPanel() }
                .keyboardShortcut("n")
            Button("Open Project…") { workspace.openPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(workspace.recents) { recent in
                    Button(recent.name) { Task { await workspace.open(recent.url) } }
                        .disabled(!recent.exists)
                }
                if !workspace.recents.isEmpty { Divider() }
                Button("Clear Menu") { workspace.clearRecents() }
                    .disabled(workspace.recents.isEmpty)
            }
            Divider()
            Button("Explore Example…") { workspace.exploreExamplePanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Result…") { if let session { workspace.exportPanel(for: session) } }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(session?.selectedResultID == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(session?.showInspector == true ? "Hide Inspector" : "Show Inspector") { session?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session == nil)
        }
        CommandMenu("Pipeline") {
            Button("Evaluate") { session?.evaluate() }
                .keyboardShortcut("r")
                .disabled(!(session?.canEvaluate ?? false))
            Button("Cancel Evaluation") { session?.cancel() }
                .keyboardShortcut(".")
                .disabled(!(session?.isRunning ?? false))
        }
        CommandMenu("Debug") {
            Button("Phase 0 Feasibility Checks") { openWindow(id: "feasibility") }
        }
    }
}
