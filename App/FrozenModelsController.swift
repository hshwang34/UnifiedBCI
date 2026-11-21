import Foundation
import Observation

/// One project's frozen models and replays (brief 006 PR 5): the Freeze sheet, the
/// Pipelines list, the Replay… sheet and the parity view. All I/O goes through the store
/// actor and `ReplayRunner`'s own worker, never the main thread.
@MainActor
@Observable
final class FrozenModelsController {
    /// The open Freeze sheet: the result and the facts its copy is built from.
    struct FreezeDraft: Identifiable {
        let id = UUID()
        let result: StoredResult
        let report: EvaluationReport?
        let sessions: [String?]
        let cueLengthSeconds: Double?
        var role: ModelRole = .reference
        var name: String
        var error: String?
        var isFreezing = false

        var sheet: FreezeSheetModel {
            FreezeSheetModel(result: result, report: report, role: role, sessions: sessions, cueLengthSeconds: cueLengthSeconds)
        }
    }

    /// The open Replay… sheet: a model and a recording, one of them fixed by where it opened.
    struct ReplayDraft: Identifiable {
        let id = UUID()
        var modelID: UUID?
        var recordingID: UUID?
        var thresholdText = Fmt.fixed(0.6)
        var error: String?
        /// Set when Replay was pressed: the runner's state belongs to this sheet from then on.
        var started = false

        var threshold: Double? { Double(thresholdText.trimmingCharacters(in: .whitespaces)) }
    }

    let runner: ReplayRunner
    private let store: ProjectStore
    private(set) var models: [ModelRecord] = []
    private(set) var liveRunCounts: [UUID: Int] = [:]
    /// Stored replays, newest first.
    private(set) var replays: [LiveRunRecord] = []
    private(set) var loadError: String?
    var selectedModelID: UUID? {
        didSet { if selectedModelID != oldValue { selectedReplayID = replays(of: selectedModelID).first?.liveRunID } }
    }
    var selectedReplayID: UUID? {
        didSet { if selectedReplayID != oldValue { loadParityPredictions() } }
    }
    /// The selected replay's predictions (for the cue-locked match), once read.
    private(set) var parityPredictions: (id: UUID, records: [PredictionRecord])?
    /// Which sheet is up. One sheet modifier serves both: two `.sheet`s presented one after
    /// the other on one view can leave the first stuck on screen (macOS SwiftUI).
    enum Sheet: String, Identifiable { case freeze, replay; var id: String { rawValue } }
    var sheet: Sheet?
    var freezeDraft: FreezeDraft? {
        didSet { syncSheet(.freeze, open: freezeDraft != nil, wasOpen: oldValue != nil) }
    }
    var replayDraft: ReplayDraft? {
        didSet { syncSheet(.replay, open: replayDraft != nil, wasOpen: oldValue != nil) }
    }

    private func syncSheet(_ kind: Sheet, open: Bool, wasOpen: Bool) {
        if open, !wasOpen { sheet = kind } else if !open, wasOpen, sheet == kind { sheet = nil }
    }

    /// Edits from the open sheet. A closing sheet's text field commits its text once more;
    /// that write must not bring back a draft that freeze, replay or Cancel already ended.
    func updateFreezeDraft(_ d: FreezeDraft) { if freezeDraft?.id == d.id { freezeDraft = d } }
    func updateReplayDraft(_ d: ReplayDraft) { if replayDraft?.id == d.id { replayDraft = d } }

    /// The sheet went away (Escape, Cancel, or a finished freeze or replay).
    func sheetClosed() {
        sheet = nil
        freezeDraft = nil
        replayDraft = nil
    }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var predictionsTask: Task<Void, Never>?

    init(store: ProjectStore, launch: WorkerLaunch?) {
        self.store = store
        runner = ReplayRunner(store: store, launch: launch)
    }

    var selectedModel: ModelRecord? { models.first { $0.modelID == selectedModelID } }
    var selectedReplay: LiveRunRecord? { replays.first { $0.liveRunID == selectedReplayID } }

    func replays(of model: UUID?) -> [LiveRunRecord] { replays.filter { $0.modelID == model } }

    func rows(results: [ResultMeta]) -> [FrozenModelRowModel] {
        models.map { m in
            FrozenModelRowModel(model: m, sourceResultDate: results.first { $0.resultID == m.sourceResultID }?.createdAt,
                                liveRuns: liveRunCounts[m.modelID] ?? 0)
        }
    }

    func reload() async {
        do {
            let m = try await store.models().models
            let runs = try await store.liveRuns().runs
            models = m
            replays = runs.filter { $0.kind == .replay }
            liveRunCounts = Dictionary(grouping: runs.filter { $0.kind == .live }, by: \.modelID).mapValues(\.count)
            loadError = nil
            if selectedModelID.map({ id in !m.contains { $0.modelID == id } }) ?? true { selectedModelID = m.first?.modelID }
            if selectedReplayID == nil { selectedReplayID = replays(of: selectedModelID).first?.liveRunID }
        } catch {
            loadError = "\(error)"
        }
    }

    func reloadInBackground() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.reload() }
    }

    func awaitLoads() async {
        await loadTask?.value
        await predictionsTask?.value
    }

    // MARK: Freeze

    /// Freezes the draft's fit; on success closes the sheet, selects the new model and
    /// returns it. On failure the sheet stays open with the reason.
    func freeze() async -> ModelRecord? {
        guard var draft = freezeDraft, !draft.isFreezing, draft.sheet.canFreeze else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.isFreezing = true
        draft.error = nil
        freezeDraft = draft
        do {
            let model = try await runner.freeze(result: draft.result, role: draft.role, name: name.isEmpty ? draft.sheet.defaultName : name)
            freezeDraft = nil
            await reload()
            selectedModelID = model.modelID
            return model
        } catch {
            freezeDraft?.isFreezing = false
            freezeDraft?.error = ReplayCopy.freezeFailed(error)
            return nil
        }
    }

    // MARK: Replay

    /// Replays the draft; on success closes the sheet and selects the stored replay. The
    /// sheet stays open with the runner's words otherwise. `cueLength` is the protocol's
    /// cue for the recording, nil for imported data.
    @discardableResult
    func replay(cueLength: (UUID) -> Double?) async -> ReplayRunner.State? {
        guard let draft = replayDraft, !runner.isBusy else { return nil }
        guard let model = models.first(where: { $0.modelID == draft.modelID }), let recording = draft.recordingID else { return nil }
        guard let t = draft.threshold, ModelErrorText.thresholdProblem(t) == nil else {
            replayDraft?.error = ModelErrorText.thresholdProblem(draft.threshold ?? .nan)
            return nil
        }
        replayDraft?.error = nil
        replayDraft?.started = true
        let state = await runner.replay(model: model, recordingID: recording, abstainThreshold: t, cueLengthSeconds: cueLength(recording))
        if case .done(let id) = state {
            replayDraft = nil
            await reload()
            selectedModelID = model.modelID
            selectedReplayID = id
        }
        return state
    }

    func shutdown() async {
        loadTask?.cancel()
        predictionsTask?.cancel()
        await runner.shutdown()
    }

    private func loadParityPredictions() {
        predictionsTask?.cancel()
        guard let id = selectedReplayID else { parityPredictions = nil; return }
        if parityPredictions?.id == id { return }
        parityPredictions = nil
        predictionsTask = Task { [weak self, store] in
            let records = (try? await store.predictions(liveRun: id).records) ?? []
            guard !Task.isCancelled, let self, self.selectedReplayID == id else { return }
            self.parityPredictions = (id, records)
        }
    }
}
