import AppKit
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
        /// `leftOut`: what the export had to leave out (ExportNoticeText), shown as a warning.
        case exported(URL, leftOut: String?)
        case exportFailed(String)
        /// Brief 006: a result's fit was frozen under this name.
        case frozen(name: String)
        /// Brief 006: a live run's `run.json` could not be finished (why).
        case liveRunNotSaved(String)

        /// Persistent notices are solid warning chips that stay until dismissed; the rest
        /// are toasts that dismiss themselves and clear on a section change (§2.5).
        var isPersistent: Bool {
            switch self {
            case .diverged, .exportFailed, .liveRunNotSaved: return true
            case .exported(_, let leftOut): return leftOut != nil
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
    /// Brief 002 signal view: trace windows on the inspection worker.
    let traces: SignalWindowRunner
    /// Brief 006: frozen models and replays, on a worker of their own.
    let frozen: FrozenModelsController
    /// The worker live runs start their own inference process from (brief 006).
    @ObservationIgnored let launch: WorkerLaunch?
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
        didSet {
            if section != oldValue, let n = notice, !n.isPersistent { notice = nil }
            if section == .protocols, section != oldValue { loadProtocols(addingDefault: true) }
            if section == .pipelines, section != oldValue { frozen.reloadInBackground() }
        }
    }

    // MARK: Protocols (brief 005)

    private(set) var protocolList: ProtocolList?
    private(set) var protocolUsage: [UUID: Int] = [:]
    private(set) var protocolsError: String?
    var selectedProtocolID: UUID?
    /// The "New version…" sheet's editor while it is open.
    var protocolEditor: ProtocolEditor?
    @ObservationIgnored private var protocolsTask: Task<Void, Never>?
    var selectedRecordingID: UUID? {
        didSet { if selectedRecordingID != oldValue { traceStartS = 0; inspectIfFirstShown() } }
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
    // MARK: Live acquisition (brief 004)

    /// This project's live board: the Connect sheet, then the acquisition screen under
    /// Recordings (decision #30). Nil until New Recording…; one per project.
    private(set) var live: ConnectController?
    var showsConnectSheet = false
    /// The Recordings list's Live row is selected (the acquisition screen is the detail).
    var liveShown = false {
        didSet { if liveShown, let n = notice, !n.isPersistent { notice = nil } }
    }

    /// The Live row exists while a board is connected or connecting through the screen.
    var hasLiveRow: Bool { live.map { $0.hasStreamed && !$0.isClosed && $0.state != .disconnected } ?? false }
    /// The list reload after a live recording ended (tests and snapshots wait on it).
    @ObservationIgnored private(set) var liveReload: Task<Void, Never>?
    var isRecording: Bool { live?.isRecordingNow ?? false }

    /// New Recording… and the welcome screen's Connect hardware: the Connect sheet, or the
    /// acquisition screen when a board is already streaming.
    func showConnectSheet() {
        guard !isClosing else { return }
        // While recording, New Recording… shows the recording in progress instead.
        if let live, !live.isClosed, live.isRecordingNow {
            section = .recordings
            liveShown = true
            return
        }
        if live == nil || live?.isClosed == true { makeLive() }
        section = .recordings
        showsConnectSheet = true
    }

    @discardableResult private func makeLive() -> ConnectController { wire(ConnectController(store: store, projectDirectory: url)) }

    /// Hooks a controller to this project: the sheet hands over to the screen when the
    /// stream starts, and the list reloads when a recording ends. Tests pass their own.
    @discardableResult
    func wire(_ c: ConnectController) -> ConnectController {
        live = c
        c.onStreamStarted = { [weak self] in
            guard let self else { return }
            self.showsConnectSheet = false
            self.section = .recordings
            self.liveShown = true
        }
        c.onRecordingEnded = { [weak self] _ in
            guard let self else { return }
            let previous = self.liveReload
            self.liveReload = Task { await previous?.value; await self.reload() }
        }
        return c
    }

    /// The sheet went away (Close, Escape, or the stream started).
    func connectSheetClosed() {
        showsConnectSheet = false
        if live?.isClosed == true { live = nil; liveShown = false }
    }

    /// The acquisition screen's Disconnect: a recording ends `stopped`, the board goes.
    func endLive() async {
        guard let live else { return }
        runs?.tearDown()
        runs = nil
        // A check in progress is called off (its replay cancelled); stop still writes run.json.
        if liveFeedback?.phase == .checking { frozen.runner.cancel() }
        await liveFeedback?.stop()
        await live.close()
        if self.live === live { self.live = nil }
        liveShown = false
    }

    // MARK: Protocol runs (brief 005)

    /// The session of protocol runs on the live stream; kept after Finish for its summaries.
    private(set) var runs: RunController?
    var startRunForm: StartRunForm?
    private(set) var startRunError: String?
    /// Why Start in the sheet didn't start; the sheet stays open and shows it.
    private(set) var startRunSheetError: String?
    /// The protocol a recording's run plans name; absent for any other recording.
    private(set) var recordingProtocols: [UUID: ProtocolRecord] = [:]

    var startRunDisabledReason: String? {
        guard let live else { return RecordGate.notStreaming }
        if runs.map({ !$0.isFinished }) ?? false { return StartRunCopy.alreadyRecording }
        return live.recordDisabledReason ?? (live.isRecordingNow ? StartRunCopy.alreadyRecording : nil)
    }

    /// Start run…: the protocols (the default added to a project without any) and displays.
    func showStartRun(operatorScreen: NSScreen?) async {
        guard startRunDisabledReason == nil else { return }
        startRunError = nil
        do {
            _ = try await store.ensureDefaultProtocol()
            let list = try await store.protocols()
            startRunForm = StartRunForm(protocols: list.protocols.filter { !list.mislinked.contains($0.protocolID) },
                                        displays: CueWindowController.displays(operatorScreen: operatorScreen),
                                        remembered: CueDisplayPicker.remembered(in: .standard))
        } catch {
            startRunError = ProtocolCopy.unreadableList(error)
        }
    }

    /// Opens the participant window on the chosen display and starts the first run.
    func startRuns(_ form: StartRunForm) {
        guard let (setup, host, screen) = prepareRuns(form) else { return }
        startRunForm = nil
        startRuns(setup, host: host, surface: CueWindowController(scheduler: CueFrameScheduler(), screen: screen))
    }

    /// The checks Start makes before anything runs; sets `startRunSheetError` when one fails.
    private func prepareRuns(_ form: StartRunForm) -> (RunController.Setup, AcquisitionRunHost, NSScreen)? {
        startRunSheetError = nil
        if let reason = form.disabledReason(streamReason: startRunDisabledReason) { startRunSheetError = reason; return nil }
        guard let p = form.selected, let seed = form.seed, let display = form.display else { return nil }
        // The display list is from when the sheet opened; never fail silently on a stale one.
        guard let screen = CueWindowController.screen(for: display) else { startRunSheetError = StartRunCopy.displayGone; return nil }
        guard let host = live?.runHost() else { startRunSheetError = live?.recordDisabledReason ?? RecordGate.notStreaming; return nil }
        CueDisplayPicker.remember(display, in: .standard)
        let setup = RunController.Setup(protocolRecord: p, sessionSeed: seed, runsPerSession: form.runsPerSession, display: display,
                                        framePeriodNanos: 1_000_000_000 / Int64(max(1, screen.maximumFramesPerSecond)))
        return (setup, host, screen)
    }

    // MARK: Live runs (brief 006)

    /// The live run of the current (or last) session of runs.
    private(set) var liveFeedback: LiveFeedbackController?
    /// Set while a live run's worker starts; Start stays disabled.
    private(set) var isStartingLive = false
    /// From Start until its replay check is stored: Evaluate and Replay are paused.
    var isLiveRunning: Bool { liveFeedback.map { $0.phase != .ended } ?? false }
    /// The Live Test list's selection: a live run, or nil for the setup.
    var selectedLiveRunID: UUID?
    /// Live Test setup: the protocol run's form (protocol, seed, display) and the live part.
    var liveRunForm: StartRunForm?
    var liveTestForm = LiveTestForm()

    /// The setup's choices: protocols (the default added if none), displays, and a model that
    /// fits the connected stream when there is one.
    func prepareLiveSetup(operatorScreen: NSScreen?) async {
        await frozen.awaitLoads()
        if let list = try? await { _ = try await store.ensureDefaultProtocol(); return try await store.protocols() }() {
            let protocols = list.protocols.filter { !list.mislinked.contains($0.protocolID) }
            if liveRunForm == nil || liveRunForm?.protocols != protocols {
                var form = StartRunForm(protocols: protocols, displays: CueWindowController.displays(operatorScreen: operatorScreen),
                                        remembered: CueDisplayPicker.remembered(in: .standard))
                if let keep = liveRunForm?.protocolID, protocols.contains(where: { $0.protocolID == keep }) { form.pick(keep) }
                liveRunForm = form
            }
        }
        if liveTestForm.modelID.map({ id in !frozen.models.contains { $0.modelID == id } }) ?? true {
            liveTestForm.modelID = (frozen.models.first { liveMismatch($0) == nil } ?? frozen.models.first)?.modelID
        }
    }

    /// Why `model` can't run on the connected stream, or nil (also nil with nothing connected).
    func liveMismatch(_ model: ModelRecord) -> String? {
        guard let live, let board = live.snapshot.board, let request = live.runHost()?.request else { return nil }
        return LiveRunCopy.mismatch(model: model, channelIDs: request.channels.map(\.id), rateHz: Double(board.samplingRate))
    }

    /// This project's window (the operator's display for the setup's display list).
    var projectWindow: NSWindow? { NSApp.windows.first { $0.title == name && $0.styleMask.contains(.titled) } }

    var liveSetupModel: ModelRecord? { frozen.models.first { $0.modelID == liveTestForm.modelID } }

    /// Why Start Live Run is disabled, or nil.
    var liveStartDisabledReason: String? {
        if isStartingLive { return LiveRunCopy.starting }
        if frozen.models.isEmpty { return LiveRunCopy.noModels }
        guard live?.snapshot.board != nil, live?.state == .streaming else { return LiveRunCopy.noSource }
        guard let model = liveSetupModel else { return LiveRunCopy.noModels }
        if let m = liveMismatch(model) { return m }
        if case .failure(let p) = liveTestForm.policy { return p.text }
        guard let form = liveRunForm else { return StartRunCopy.noProtocol }
        if let p = form.selected, let m = LiveRunCopy.classMismatch(model: model, protocolRecord: p) { return m }
        if let p = form.selected, FeedbackFeed.directions(classes: p.classes, modelLabels: model.classLabels) == nil { return LiveTestCopy.directionProblem }
        return form.disabledReason(streamReason: startRunDisabledReason)
    }

    /// Start Live Run in the Live Test setup.
    func startLiveFromSetup() async {
        guard liveStartDisabledReason == nil, let form = liveRunForm, let model = liveSetupModel, case .success(let policy) = liveTestForm.policy else { return }
        await startLiveRuns(form, model: model, policy: policy)
    }

    /// Starts a live run: the inference worker first (a model that doesn't match the stream
    /// is refused here, before anything runs), then the protocol runs with feedback on.
    func startLiveRuns(_ form: StartRunForm, model: ModelRecord, policy: FeedbackPolicy) async {
        guard !isStartingLive, !isLiveRunning, let (setup, host, screen) = prepareRuns(form), let board = live?.snapshot.board else { return }
        // Checked again here, not only in the setup: the classes must be the model's, and cue on opposite sides.
        if let m = LiveRunCopy.classMismatch(model: model, protocolRecord: setup.protocolRecord) { startRunSheetError = m; return }
        if FeedbackFeed.directions(classes: setup.protocolRecord.classes, modelLabels: model.classLabels) == nil {
            startRunSheetError = LiveTestCopy.directionProblem; return
        }
        isStartingLive = true
        defer { isStartingLive = false }
        var request = host.request
        request.recordingID = UUID()
        do {
            let c = try await LiveFeedbackController.start(model: model, protocolRecord: setup.protocolRecord, policy: policy, store: store,
                                                           launch: launch, session: host.session, board: board, request: request)
            startRunForm = nil
            startRuns(setup, host: AcquisitionRunHost(session: host.session, request: request, store: store),
                      surface: CueWindowController(scheduler: CueFrameScheduler(), screen: screen), feedback: c)
        } catch let e as WorkerError {
            startRunSheetError = ModelErrorText.describe(code: e.code, message: e.message)
        } catch {
            startRunSheetError = "\(error)"
        }
    }

    /// Tests pass a fake surface and host. With `feedback`, the runs are a live run's:
    /// cues reach its runner and the participant window draws its bar.
    func startRuns(_ setup: RunController.Setup, host: any ProtocolRunHost, surface: any CueSurface, options: ProtocolRunner.Options = .init(),
                   feedback: LiveFeedbackController? = nil) {
        runs?.tearDown()
        if liveFeedback !== feedback { liveFeedback?.tearDown() }
        liveFeedback = feedback
        let host = feedback?.host(wrapping: host) ?? host
        surface.attachFeedback(feedback?.feed)
        let live = live
        let r = RunController(setup: setup, host: host, store: store, surface: surface, options: options,
                              onRecording: { [weak live] id in live?.adoptRecording(id) },
                              stopRecording: { [weak live] in await live?.stopRecording() })
        r.operatorWindow = NSApp.windows.first { $0.title == name && $0.styleMask.contains(.titled) }
        runs = r
        r.startNextRun()
    }

    func finishRuns() async {
        await runs?.finish()
        await liveReload?.value
        if let c = liveFeedback, c.phase == .running {
            await c.stop(replay: { [weak self] model, recording, threshold, cue in
                guard let self else { return .failure(.init(reason: "the project closed")) }
                return await self.replayForCheck(model: model, recording: recording, threshold: threshold, cue: cue)
            })
            await frozen.reload()
            if let run = frozen.liveRuns.first(where: { $0.liveRunID == c.liveRunID }) { await frozen.loadInputs(run, force: true) }
            selectedLiveRunID = c.liveRunID
            if let why = c.finishProblem {
                notice = .liveRunNotSaved(why)
                announce(noticeText(notice!))
            }
        }
    }

    /// The live-vs-replay check's replay: the frozen-model worker, as Replay… uses it.
    private func replayForCheck(model: ModelRecord, recording: UUID, threshold: Double, cue: Double)
        async -> Result<[PredictionRecord], LiveFeedbackController.ReplayFailure> {
        let state = await frozen.runner.replay(model: model, recordingID: recording, abstainThreshold: threshold, cueLengthSeconds: cue)
        if case .cancelled = state { return .failure(.init(reason: LiveRunCopy.checkCancelled)) }
        guard case .done(let id) = state else { return .failure(.init(reason: "the replay didn't finish (\(state))")) }
        do { return .success(try await store.predictions(liveRun: id).records) } catch { return .failure(.init(reason: "\(error)")) }
    }

    func dismissRuns() {
        guard runs?.isFinished ?? true else { return }
        runs = nil
    }

    /// "Show Recording": selects a recording the live board made.
    func showRecording(_ id: UUID) {
        liveShown = false
        section = .recordings
        selectedRecordingID = id
    }


    private var defaultsTask: Task<Void, Never>?
    private var resultLoad: Task<Void, Never>?

    init(store: ProjectStore, url: URL, launch: WorkerLaunch?, name: String) {
        self.url = url
        self.store = store
        self.runner = EvaluationRunner(store: store, launch: launch)
        self.inspector = InspectionRunner(projectDirectory: url, launch: launch)
        self.traces = SignalWindowRunner(inspector: inspector)
        self.frozen = FrozenModelsController(store: store, launch: launch)
        self.launch = launch
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
            var protocols: [UUID: ProtocolRecord] = [:]
            if let known = try? await store.protocols().protocols, !known.isEmpty {
                for id in ids {
                    guard let plan = try? await store.runPlans(recording: id).plans.first else { continue }
                    protocols[id] = known.first { $0.protocolID == plan.protocolID }
                }
            }
            recordings = handles
            eventsByRecording = events
            recordingProtocols = protocols
            if selectedRecordingID == nil || !ids.contains(selectedRecordingID!) { selectedRecordingID = ids.first }
            try await reloadResults()
            await frozen.reload()
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

    /// Lists the protocols and their use. `addingDefault` (only on entering the section)
    /// first gives a project with no protocol at all the default (decision #28).
    func loadProtocols(addingDefault: Bool = false) {
        protocolsTask?.cancel()
        protocolsTask = Task { [weak self] in
            guard let self else { return }
            var error: String?
            if addingDefault {
                do { _ = try await self.store.ensureDefaultProtocol() } catch let e {
                    error = ProtocolCopy.defaultNotSaved(e, writable: FileManager.default.isWritableFile(atPath: self.url.path))
                }
            }
            do {
                let list = try await self.store.protocols()
                let usage = try await self.store.protocolUsage()
                guard !Task.isCancelled else { return }
                self.protocolList = list
                self.protocolUsage = usage
                self.protocolsError = error
                if self.selectedProtocolID.map({ id in !list.protocols.contains { $0.protocolID == id } }) ?? true {
                    self.selectedProtocolID = ProtocolListModel(list: list, usage: usage).groups.first?.rows.first?.id
                }
            } catch let e {
                self.protocolsError = ProtocolCopy.unreadableList(e)
            }
        }
    }

    func awaitProtocols() async { await protocolsTask?.value }

    var selectedProtocol: ProtocolRecord? {
        protocolList?.protocols.first { $0.protocolID == selectedProtocolID }
    }

    /// Where the default evaluation window ends (offset + length), for the cue warning.
    var evaluationWindowEndMs: Int {
        let offset = parameters.windowOffsetSeconds ?? workerDefaults?.params.window.offset_s ?? 0.5
        let length = parameters.windowLengthSeconds ?? workerDefaults?.params.window.length_s ?? 3.5
        let end = (offset + length) * 1000
        return end.isFinite ? Int(min(max(end, 0), 1e9).rounded()) : 4000
    }

    func newProtocolVersion(of base: ProtocolRecord) {
        guard let list = protocolList, !list.mislinked.contains(base.protocolID) else { return }
        let lineage = list.protocols.filter { list.lineage(of: $0) == list.lineage(of: base) }
        protocolEditor = ProtocolEditor(base: base, lineage: lineage, windowEndMs: evaluationWindowEndMs)
    }

    /// Saves the editor's draft as a new version and selects it; keeps the sheet open with
    /// the store's reason when it refuses.
    func saveProtocolEditor() async {
        guard let editor = protocolEditor, editor.canSave, let draft = editor.draft else { return }
        editor.isSaving = true
        defer { editor.isSaving = false }
        do {
            let record = try await store.createProtocolVersion(draft, basedOn: editor.base)
            protocolEditor = nil
            selectedProtocolID = record.protocolID
            loadProtocols()
            await awaitProtocols()
        } catch {
            editor.saveError = ProtocolCopy.notSaved(error)
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

    var canEvaluate: Bool {
        guard let handle = selectedRecording, !isRunning, !liveShown, !isLiveRunning else { return false }
        return RunCountModel.evaluableRuns(eventsByRecording[handle.id] ?? []) >= RunCountModel.minimumRuns
    }

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
        // A protocol recording evaluates its own classes (brief 005), not the worker's defaults.
        if let p = recordingProtocols[recordingID], p.classes.count == 2 {
            r.leftLabel = p.classes[0].label
            r.rightLabel = p.classes[1].label
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
        // Training never competes with inference (PRD §7): paused during a live run.
        guard let recordingID = selectedRecordingID, !isRunning, !isLiveRunning else { return runner.state }
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
        case .exported(let url, let leftOut): return ExportNoticeText.exported(url, leftOut: leftOut)
        case .exportFailed(let why): return "Export failed: \(why)"
        case .frozen(let name): return ReplayCopy.frozen(name)
        case .liveRunNotSaved(let why): return LiveRunCopy.runNotSaved(why)
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

    // MARK: Signal view (brief 002)

    /// The trace window's start (segment seconds) and Raw / Band-passed choice.
    var traceStartS: Double = 0
    var traceBandpassed = false
    @ObservationIgnored private var traceCache: (key: String, model: TraceModel)?

    /// Asks for the window at `traceStartS` in a segment (its worker index).
    func loadTrace(segment: Int) {
        guard let id = selectedRecordingID, !isClosing else { return }
        traces.load(.init(recordingID: id, segment: segment, startS: traceStartS))
    }

    /// The window on screen for this recording and segment (the last one received, while
    /// the next loads); nil before the first arrives. Built once per window and mode.
    func traceModel(segment: Int, section: Int) -> TraceModel? {
        guard let id = selectedRecordingID, let w = traces.window, w.recordingId == id.uuidString, w.segment == segment,
              let quality = qualityModel(for: id) else { return nil }
        let key = "\(w.recordingId)/\(w.segment)/\(w.startS)/\(traceBandpassed)"
        if let c = traceCache, c.key == key { return c.model }
        let m = TraceModel(window: w, processed: traceBandpassed, flags: quality.flagTitles(section: section))
        traceCache = (key, m)
        return m
    }

    // MARK: Freeze and replay (brief 006)

    /// Freeze for live use…: the sheet for `stored`, with its training sessions (from the
    /// recording) and the protocol's cue length (nil for imported data).
    func showFreeze(_ stored: StoredResult) {
        let report = try? EvaluationReport.decode(stored.evaluationJSON)
        let segments = recordings.first { $0.id == stored.meta.recordingID }?.manifest.segments ?? []
        let sessions = (report?.splitManifest.trainingRuns ?? []).map { run in segments.first { $0.runID == run }?.sessionID }
        let sheet = FreezeSheetModel(result: stored, report: report, role: .reference, sessions: sessions,
                                     cueLengthSeconds: cueLength(stored.meta.recordingID))
        frozen.freezeDraft = .init(result: stored, report: report, sessions: sessions, cueLengthSeconds: cueLength(stored.meta.recordingID),
                                   name: sheet.defaultName)
    }

    @discardableResult
    func freeze() async -> ModelRecord? {
        guard let model = await frozen.freeze() else { return nil }
        notice = .frozen(name: model.name)
        announce(noticeText(notice!))
        return model
    }

    /// Replay… from a recording (model to pick) or a model (recording to pick).
    func showReplay(model: UUID? = nil, recording: UUID? = nil) {
        guard !isLiveRunning else { return }
        frozen.replayDraft = .init(modelID: model ?? frozen.models.first?.modelID, recordingID: recording ?? selectedRecordingID ?? recordings.first?.id)
    }

    @discardableResult
    func replay() async -> ReplayRunner.State? {
        let state = await frozen.replay(cueLength: cueLength)
        // The parity view is under Pipelines; switched to once the sheet has closed
        // (changing the section while a sheet closes can leave it stuck on screen).
        if case .done = state { showPipelinesAfterSheet = true }
        return state
    }

    /// Set by a finished replay; the Replay sheet's dismissal shows Pipelines.
    var showPipelinesAfterSheet = false

    func replaySheetClosed() {
        if showPipelinesAfterSheet { section = .pipelines }
        showPipelinesAfterSheet = false
    }

    /// The protocol's cue length for a recording its run plans name, else nil.
    func cueLength(_ recording: UUID) -> Double? {
        recordingProtocols[recording].map { Double($0.timing.cueMs) / 1000 }
    }

    // MARK: Export

    /// Writes the export folder for `resultID` at `destination`; the outcome is a notice.
    func export(resultID: UUID, to destination: URL) async {
        do {
            let summary = try await store.export(result: resultID, to: destination)
            notice = .exported(destination, leftOut: ExportNoticeText.leftOut(summary))
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
        // Stops a recording (`stopped`, partial chunk flushed) and releases the board.
        runs?.tearDown()
        // A check in progress is called off (its replay cancelled); stop still writes run.json.
        if liveFeedback?.phase == .checking { frozen.runner.cancel() }
        await liveFeedback?.stop()
        await live?.close()
        // The inspection worker stops alongside the evaluation, inside the same budget.
        async let inspection: Void = inspector.shutdown()
        async let models: Void = frozen.shutdown()
        await runner.stop(within: Self.stopLimit)
        await runner.shutdown()
        await inspection
        await models
        isShutDown = true
    }

    /// Under the app's 5 s quit backstop, so a commit in progress normally completes.
    static let stopLimit: Duration = .seconds(4)
}
