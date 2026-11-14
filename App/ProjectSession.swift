import Foundation
import Observation
import SwiftUI

/// One open project: the store, the evaluation runner and its worker, and the window's
/// selection. Main-actor state for the views; all I/O happens in `ProjectStore` (an actor)
/// or in detached tasks, never on the main thread.
@MainActor
@Observable
final class ProjectSession: Identifiable {
    enum DefaultsState: Equatable {
        case loading
        case loaded(EvaluationDefaults)
        case unavailable(String)
    }

    /// Transient outcome of the last user action, shown above the detail column.
    enum Notice: Equatable {
        case saved
        case reproduced(original: Date?)
        case diverged(original: Date?)
        case cancelled
        case exported(URL)
        case exportFailed(String)

        /// Persistent notices are solid warning chips that stay until dismissed; the rest
        /// are toasts that dismiss themselves and clear on a section change (§2.5).
        var isPersistent: Bool {
            switch self {
            case .diverged, .exportFailed: return true
            default: return false
            }
        }
    }

    /// How long a toast stays up.
    @ObservationIgnored var noticeLifetime: Duration = .seconds(6)
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?

    /// Banner for a run that ended badly. Distinct from `Notice`: it stays until a retry
    /// or a new run, and the recording stays browsable underneath it.
    enum Banner: Equatable {
        /// The worker died, could not start, or stopped answering. Retry starts a fresh one.
        case analysisUnavailable(details: String)
        /// The worker ran and refused (integrity, bad parameters, internal error).
        case failed(details: String)
    }

    /// Optional overrides for one evaluation; nil means "the worker's default".
    struct Parameters: Equatable {
        var seed: Int?
        var cspComponents: Int?
        var windowOffsetSeconds: Double?
        var windowLengthSeconds: Double?
    }

    nonisolated let url: URL
    let store: ProjectStore
    let runner: EvaluationRunner
    /// Brief 002: the Quality tab's inspections, on a worker of their own.
    let inspector: InspectionRunner
    nonisolated var id: URL { url }

