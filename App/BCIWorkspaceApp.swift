import AppKit
import SwiftUI

/// Scenes (UI spec §1): a Welcome window that is the only thing shown at launch
/// (decision #7), and one window per project. Not `DocumentGroup`: the store is
/// append-only with atomic commits and owns persistence; there is no dirty state to save.
@main
struct BCIWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #if DEBUG
    @State private var feasibility = FeasibilityModel()
    #endif

    var body: some Scene {
        Window("Welcome", id: "welcome") {
            WelcomeView()
                .environment(appDelegate.workspace)
                .containerBackground(.ultraThinMaterial, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Brief 009: never restored from saved state. A launch after a force-quit (or after
        // the Welcome window was closed) otherwise came up with no window at all; decision #7
        // says the Welcome window is what a launch shows.
        .restorationBehavior(.disabled)
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

        // Brief 008: Settings ▸ Agent Control (⌘,).
        Settings {
            AgentControlSettingsView()
        }

        #if DEBUG
        // Phase-0 feasibility checks: developer tooling, not in Release builds.
        Window("Phase 0 Feasibility", id: "feasibility") {
            FeasibilityView(model: feasibility)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace: Workspace

    override convenience init() {
        self.init(workspace: Workspace(recents: SystemRecentDocuments(), launch: LaunchArguments.workerLaunch(default: WorkerLaunch.locate())))
    }

    /// Brief 008: the local control server for coding agents (off unless the person turns it on).
    private(set) lazy var agentControl = AgentControl(workspace: workspace)

    init(workspace: Workspace) {
        self.workspace = workspace
        // Brief 009 / decision #7: a launch shows the Welcome window and nothing else. macOS's
        // saved window state (written after a crash or force-quit) made later launches come up
        // with no window at all, so it is ignored. Registration domain: a user can still override.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never under XCTest: tests drive the router directly.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        agentControl.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.notice(.app, "terminate", ["openProjects": String(workspace.sessions.count)])
        DiagnosticsLog.shared.flush()
        agentControl.stop()
    }

    /// Quit from the Dock, logout, shutdown or a script arrives as the quit Apple Event, which
    /// macOS refuses while a sheet is open (brief 009: "Show me" can leave the Connect sheet
    /// up). It takes the same path as ⌘Q: close sheets, then quit.
    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        workspace.dismissSheetsForQuit()
        NSApp.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        // Brief 009: opens this launch's diagnostics file (and prunes old ones) first.
        AppLog.notice(.app, "launch", ["version": ControlServer.appVersion, "pid": String(getpid()),
                                       "agentControl": ControlSettings.standard.enabled ? "on" : "off"])
        LaunchArguments.applyAppearance()
        HeadGlassWarmUp.start()
        // Lead default 6, decided before the Welcome window's first frame (no welcome-then-
        // intro flash). The flag is set when the window appears (Workspace.welcomeAppeared).
        workspace.presentIntroIfFirstRun(FirstRun(defaults: .standard), reset: LaunchArguments.resetFirstRun,
                                         introStep: LaunchArguments.introStep)
        if LaunchArguments.showAgentCard { workspace.showsAgentCard = true }
    }

    /// Closing the last project window leaves the app running; Welcome stays reachable.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no window open: show Welcome.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspace.openWindow?(id: "welcome") }
        return true
    }

    /// Finder double-click / "Open With" on a `.bciproj`: through `Workspace.open`, so the
    /// one-window-per-project rule and recents apply exactly as for Open….
    func application(_ application: NSApplication, open urls: [URL]) {
        // `bciworkspace://enable-control` (`bci enable`, brief 008) is not a document.
        let control = urls.filter { $0.scheme == ControlProtocol.urlScheme }
        for url in control { agentControl.handle(url: url) }
        let documents = urls.filter { $0.isFileURL }
        guard !documents.isEmpty else { return }
        // A first launch by "Open With" skips the intro this launch (flag left unset).
        workspace.openingDocuments()
        Task { await route(documents) }
    }

    func route(_ urls: [URL]) async {
        for url in urls { await workspace.open(url) }
    }

    /// Lets every project stop before the app does: a run is cancelled, one that is
    /// storing its result finishes the commit, and each worker exits (the worker also
    /// exits on its own when its parent dies, so a force-quit leaves nothing behind).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.dismissSheetsForQuit()
        guard !workspace.sessions.isEmpty || workspace.isClosingAny else { return .terminateNow }
        var replied = false
        func reply() {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await workspace.closeAll()
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
            Divider()
            // Brief 004: the Connect sheet in this project (decision #30).
            Button(LiveScreenModel.newRecording) { session?.showConnectSheet() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session == nil)
        }
        // ⌘Q with the Connect sheet open: close the sheet first, then quit (the shutdown
        // releases a board mid-connect and ends a recording `stopped`).
        CommandGroup(replacing: .appTermination) {
            Button("Quit BCI Workspace") {
                workspace.dismissSheetsForQuit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
            .keyboardShortcut("q")
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
        // Brief 003: the app has no help book, so the Help item is the tour.
        CommandGroup(replacing: .help) {
            Button("Show Welcome Tour") { workspace.showWelcomeTour(open: openWindow) }
            Divider()
            // Brief 007: the goal picker and the sidebar Guide card of the key project.
            Button(GuideCopy.menuGuide) { session?.presentGuidePicker() }
                .disabled(session == nil || session?.isSheetUp == true || workspace.welcomeFlow.isIntro)
            Button(GuideCopy.menuShowGuide) { session?.showGuide() }
                .disabled(session == nil || session?.showsGuideCard == true)
            Divider()
            // Brief 009 / decision #56: a folder for a bug report; never EEG data.
            Button(DiagnosticsCopy.menuExport) { workspace.exportDiagnosticsPanel() }
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Phase 0 Feasibility Checks") { openWindow(id: "feasibility") }
        }
        #endif
    }
}
