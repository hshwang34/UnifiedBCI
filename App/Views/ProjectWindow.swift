import SwiftUI

extension FocusedValues {
    /// The project of the key window, for the menu commands.
    @Entry var projectSession: ProjectSession?
}

/// A project window's root: resolves the session for its URL (one per project) and
/// registers its NSWindow so a second window for the same project never stays open.
struct ProjectWindowRoot: View {
    let url: URL?
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .opening

    enum Phase {
        case opening
        case open(ProjectSession)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .opening:
                ProgressView("Opening project…").frame(minWidth: 900, minHeight: 560)
            case .open(let session):
                ProjectWindow(session: session)
            case .failed(let message):
                ContentUnavailableView("Project unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        .background(WindowReader { window in
            guard let url else { return }
            workspace.attach(window, to: url)
        })
        .onAppear { if workspace.openWindow == nil { workspace.openWindow = openWindow } }
        .task(id: url) {
            guard let url else { phase = .failed("No project."); return }
            do {
                // The window may close while the project is still opening; then the
                // session is closed rather than left running without a window.
                if let session = try await workspace.session(forWindow: url, stillWanted: { !Task.isCancelled }) {
                    phase = .open(session)
                }
            } catch {
                phase = .failed(Workspace.openFailureMessage(error))
            }
        }
    }
}

struct ProjectWindow: View {
    @Bindable var session: ProjectSession
    @Environment(Workspace.self) private var workspace
    @State private var showParameters = false
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ProjectSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } content: {
            ContentColumn(session: session)
                .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 360)
        } detail: {
            DetailColumn(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    // Under the Result hero the glow continues beneath sidebar and inspector (26).
                    if session.section == .results { AmbientBackdrop().extendedBackground() } else { AmbientBackdrop() }
                }
                .safeAreaInset(edge: .top, spacing: 0) { StatusArea(session: session) }
        }
        // The Evaluate inspector belongs to Recordings only; the preference is kept.
        .inspector(isPresented: Binding(get: { session.showInspector && session.section == .recordings },
                                        set: { session.showInspector = $0 })) {
            EvaluateInspector(session: session)
                .inspectorColumnWidth(min: 250, ideal: 280, max: 400)
        }
        .navigationTitle(session.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if session.isRunning {
                    Button { session.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                        .labelStyle(.titleAndIcon)
                        .help("Cancel the evaluation (⌘.)")
                } else {
                    Button { session.evaluate() } label: { Label("Evaluate", systemImage: "play.fill") }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canEvaluate)
                        .help("Evaluate the selected recording (⌘R)")
                }
            }
            FixedToolbarSpacer()
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Parameters…") { showParameters.toggle() }
                    .help("Evaluation parameters")
                    .popover(isPresented: $showParameters, arrowEdge: .bottom) { ParametersPopover(session: session) }
                Button { workspace.exportPanel(for: session) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(session.selectedResultID == nil || session.section != .results)
                    .help("Export the selected result (⇧⌘X)")
            }
            FixedToolbarSpacer()
            ToolbarItem(placement: .primaryAction) {
                Button { session.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .disabled(session.section != .recordings)
                    .help(session.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
        }
        .focusedSceneValue(\.projectSession, session)
        .frame(minWidth: 1100, minHeight: 640)
    }

    private var subtitle: String {
        switch session.section {
        case .recordings: return session.selectedRecording.map { RecordingDetailModel.title(for: $0.manifest) } ?? "Recordings"
        case .results:
            if let id = session.selectedResultID, let meta = session.results.first(where: { $0.resultID == id }) {
                return "Result · seed \(meta.seed) · \(ProjectSession.time(meta.createdAt))"
            }
            return "Results"
        default: return session.section.title
        }
    }
}

// MARK: Sidebar

private struct ProjectSidebar: View {
    @Bindable var session: ProjectSession

    var body: some View {
        List(selection: Binding(get: { session.section }, set: { if let s = $0 { session.section = s } })) {
            Section("Project") {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .badge(count(section))
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Plain text on the sidebar: no glass on glass.
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "cable.connector.slash")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No hardware connected")
                    Text("Replay mode")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(SidebarSection.statusLine)
        }
    }

    private func count(_ section: SidebarSection) -> Int {
        switch section {
        case .recordings: return session.recordings.count
        case .results: return session.results.count
        default: return 0
        }
    }
}

