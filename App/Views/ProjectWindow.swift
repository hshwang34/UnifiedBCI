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
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 360)
        } detail: {
            DetailColumn(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { StatusArea(session: session) }
        }
        .inspector(isPresented: $session.showInspector) {
            EvaluateInspector(session: session)
                .inspectorColumnWidth(min: 250, ideal: 280, max: 400)
        }
        .navigationTitle(session.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if session.isRunning {
                    Button { session.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                        .help("Cancel the evaluation (⌘.)")
                } else {
                    Button { session.evaluate() } label: { Label("Evaluate", systemImage: "play.fill") }
                        .disabled(!session.canEvaluate)
                        .help("Evaluate the selected recording (⌘R)")
                }
                Button("Parameters…") { showParameters.toggle() }
                    .help("Evaluation parameters")
                    .popover(isPresented: $showParameters, arrowEdge: .bottom) { ParametersPopover(session: session) }
                Button { workspace.exportPanel(for: session) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(session.selectedResultID == nil)
                    .help("Export the selected result (⇧⌘X)")
                Button { session.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help(session.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
        }
        .focusedSceneValue(\.projectSession, session)
        .frame(minWidth: 1000, minHeight: 620)
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
                        .badge(count(section))
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Label(SidebarSection.statusLine, systemImage: "cable.connector.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                ContentUnavailableView("No Recordings", systemImage: "waveform",
                                       description: Text(session.loadError ?? "Recording from hardware arrives in phase 2."))
            } else {
                List(session.recordings, id: \.id, selection: $session.selectedRecordingID) { handle in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecordingDetailModel.title(for: handle.manifest))
                        Text(RecordingDetailModel.summary(for: handle.manifest)).font(.caption).foregroundStyle(.secondary)
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
            ContentUnavailableView(session.section.title, systemImage: session.section.symbol,
                                   description: Text(session.section.placeholder ?? ""))
        case .pipelines:
            PipelinesList(session: session)
        case .results:
            if session.results.isEmpty {
                ContentUnavailableView("No Results", systemImage: SidebarSection.results.symbol,
                                       description: Text("Select a recording and choose Evaluate (⌘R)."))
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
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text("Reproduction of \(originalTime)")
            } else if node.diverged {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Differs from \(originalTime)")
            } else {
                Text("Seed \(node.meta.seed)")
            }
            Spacer()
            Text(time).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
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
            ContentUnavailableView("Pipelines unavailable", systemImage: "exclamationmark.octagon",
                                   description: Text("The analysis worker did not describe its recipes. \(why)"))
        case .loaded:
            List(session.recipes) { recipe in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(recipe.name).font(.headline)
                        Spacer()
                        Text(recipe.role).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(recipe.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    ForEach(recipe.steps, id: \.self) { step in
                        Text("• " + step).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
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
                ContentUnavailableView("No Recording Selected", systemImage: "waveform")
            }
        case .results:
            if let stored = session.selectedResult {
                ResultDetailView(session: session, stored: stored).id(stored.meta.resultID)
            } else if let error = session.selectedResultError {
                ContentUnavailableView("Result unreadable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if session.selectedResultID != nil {
                ProgressView()
            } else {
                ContentUnavailableView("No Result Selected", systemImage: SidebarSection.results.symbol)
            }
        case .pipelines:
            ContentUnavailableView("Read-only in phase 1", systemImage: SidebarSection.pipelines.symbol,
                                   description: Text("These recipes run as shipped. Parameters… changes the window, CSP components and seed of one evaluation; the values are stored with its result."))
        case .protocols, .liveTest:
            Color.clear
        }
    }
}

// MARK: Status: progress, banners, notices

private struct StatusArea: View {
    let session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            if let p = session.progress {
                ProgressStrip(progress: p) { session.cancel() }
            }
            if let banner = session.banner {
                BannerView(banner: banner, retry: { session.retry() })
            }
            if let notice = session.notice {
                NoticeView(notice: notice, text: session.noticeText(notice), dismiss: session.dismissNotice)
            }
        }
    }
}

private struct ProgressStrip: View {
    let progress: ProgressDisplay
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(Array(ProgressDisplay.stages.enumerated()), id: \.offset) { i, stage in
                        if i > 0 { Text("·").foregroundStyle(.tertiary) }
                        Text(stage)
                            .fontWeight(stage == progress.stage ? .semibold : .regular)
                            .foregroundStyle(stage == progress.stage ? .primary : .secondary)
                    }
                }
                .font(.callout)
                ProgressView(value: progress.fraction, total: 1)
                    .accessibilityLabel("Evaluation progress")
                    .accessibilityValue(progress.accessibilityValue)
                Text(progress.detail).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", action: cancel).keyboardShortcut(".", modifiers: .command)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct BannerView: View {
    let banner: ProjectSession.Banner
    let retry: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.octagon").foregroundStyle(.red).font(.title3)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if case .analysisUnavailable = banner {
                    Button("Retry", action: retry).buttonStyle(.borderedProminent)
                }
            }
            DisclosureGroup("Show details", isExpanded: $showDetails) {
                ScrollView {
                    Text(details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .font(.callout)
        }
        .padding(12)
        .background(.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch banner {
        case .analysisUnavailable:
            return "Analysis unavailable. The analysis worker stopped. Your recording is unchanged."
        case .failed:
            return "Evaluation failed. The analysis worker refused this request; nothing was saved. Retrying without a change will fail the same way."
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
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if case .exported(let url) = notice {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
        case .diverged, .exportFailed: return .orange
        case .cancelled: return .secondary
        default: return .green
        }
    }
}

// MARK: Parameters

/// Overrides for one evaluation. Empty fields use the worker's defaults, shown as
/// placeholders; none of these numbers originate in the app.
struct ParametersPopover: View {
    @Bindable var session: ProjectSession

    var body: some View {
        Form {
            switch session.defaults {
            case .loading:
                Label("Loading defaults from the analysis worker…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .unavailable:
                Label("The analysis worker is not running, so its defaults are unknown. The values an evaluation uses are always stored with its result.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .loaded: EmptyView()
            }
            let d = session.workerDefaults?.params
            Section {
                TextField("Seed", value: $session.parameters.seed, format: .number.grouping(.never), prompt: Text(d.map { "\($0.seed)" } ?? ""))
                Text(ParametersCopy.seed).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("CSP components", value: $session.parameters.cspComponents, format: .number.grouping(.never), prompt: Text(d.map { "\($0.csp_components)" } ?? ""))
                Text("More components capture more variance patterns but overfit sooner on few trials.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Window offset (s)", value: $session.parameters.windowOffsetSeconds, format: .number, prompt: Text(d.map { "\($0.window.offset_s)" } ?? ""))
                Text("When after the cue the analysis window starts. Earlier risks cue-onset artefacts.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Window length (s)", value: $session.parameters.windowLengthSeconds, format: .number, prompt: Text(d.map { "\($0.window.length_s)" } ?? ""))
                Text("Longer windows average more noise out but dilute short-lived changes.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Reset") { session.parameters = .init() }
                    .disabled(session.parameters == .init())
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}

enum ParametersCopy {
    /// The spec's "Changes the bootstrap draws. The split stays the same." holds only when
    /// a frozen split manifest is supplied. The app never supplies one, so the worker draws
    /// the held-out runs from the seed (pipeline.draw_split_manifest): the copy says so.
    static let seed = "Chooses the held-out runs and the bootstrap draws. The same seed gives the same split."
}

