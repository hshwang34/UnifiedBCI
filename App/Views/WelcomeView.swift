import SwiftUI

/// First-launch window (decision #7): three entry points and the recent projects.
struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BCI Workspace").font(.largeTitle.weight(.semibold))
                    Text("Version \(Self.version)").foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WelcomeModel.actions) { action in
                        WelcomeActionButton(action: action) { perform(action.kind) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 290)
                recentList
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 640, height: 400)
        .onAppear {
            if workspace.openWindow == nil { workspace.openWindow = openWindow }
            workspace.refreshRecents()
        }
        .task { await LaunchArguments.runOnce(workspace) }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Projects").font(.headline)
            if workspace.recents.isEmpty {
                Text(WelcomeModel.emptyRecents)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
            } else {
                List(workspace.recents, selection: $selection) { recent in
                    RecentRow(recent: recent)
                        .tag(recent.url)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
                                .disabled(!recent.exists)
                            Button("Remove from Recents") { workspace.removeRecent(recent.url) }
                        }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                    if let url = urls.first { Task { await workspace.open(url) } }
                }
            }
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

private struct WelcomeActionButton: View {
    let action: WelcomeAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(action.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.headline)
                    Text(action.caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.isEnabled {
                        Label("Not available yet", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        // Disabled but still focusable and explained: the reason is the help and the hint.
        .opacity(action.isEnabled ? 1 : 0.6)
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
        HStack(spacing: 8) {
            Image(systemName: recent.exists ? "shippingbox" : "exclamationmark.triangle")
                .foregroundStyle(recent.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name).lineLimit(1)
                Text(recent.exists ? recent.abbreviatedPath : "Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let date = recent.modified {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