// MARK: Content column

private struct ContentColumn: View {
    @Bindable var session: ProjectSession

    var body: some View {
        switch session.section {
        case .recordings:
            if session.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text(session.loadError ?? "Recording from hardware arrives in phase 2.").foregroundStyle(Theme.textSecondary)
                }
            } else {
                List(session.recordings, id: \.id, selection: $session.selectedRecordingID) { handle in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecordingDetailModel.title(for: handle.manifest))
                        Text(RecordingDetailModel.summary(for: handle.manifest)).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                    .tag(handle.id)
                    .contextMenu {
                        Button("Evaluate") { session.selectedRecordingID = handle.id; session.evaluate() }
                            .disabled(session.isRunning)
                    }
                }
            }
        case .protocols, .liveTest:
            // The placeholder lives in the detail column; this column stays empty.
            Color.clear
        case .pipelines:
            PipelinesList(session: session)
        case .results:
            if session.results.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: SidebarSection.results.symbol)
                } description: {
                    Text("Select a recording and choose Evaluate (⌘R).").foregroundStyle(Theme.textSecondary)
                }
            } else {
                // Originals with their reruns as children, expanded unless the user folds
                // them, so a new reproduction is visible as soon as it is selected.
                List(selection: $session.selectedResultID) {
                    ForEach(session.resultTree) { node in
                        if let children = node.children {
                            DisclosureGroup(isExpanded: expanded(node.id)) {
                                ForEach(children) { ResultRow(node: $0, results: session.results).tag($0.id) }
                            } label: {
                                ResultRow(node: node, results: session.results).tag(node.id)
                            }
                        } else {
                            ResultRow(node: node, results: session.results).tag(node.id)
                        }
                    }
                }
            }
        }
    }
}

extension ContentColumn {
    func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !session.collapsedResults.contains(id) },
                set: { if $0 { session.collapsedResults.remove(id) } else { session.collapsedResults.insert(id) } })
    }
}

private struct ResultRow: View {
    let node: ResultNode
    let results: [ResultMeta]

    var body: some View {
        let time = ProjectSession.time(node.meta.createdAt)
        HStack(spacing: 6) {
            if node.isReproduction {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.textSecondary)
                Text("Reproduction").lineLimit(1)
            } else if node.diverged {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("Differs").lineLimit(1)
            } else {
                Text("Seed \(node.meta.seed)").lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(time).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
        .help(fullDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fullDescription)
    }

    private var fullDescription: String {
        let time = ProjectSession.time(node.meta.createdAt)
        if node.isReproduction { return "Reproduction of \(originalTime), run at \(time)" }
        if node.diverged { return "Differs from the \(originalTime) original, run at \(time)" }
        return "Seed \(node.meta.seed), \(time)"
    }

    private var originalTime: String {
        let id = node.meta.reproductionOf ?? node.meta.divergedFrom
        return results.first { $0.resultID == id }.map { ProjectSession.time($0.createdAt) } ?? "original"
    }
}

/// The two recipes phase 1 runs, read-only, described by the worker.
private struct PipelinesList: View {
    let session: ProjectSession