    private(set) var name: String
    private(set) var recordings: [RecordingHandle] = []
    private(set) var eventsByRecording: [UUID: [EventRecord]] = [:]
    private(set) var results: [ResultMeta] = []
    private(set) var loadError: String?
    private(set) var defaults: DefaultsState = .loading
    private(set) var notice: Notice? {
        didSet {
            noticeTimer?.cancel()
            guard let notice, !notice.isPersistent else { return }
            let lifetime = noticeLifetime
            noticeTimer = Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled, let self, self.notice == notice else { return }
                self.notice = nil
            }
        }
    }
    private(set) var selectedResult: StoredResult?
    private(set) var selectedResultError: String?
    /// Parsed reports of the latest result per recording, for the inspector's bullets.
    private(set) var latestReport: [UUID: EvaluationReport] = [:]

    var section: SidebarSection = .recordings {
        didSet { if section != oldValue, let n = notice, !n.isPersistent { notice = nil } }
    }
    var selectedRecordingID: UUID? {
        didSet { if selectedRecordingID != oldValue { inspectIfFirstShown() } }
    }
    var selectedResultID: UUID? {
        didSet { if selectedResultID != oldValue { loadSelectedResult() } }
    }
    var parameters = Parameters() {
        didSet { if parameters.cspComponents != oldValue.cspComponents { refreshRecipes() } }
    }
    /// The recipes as the worker describes them for the current CSP component count.
    private(set) var recipes: [EvaluationDefaults.Recipe] = []
    @ObservationIgnored private var recipesTask: Task<Void, Never>?
    var showInspector = true
    var recordingTab: RecordingTab = .channels {
        didSet { if recordingTab != oldValue { inspectIfFirstShown() } }
    }
    /// Recordings whose Quality tab has been shown: inspection starts on its own only the
    /// first time, so a cancel or a failure is not undone by switching tabs.
    @ObservationIgnored private var autoInspected: Set<UUID> = []
    @ObservationIgnored private var qualityModels: [UUID: QualityModel] = [:]
    /// Results whose reruns the user folded away in the list (all start expanded).
    var collapsedResults: Set<UUID> = []

    private var defaultsTask: Task<Void, Never>?
    private var resultLoad: Task<Void, Never>?

    init(store: ProjectStore, url: URL, launch: WorkerLaunch?, name: String) {
        self.url = url
        self.store = store
        self.runner = EvaluationRunner(store: store, launch: launch)
        self.inspector = InspectionRunner(projectDirectory: url, launch: launch)
        self.name = name
    }

    /// Opens the project at `url` (already canonical) without blocking the main actor:
    /// `ProjectStore.open` does synchronous I/O (manifest read, orphan sweep).
    static func open(at url: URL, launch: WorkerLaunch?) async throws -> ProjectSession {
        let store = try await Task.detached(priority: .userInitiated) { try ProjectStore.open(at: url) }.value
        return await adopt(store, url: url, launch: launch)
    }

    /// Wraps a store that is already open (a project just created or imported).
    static func adopt(_ store: ProjectStore, url: URL, launch: WorkerLaunch?) async -> ProjectSession {
        let session = ProjectSession(store: store, url: url, launch: launch, name: await store.manifest.name)
        await session.reload()
        session.loadDefaults()
        return session
    }

    // MARK: Loading

    func reload() async {
        do {
            let ids = try await store.recordingIDs()
            var handles: [RecordingHandle] = []
            var events: [UUID: [EventRecord]] = [:]
            for id in ids {
                let handle = try await store.recording(id: id)
                handles.append(handle)
                events[id] = try await store.events(for: id)
            }
            recordings = handles
            eventsByRecording = events
            if selectedRecordingID == nil || !ids.contains(selectedRecordingID!) { selectedRecordingID = ids.first }
            try await reloadResults()
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadResults() async throws {
        results = try await store.results()
        var latest: [UUID: EvaluationReport] = [:]
        for recording in Set(results.map(\.recordingID)) {
            guard let meta = results.last(where: { $0.recordingID == recording }),
                  let stored = try? await store.result(id: meta.resultID),
                  let report = try? EvaluationReport.decode(stored.evaluationJSON) else { continue }
            latest[recording] = report
        }
        latestReport = latest
    }

    /// Asks the worker for its defaults (`fit_evaluate_defaults`). Starting the worker
    /// here also warms it for the first Evaluate.
    func loadDefaults() {
        defaults = .loading
        defaultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let d = try await self.runner.defaults()
                self.defaults = .loaded(d)
                if self.parameters.cspComponents == nil { self.recipes = d.recipes } else { self.refreshRecipes() }
            } catch let error as WorkerError {
                self.defaults = .unavailable(error.message)
            } catch {
                self.defaults = .unavailable("\(error)")
            }
        }
    }

    private func refreshRecipes() {
        recipesTask?.cancel()
        let count = parameters.cspComponents
        recipesTask = Task { [weak self] in
            guard let self, let d = try? await self.runner.defaults(cspComponents: count),
                  self.parameters.cspComponents == count else { return }
            self.recipes = d.recipes
        }
    }

    /// Waits for the recipe description to follow the parameters (tests).
    func awaitRecipes() async { await recipesTask?.value }

    private func loadSelectedResult() {
        resultLoad?.cancel()
        selectedResult = nil
        selectedResultError = nil
        guard let id = selectedResultID else { return }
        resultLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let stored = try await self.store.result(id: id)
                guard self.selectedResultID == id else { return }
                self.selectedResult = stored
            } catch {
                guard self.selectedResultID == id else { return }
                self.selectedResultError = "\(error)"
            }
        }
    }

    /// Waits for the worker's defaults lookup to finish (tests).
    func awaitDefaults() async { await defaultsTask?.value }

    /// Waits for the selected result to load (tests).
    func awaitSelectedResult() async { await resultLoad?.value }

    // MARK: Derived

    var selectedRecording: RecordingHandle? {
        recordings.first { $0.id == selectedRecordingID }
    }

    var resultTree: [ResultNode] { ResultNode.tree(results) }

    var workerDefaults: EvaluationDefaults? {
        if case .loaded(let d) = defaults { return d }
        return nil
    }

    func modelName(_ key: String) -> String {
        recipes.first { $0.model == key }?.name ?? key
    }

    var isRunning: Bool {
        if case .running = runner.state { return true }
        return false
    }

    var canEvaluate: Bool { selectedRecordingID != nil && !isRunning }

    var progress: ProgressDisplay? {
        guard case .running(let p) = runner.state else { return nil }
        return ProgressDisplay(p, modelName: modelName)
    }

    var banner: Banner? {
        switch runner.state {
        case .analysisUnavailable(let reason): return .analysisUnavailable(details: reason)
        case .failed(let reason): return .failed(details: reason)
        default: return nil
        }
    }

    func dismissNotice() { notice = nil }

    /// Shows a notice directly (tests).
    func showNoticeForTesting(_ n: Notice) { notice = n }

    // MARK: Evaluate

    /// The request the next Evaluate sends: overrides, else the worker's defaults. Until
    /// the worker has answered, the runner's own defaults (which a test pins to the
    /// worker's) fill in, so nothing here is a number of the UI's own.
    func makeRequest(recordingID: UUID) -> EvaluationRunner.Request {
        let d = workerDefaults?.params
        var r = EvaluationRunner.Request(recordingID: recordingID, seed: parameters.seed ?? d?.seed ?? 0)
        if let d {
            r.windowOffsetSeconds = d.window.offset_s
            r.windowLengthSeconds = d.window.length_s
            r.cspComponents = d.csp_components
            r.leftLabel = d.labels.left
            r.rightLabel = d.labels.right
        }
        if let v = parameters.windowOffsetSeconds { r.windowOffsetSeconds = v }
        if let v = parameters.windowLengthSeconds { r.windowLengthSeconds = v }
        if let v = parameters.cspComponents { r.cspComponents = v }
        return r
    }

    func evaluate() {
        Task { await evaluateAndWait() }
    }

    @discardableResult
    func evaluateAndWait() async -> EvaluationRunner.State {
        guard let recordingID = selectedRecordingID, !isRunning else { return runner.state }
        notice = nil
        // The worker's defaults decide the request; a lookup in flight is waited for.
        await defaultsTask?.value
        let state = await runner.evaluateAndWait(makeRequest(recordingID: recordingID))
        await finished(state)
        return state
    }

    func retry() {
        Task { await retryAndWait() }
    }

    @discardableResult
    func retryAndWait() async -> EvaluationRunner.State {
        notice = nil
        let state = await runner.retryAndWait()
        await finished(state)
        if workerDefaults == nil, case .done = state { loadDefaults() }
        return state
    }

    func cancel() { runner.cancel() }

    private func finished(_ state: EvaluationRunner.State) async {
        switch state {
        case .done(let id):
            try? await reloadResults()
            section = .results
            selectedResultID = id
            let meta = results.first { $0.resultID == id }
            let original = { (oid: UUID) in self.results.first { $0.resultID == oid }?.createdAt }
            if let o = meta?.reproductionOf {
                notice = .reproduced(original: original(o))
            } else if let o = meta?.divergedFrom {
                notice = .diverged(original: original(o))
            } else {
                notice = .saved
            }
            announce(noticeText(notice!))
        case .cancelled:
            notice = .cancelled
            announce(noticeText(.cancelled))
        case .analysisUnavailable:
            announce("Analysis unavailable. Your recording is unchanged.")
        case .failed:
            announce("Evaluation failed. Nothing was saved.")
        default: break
        }
    }

    func noticeText(_ n: Notice) -> String {
        switch n {
        case .saved: return "Result saved to project"
        case .reproduced(let d): return "Reproduced — identical to \(d.map(Self.time) ?? "the") original"
        case .diverged(let d): return "Differs from original (\(d.map(Self.time) ?? "earlier run")). Same recording, configuration and seed gave different bytes; this is a bug."
        case .cancelled: return "Cancelled — nothing saved."
        case .exported(let url): return "Exported to \((url.path as NSString).abbreviatingWithTildeInPath)"
        case .exportFailed(let why): return "Export failed: \(why)"
        }
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Quality (brief 002)

    /// The Quality tab's state for the selected recording, derived from the runner alone:
    /// a pending request wins over the previous run's terminal state, and terminal states
    /// count only for the recording that run was for.
    var qualityState: QualityTabState {
        guard let id = selectedRecordingID else { return .notStarted }
        if let model = qualityModel(for: id) { return .ready(model) }
        if inspector.pendingRecordingID == id {
            if case .running(let rid, let p) = inspector.state, rid == id { return .running(p) }
            return .running(.starting)
        }
        guard !inspector.isBusy, inspector.lastRecordingID == id else { return .notStarted }
        switch inspector.state {
        case .analysisUnavailable(let d): return .unavailable(details: d)
        case .failed(let d): return .failed(details: d)
        case .cancelled: return .cancelled
        default: return .notStarted
        }
    }

    /// Built once per report: hover and selection re-renders never rebuild it.
    func qualityModel(for id: UUID) -> QualityModel? {
        if let m = qualityModels[id] { return m }
        guard let report = inspector.report(for: id) else { return nil }
        let m = QualityModel(report: report)
        qualityModels[id] = m
        return m
    }

    private func inspectIfFirstShown() {
        guard recordingTab == .quality, let id = selectedRecordingID, !isClosing, autoInspected.insert(id).inserted else { return }
        inspect()
    }

    /// Inspects the selected recording (Inspect, Retry, first show). A run for another
    /// recording is cancelled and this one queued behind it (`InspectionRunner.inspect`).
    func inspect() {
        guard let id = selectedRecordingID, !isClosing, inspector.report(for: id) == nil else { return }
        if inspector.isBusy, inspector.pendingRecordingID != id { inspector.cancel() }
        inspector.inspect(recordingID: id)
    }

    func cancelInspection() { inspector.cancel() }

    /// Waits until the runner is idle (tests, snapshots).
    func awaitInspection() async {
        while inspector.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Export

    /// Writes the export folder for `resultID` at `destination`; the outcome is a notice.
    func export(resultID: UUID, to destination: URL) async {
        do {
            try await store.export(result: resultID, to: destination)
            notice = .exported(destination)
        } catch ProjectStoreError.alreadyExists {
            notice = .exportFailed("\(destination.lastPathComponent) already exists. Export never overwrites; choose a new name.")
        } catch {
            notice = .exportFailed("\(error)")
        }
        announce(noticeText(notice!))
    }

    /// Set as `shutdown()` begins: nothing starts an inspection afterwards.
    private(set) var isClosing = false

    /// True once `shutdown()` has finished: no run, no worker, nothing loading.
    private(set) var isShutDown = false

    /// Stops everything this project runs: cancels the evaluation and waits (bounded) for
    /// it to end — a run that is storing its result finishes the commit first — then
    /// stops the worker for good. Called when the window closes and when the app quits.
    func shutdown() async {
        defaultsTask?.cancel()
        resultLoad?.cancel()
        recipesTask?.cancel()
        isClosing = true
        // The inspection worker stops alongside the evaluation, inside the same budget.
        async let inspection: Void = inspector.shutdown()
        await runner.stop(within: Self.stopLimit)
        await runner.shutdown()
        await inspection
        isShutDown = true
    }

    /// Under the app's 5 s quit backstop, so a commit in progress normally completes.
    static let stopLimit: Duration = .seconds(4)
}
