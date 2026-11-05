import SwiftUI

/// First-launch window (decision #7; visual spec §2.1): three glass entry cards over the
/// ambient backdrop, and the recent projects on a solid card.
struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var selection: URL?
    @FocusState private var focus: WelcomeFlow.Focus?
    @AccessibilityFocusState private var voiceOverFocus: WelcomeFlow.Focus?

    var body: some View {
        // Brief 003: the intro is a mode of this fixed-size window, so `.contentSize` never jumps.
        // The welcome screen stays built underneath the intro (hidden, disabled), so ending the
        // intro is only a fade: building the list and cards mid-transition cost a dropped frame.
        ZStack {
            welcome
                .opacity(workspace.welcomeFlow.isIntro ? 0 : 1)
                .disabled(workspace.welcomeFlow.isIntro)
                .accessibilityHidden(workspace.welcomeFlow.isIntro)
            if workspace.welcomeFlow.isIntro {
                IntroView().transition(.opacity)
            }
        }
        .frame(width: 760, height: 460)
        .animation(LaunchArguments.reduceMotion(system: systemReduceMotion) ? nil : .smooth(duration: 0.45), value: workspace.welcomeFlow.isIntro)
        .onAppear {
            if workspace.openWindow == nil { workspace.openWindow = openWindow }
            workspace.refreshRecents()
            presentIntroIfFirstRun()
        }
        .onChange(of: workspace.welcomeFlow.isIntro) { _, isIntro in if !isIntro { takeFocusAfterIntro() } }
        .task { await LaunchArguments.runOnce(workspace) }
    }

    /// Lead default 6: the flag is set the moment the intro is first presented (Workspace
    /// makes the decision once per launch).
    private func presentIntroIfFirstRun() {
        workspace.presentIntroIfFirstRun(FirstRun(defaults: .standard), reset: LaunchArguments.resetFirstRun,
                                         introStep: LaunchArguments.introStep)
    }

    /// After the intro: "Explore an example" takes keyboard and VoiceOver focus.
    private func takeFocusAfterIntro() {
        guard workspace.welcomeFlow.focus == .exploreExample else { return }
        workspace.welcomeFlow.consumeFocus()
        Task { @MainActor in
            focus = .exploreExample
            voiceOverFocus = .exploreExample
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.l) {
                // From the asset catalog: the Dock's cached icon can lag behind a rebuilt bundle.
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("BCI Workspace").font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(Self.version)").font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                GlassGroup(spacing: 12) {
                    VStack(spacing: Theme.Space.m) {
                        ForEach(WelcomeModel.actions) { action in
                            if action.kind == .example {
                                WelcomeActionCard(action: action) { perform(action.kind) }
                                    .focusable()
                                    .focused($focus, equals: .exploreExample)
                                    .accessibilityFocused($voiceOverFocus, equals: .exploreExample)
                                    .onKeyPress(keys: Set(IntroKeys.activateKeys), phases: IntroKeys.phases) { _ in perform(action.kind); return .handled }
                            } else {
                                WelcomeActionCard(action: action) { perform(action.kind) }
                            }
                        }
                    }
                }
                .frame(width: 380)
                recentList
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.xl)
        .frame(width: 760, height: 460)
        .background { AmbientBackdrop() }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Recent Projects").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            Group {
                if workspace.recents.isEmpty {
                    Text(WelcomeModel.emptyRecents)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(workspace.recents, selection: $selection) { recent in
                        RecentRow(recent: recent)
                            .tag(recent.url)
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
                                    .disabled(!recent.exists)
                                Button("Remove from Recents") { workspace.removeRecent(recent.url) }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                        if let url = urls.first { Task { await workspace.open(url) } }
                    }
                }
            }
            .card(padding: Theme.Space.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func perform(_ kind: WelcomeAction.Kind) {
        switch kind {
        case .example: workspace.exploreExamplePanel()
        case .open: workspace.openPanel()
        case .hardware: break
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct WelcomeActionCard: View {
    let action: WelcomeAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: action.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 28))
                    .foregroundStyle(action.isEnabled ? Theme.accentInk : Theme.textTertiary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(action.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(action.isEnabled ? Theme.textPrimary : Theme.textTertiary)
                    // Information, so full contrast even when the card is disabled.
                    Text(action.caption)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.isEnabled {
                        Label("Not available yet", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.l)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .interactiveGlassCard(cornerRadius: 16, enabled: action.isEnabled)
        // Disabled but still focusable and explained: the reason is the help and the hint.
        .allowsHitTesting(action.isEnabled)
        .help(action.disabledReason ?? action.caption)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.disabledReason ?? action.caption)
        .accessibilityValue(action.isEnabled ? "" : "Unavailable")
    }
}

private struct RecentRow: View {
    let recent: RecentProject

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: recent.exists ? "shippingbox" : "exclamationmark.triangle.fill")
                .foregroundStyle(recent.exists ? Theme.textSecondary : Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(recent.exists ? recent.abbreviatedPath : "Not found")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let date = recent.modified, recent.exists {
                    Text("Modified \(date, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
        .help(recent.url.path)
    }
}