    var body: some View {
        switch session.defaults {
        case .loading:
            ProgressView("Asking the analysis worker…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let why):
            ContentUnavailableView {
                Label("Pipelines unavailable", systemImage: "exclamationmark.octagon")
            } description: {
                Text("The analysis worker did not describe its recipes. \(why)").foregroundStyle(Theme.textSecondary)
            }
        case .loaded:
            List(session.recipes) { recipe in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.name).font(Theme.Fonts.sectionHeader)
                        HStack(spacing: Theme.Space.s) {
                            Text(recipe.id).font(Theme.Fonts.monoCaption)
                            Text(recipe.role).font(.caption)
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(recipe.steps, id: \.self) { step in
                        Label {
                            Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.s)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Detail column

private struct DetailColumn: View {
    let session: ProjectSession

    var body: some View {
        switch session.section {
        case .recordings:
            if let handle = session.selectedRecording {
                RecordingDetailView(model: RecordingDetailModel(manifest: handle.manifest, events: session.eventsByRecording[handle.id] ?? []),
                                    info: ExampleInfo(manifest: handle.manifest))
                    .id(handle.id)
            } else {
                Placeholder(title: "No Recording Selected", symbol: "waveform", text: nil)
            }
        case .results:
            if let stored = session.selectedResult {
                ResultDetailView(session: session, stored: stored).id(stored.meta.resultID)
            } else if let error = session.selectedResultError {
                Placeholder(title: "Result unreadable", symbol: "exclamationmark.triangle", text: error)
            } else if session.selectedResultID != nil {
                ProgressView()
            } else {
                Placeholder(title: "No Result Selected", symbol: SidebarSection.results.symbol, text: nil)
            }
        case .pipelines:
            Placeholder(title: "Read-only in phase 1", symbol: SidebarSection.pipelines.symbol,
                        text: "These recipes run as shipped. Parameters… changes the window, CSP components and seed of one evaluation; the values are stored with its result.")
        case .protocols, .liveTest:
            Placeholder(title: session.section.title, symbol: session.section.symbol, text: session.section.placeholder)
        }
    }
}

/// `ContentUnavailableView` with full-opacity secondary text (finding 11).
private struct Placeholder: View {
    let title: String
    let symbol: String
    let text: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol).foregroundStyle(Theme.textSecondary)
        } description: {
            if let text { Text(text).foregroundStyle(Theme.textSecondary) }
        }
    }
}

// MARK: Status: error banner > progress > notice

private struct StatusArea: View {
    let session: ProjectSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let banner = session.banner {
                ErrorBanner(banner: banner, retry: { session.retry() })
            } else if let p = session.progress {
                ProgressPanel(progress: p) { session.cancel() }
                    .transition(.opacity.combined(with: .offset(y: -8)))
            } else if let notice = session.notice {
                NoticeView(notice: notice, text: session.noticeText(notice), dismiss: session.dismissNotice)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        // Zero ideal width: the panel takes the width it is offered (up to 680) and never
        // asks the split view for more, which would push the window's columns out of it.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: 680)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .animation(Theme.motion(reduceMotion: reduceMotion), value: session.progress == nil)
        .animation(Theme.motion(reduceMotion: reduceMotion), value: session.notice)
    }
}

private struct ProgressPanel: View {
    let progress: ProgressDisplay
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Every stage named when there is room; otherwise marks plus the current name.
            ViewThatFits(in: .horizontal) {
                stages(compact: false)
                stages(compact: true)
            }
            HStack(spacing: Theme.Space.m) {
                ProgressView(value: progress.fraction, total: 1)
                    .progressViewStyle(TrackProgressStyle())
                    .accessibilityLabel("Evaluation progress")
                    .accessibilityValue(progress.accessibilityValue)
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(".", modifiers: .command)
            }
            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .id(progress.detail)
                .transition(.opacity)
                .animation(Theme.motion(reduceMotion: reduceMotion), value: progress.detail)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
        .glassSurface(cornerRadius: Theme.Radius.hero)
    }

    private func stages(compact: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(Array(ProgressDisplay.stages.enumerated()), id: \.offset) { i, stage in
                let mark = progress.mark(for: i)
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: mark.symbol).accessibilityHidden(true)
                    if !compact || mark == .current {
                        Text(stage).fontWeight(mark == .current ? .semibold : .regular).lineLimit(1)
                    }
                }
                .font(.callout)
                .foregroundStyle(mark == .pending ? Theme.textSecondary : Theme.textPrimary)
                .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilityValue)
    }
}

/// A 6 pt determinate track in accentInk (§2.5): the system linear style has a fixed
/// thickness and animates toward each value, so a fast run read as nearly empty.
private struct TrackProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule().fill(Theme.accentInk)
                    .frame(width: geo.size.width * CGFloat(min(max(configuration.fractionCompleted ?? 0, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Solid, never glass, never auto-dismissed (§2.5).
private struct ErrorBanner: View {
    let banner: ProjectSession.Banner
    let retry: () -> Void
    @State private var showDetails = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Theme.danger).frame(width: 4)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.danger)
                    Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if case .analysisUnavailable = banner {
                        Button("Retry", action: retry).appProminentButton()
                    }
                }
                Text(message).font(.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Show details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(details)
                            .font(Theme.Fonts.monoCaption)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                    }
                    .frame(maxHeight: 120)
                    .background(Theme.surface2, in: .rect(cornerRadius: Theme.Radius.control))
                }
                .font(.callout)
            }
            .padding(Theme.Space.l)
        }
        .background {
            ZStack {
                shape.fill(Theme.surface1)
                shape.fill(Theme.danger.opacity(0.12))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.danger, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch banner {
        case .analysisUnavailable: return "Analysis unavailable"
        case .failed: return "Evaluation failed"
        }
    }

    private var message: String {
        switch banner {
        case .analysisUnavailable: return "The analysis worker stopped. Your recording is unchanged."
        case .failed: return "The analysis worker refused this request; nothing was saved. Retrying without a change will fail the same way."
        }
    }

    private var details: String {
        switch banner {
        case .analysisUnavailable(let d), .failed(let d): return d
        }
    }
}

private struct NoticeView: View {
    let notice: ProjectSession.Notice
    let text: String
    let dismiss: () -> Void

    var body: some View {
        if notice.isPersistent {
            HStack(spacing: Theme.Space.s) {
                StatusChip(kind: .warning, text: text)
                dismissButton
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(text).font(.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                if case .exported(let url) = notice {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered)
                }
                dismissButton
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .glassSurface(cornerRadius: Theme.Radius.hero)
        }
    }

    private var dismissButton: some View {
        Button { dismiss() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
    }

    private var symbol: String {
        switch notice {
        case .saved, .exported: return "checkmark.circle.fill"
        case .reproduced: return "arrow.triangle.2.circlepath"
        case .diverged, .exportFailed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch notice {
        case .cancelled: return Theme.textSecondary
        case .diverged, .exportFailed: return Theme.warning
        default: return Theme.positive
        }
    }
}

// MARK: Parameters

/// Overrides for one evaluation. Empty fields use the worker's defaults, shown beside each
/// field; none of these numbers originate in the app. Values are live (no Apply).
struct ParametersPopover: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let d = session.workerDefaults?.params
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            switch session.defaults {
            case .loading:
                StatusChip(kind: .info, text: "Loading defaults from the analysis worker…")
            case .unavailable:
                StatusChip(kind: .warning, text: "The analysis worker is not running, so its defaults are unknown. The values an evaluation uses are always stored with its result.")
            case .loaded: EmptyView()
            }
            field("Seed", help: ParametersCopy.seed, default: d.map { "\($0.seed)" }) {
                TextField("Seed", value: $session.parameters.seed, format: .number.grouping(.never), prompt: Text(d.map { "\($0.seed)" } ?? ""))
            }
            field("CSP components", help: "More components capture more variance patterns but overfit sooner on few trials.", default: d.map { "\($0.csp_components)" }) {
                TextField("CSP components", value: $session.parameters.cspComponents, format: .number.grouping(.never), prompt: Text(d.map { "\($0.csp_components)" } ?? ""))
            }
            field("Window offset (s)", help: "When after the cue the analysis window starts. Earlier risks cue-onset artefacts.", default: d.map { "\($0.window.offset_s)" }) {
                TextField("Window offset", value: $session.parameters.windowOffsetSeconds, format: .number, prompt: Text(d.map { "\($0.window.offset_s)" } ?? ""))
            }
            field("Window length (s)", help: "Longer windows average more noise out but dilute short-lived changes.", default: d.map { "\($0.window.length_s)" }) {
                TextField("Window length", value: $session.parameters.windowLengthSeconds, format: .number, prompt: Text(d.map { "\($0.window.length_s)" } ?? ""))
            }
            HStack {
                Spacer()
                Button("Reset") { session.parameters = .init() }
                    .buttonStyle(.bordered)
                    .disabled(session.parameters == .init())
            }
        }
        .padding(Theme.Space.cardPadding)
        .frame(width: 380)
    }

    private func field<F: View>(_ label: String, help: String, default value: String?, @ViewBuilder input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).font(.callout.weight(.semibold))
            HStack(spacing: Theme.Space.s) {
                input().textFieldStyle(.roundedBorder).labelsHidden()
                Text(value.map { "Default \($0)" } ?? "Default unknown")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(help).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ParametersCopy {
    /// Decision #10.
    static let seed = "Chooses the held-out runs and the bootstrap draws. The same seed gives the same split."
}
