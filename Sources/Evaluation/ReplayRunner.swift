import Foundation
import Observation

/// Freezes models and replays recordings through them (brief 006): one request at a time,
/// on its own worker so a replay never queues behind an evaluation. A replay runs the
/// streaming path at several chunkings beside the offline reference in the worker, then
/// stores the parity report and the first chunking's predictions as `live/<uuid>/` (kind
/// `replay`). Failures split as in `EvaluationRunner`, plus `refused` for the model codes
/// (`invalid_model`, `channel_mismatch`), whose words come from `ModelErrorText`.
@MainActor
@Observable
public final class ReplayRunner {
    public enum Progress: Sendable, Equatable { case starting, loading, replaying, storing }

    public enum State: Sendable, Equatable {
        case idle
        case running(Progress)
        case done(liveRunID: UUID)
        case analysisUnavailable(reason: String)
        /// The worker refused the model or the recording; `code` is its error code.
        case refused(code: String, message: String)
        case failed(reason: String)
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var lastReplay: LiveRunRecord?
    /// Set when `cancel()` arrives while the replay is being stored: storing is short and
    /// finishes cleanly (a half-stored replay can't exist), so the cancel is refused and
    /// this says so. Cleared on the next replay.
    public private(set) var cancelNotice: String?
    public let store: ProjectStore
    public let callTimeout: Duration

    private let launch: WorkerLaunch?
    private var client: WorkerClient?
    private var eventTask: Task<Void, Never>?
    private var currentRequestID: String?
    private var cancelRequested = false
    public private(set) var isBusy = false

    public init(store: ProjectStore, launch: WorkerLaunch?, callTimeout: Duration = .seconds(600)) {
        self.store = store
        self.launch = launch
        self.callTimeout = callTimeout
    }

    // MARK: Freeze

    /// Validates the result's fitted arrays in the worker, then freezes them (decision #38).
    /// Throws `WorkerError` (`invalid_model` and the rest) or a store refusal.
    /// Refused while a replay runs, so it can never discard the client that replay uses.
    public func freeze(result: StoredResult, role: ModelRole, name: String) async throws -> ModelRecord {
        guard !isBusy else { throw WorkerError(code: "busy", message: "a replay is running; freeze when it has finished") }
        isBusy = true
        defer { isBusy = false }
        let client = try await readyClient()
        let arrays = await store.fittedArraysURL(pipelineID: result.pipeline.pipelineID)
        do {
            let summary = try await client.validateModel(ModelArraysRef(arraysPath: arrays.path, sha256: nil, role: role),
                                                         nChannels: result.pipeline.expectedChannelIDs.count)
            return try await store.freeze(pipeline: result.pipeline.pipelineID, result: result.meta.resultID, role: role,
                                          name: name, validation: summary)
        } catch let error as WorkerError {
            if Self.isWorkerGone(error.code) { discardClient(client) }
            throw error
        }
    }

    // MARK: Replay

    /// Replays `recordingID` through `model`. `cueLengthSeconds` is the imagery span for
    /// trials without a `cue_end` event (the protocol's cue, or nil for imported data).
    @discardableResult
    public func replay(model: ModelRecord, recordingID: UUID, abstainThreshold: Double = 0.6, cueLengthSeconds: Double? = nil) async -> State {
        guard !isBusy else { return state }
        if let problem = ModelErrorText.thresholdProblem(abstainThreshold) { return finish(.refused(code: "invalid_threshold", message: problem)) }
        isBusy = true
        cancelRequested = false
        cancelNotice = nil
        defer { isBusy = false; currentRequestID = nil }
        state = .running(.starting)
        let client: WorkerClient
        do {
            client = try await readyClient()
        } catch {
            return finish(cancelRequested ? .cancelled : .analysisUnavailable(reason: "\(error)"))
        }
        let staging: URL
        do { staging = try await store.stagingDirectory() } catch { return finish(.failed(reason: "\(error)")) }
        defer { Task { [store] in await store.discardStagingDirectory(staging) } }
        guard !cancelRequested else { return finish(.cancelled) }
        let requestID = "replay-\(UUID().uuidString)"
        currentRequestID = requestID
        let file = staging.appendingPathComponent("replay-predictions.jsonl")
        let started = Date()
        let report: ReplayReport
        do {
            report = try await client.replayRecording(
                projectDirectory: store.directory, recordingID: recordingID, model: model, arraysPath: await store.arraysURL(for: model).path,
                predictionsPath: file, abstainThreshold: abstainThreshold, cueLengthSeconds: cueLengthSeconds, requestID: requestID, timeout: callTimeout)
        } catch let error as WorkerError {
            if error.code == "timeout" { await client.forceTerminate() }
            if Self.isWorkerGone(error.code) { discardClient(client) }
            if cancelRequested || error.code == "cancelled" { return finish(.cancelled) }
            if Self.isWorkerGone(error.code) { return finish(.analysisUnavailable(reason: error.message)) }
            if ModelErrorText.modelCodes.contains(error.code) { return finish(.refused(code: error.code, message: error.message)) }
            return finish(.failed(reason: error.description))
        } catch {
            return finish(.failed(reason: "unreadable replay_recording response: \(error)"))
        }
        guard !cancelRequested else { return finish(.cancelled) }
        state = .running(.storing)
        do {
            let predictions = try await Task.detached { try Self.readPredictions(file, model: model, threshold: abstainThreshold) }.value
            let handle = try await store.recording(id: recordingID)
            let record = LiveRunRecord(kind: .replay, modelID: model.modelID, recordingID: recordingID,
                                       runIDs: Array(Set(handle.manifest.segments.map(\.runID))).sorted(), hopSamples: WorkerClient.hopSamples,
                                       abstainThreshold: abstainThreshold, staleLimitMillis: nil, startedAt: started, endedAt: Date(),
                                       parity: Self.parity(report, predictions: predictions), summary: Self.summary(predictions))
            try await store.storeReplay(record, predictions: predictions)
            lastReplay = record
            return finish(.done(liveRunID: record.liveRunID))
        } catch {
            return finish(.failed(reason: "\(error)"))
        }
    }

    public func cancel() {
        guard isBusy, !cancelRequested else { return }
        if state == .running(.storing) {
            cancelNotice = "The replay is being saved and can't be cancelled now."
            return
        }
        cancelRequested = true
        guard let client, let id = currentRequestID else { return }
        Task { _ = try? await client.cancel(requestID: id) }
    }

    public func shutdown() async {
        cancel()
        let old = client
        eventTask?.cancel()
        eventTask = nil
        client = nil
        if let old { await old.shutdown() }
    }

    // MARK: Conversion (also used by live runs)

    /// A worker prediction as a `PredictionRecord`: abstain below `threshold` (decision #39)
    /// or for any window without a valid score; otherwise the class the score favours.
    /// Throws when the worker's class disagrees with the sign of its own score.
    nonisolated static func record(_ p: WorkerPrediction, model: ModelRecord, threshold: Double, sequence: Int,
                                   emittedAt: Int64? = nil) throws -> PredictionRecord {
        let validity = Validity(rawValue: p.validity) ?? .invalidInput
        if let s = p.score, let k = p.predictedClass, k != (s > 0 ? 1 : 0) {
            throw WorkerError(code: "protocol_mismatch", message: "prediction \(sequence): class \(k) disagrees with score \(s)")
        }
        var action = PredictionRecord.Action.abstain
        if validity == .valid, let s = p.score, let c = p.confidence, c >= threshold { action = .chosen(model.classLabels[s > 0 ? 1 : 0]) }
        return PredictionRecord(
            pipelineID: model.sourcePipelineID, inputSegment: p.segment ?? 0,
            inputSampleRange: .init(start: p.windowStart, count: max(0, p.windowStop - p.windowStart)), score: p.score, validity: validity,
            emittedAtMonotonicNanos: emittedAt, action: action, feedbackPresentedAtMonotonicNanos: nil, sequence: sequence,
            validityDetail: p.detail, confidence: p.confidence, windowKind: p.kind, trialID: p.trialId, predictedClass: p.predictedClass, feedbackEligible: p.feedbackEligible,
            offline: p.offline.map { .init(validity: Validity(rawValue: $0.validity) ?? .invalidInput, score: $0.score) })
    }

    nonisolated static func readPredictions(_ url: URL, model: ModelRecord, threshold: Double) throws -> [PredictionRecord] {
        guard let data = BoundedRead.data(at: url, maxBytes: ProjectStore.liveLogBytes) else {
            throw WorkerError(code: "protocol_mismatch", message: "the worker's replay predictions are missing or too large")
        }
        let decoder = WorkerClient.snakeDecoder()
        return try data.split(separator: 0x0A).enumerated().map { i, line in
            try record(try decoder.decode(WorkerPrediction.self, from: line), model: model, threshold: threshold, sequence: i)
        }
    }

    nonisolated static func parity(_ r: ReplayReport, predictions: [PredictionRecord]) -> LiveRunRecord.ParityReport {
        let names = ["bandpassed_uv", "features", "score"]
        let deviations = names.compactMap { q in r.maxDeviation[q].map { LiveRunRecord.Deviation(quantity: q, observed: $0.observedMax, allowed: $0.tolerance) } }
        let firstValid = r.firstValidWindowStop.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { ($0.value ?? nil) ?? -1 }
        var mismatches: [String] = []
        for pass in r.chunkings {
            let k = "chunks of \(pass.chunking)"
            mismatches += pass.report.validityMismatches.map { "\(k): validity differs at \(where_($0))" }
            mismatches += pass.report.decisionMismatches.map { "\(k): decision differs at \(where_($0))" }
            if !pass.report.missingWindows.isEmpty { mismatches.append("\(k): \(pass.report.missingWindows.count) offline windows never streamed") }
            if !pass.report.extraWindows.isEmpty { mismatches.append("\(k): \(pass.report.extraWindows.count) streamed windows not offline") }
        }
        let cueLocked = predictions.filter { $0.windowKind == "cue_locked" && $0.offline != nil }.count
        return .init(passed: r.passed, windowsCompared: r.windowsCompared, deviations: deviations, boundaryWindows: r.boundaryWindows.count,
                     firstValidWindowStop: firstValid, chunkings: r.chunkings.map { "\($0.chunking)" }, cueLockedCompared: cueLocked,
                     mismatches: Array(mismatches.prefix(LiveRunRecord.ParityReport.maxMismatches)),
                     storedChunking: r.chunkings.first.map { "\($0.chunking)" })
    }

    nonisolated static func summary(_ predictions: [PredictionRecord]) -> LiveRunRecord.Summary {
        .init(predictions: predictions.count, byValidity: Dictionary(grouping: predictions, by: \.validity.rawValue).mapValues(\.count),
              abstained: predictions.filter { $0.validity == .valid && $0.action.kind == .abstain }.count)
    }

    private nonisolated static func where_(_ w: ReplayReport.Where) -> String {
        "segment \(w.segment.map(String.init) ?? "?"), \(w.kind == "cue_locked" ? "trial \(w.trialId ?? "?")" : "window") ending at sample \(w.windowStop)"
    }

    // MARK: Worker

    private func finish(_ s: State) -> State {
        state = s
        return s
    }

    private static func isWorkerGone(_ code: String) -> Bool {
        ["worker_exited", "launch_failed", "ready_timeout", "protocol_mismatch", "bad_state", "write_failed", "timeout"].contains(code)
    }

    private func readyClient() async throws -> WorkerClient {
        if let client, await client.state == .ready { return client }
        discardClient()
        guard let launch else { throw WorkerError(code: "launch_failed", message: "no analysis worker is available (bundled worker missing and no development venv)") }
        let fresh = WorkerClient(launch: launch)
        client = fresh
        eventTask = Task { [weak self] in
            for await event in fresh.events { self?.handle(event) }
        }
        do {
            _ = try await fresh.start()
        } catch {
            discardClient(fresh)
            throw error
        }
        return fresh
    }

    private func discardClient(_ expected: WorkerClient? = nil) {
        if let expected, expected !== client { return }
        eventTask?.cancel()
        eventTask = nil
        if let old = client { Task { await old.forceTerminate() } }
        client = nil
    }

    private func handle(_ event: WorkerEvent) {
        guard event.name == "progress", event.requestID == currentRequestID, case .running = state,
              let p = try? JSONDecoder().decode([String: JSONScalar].self, from: event.data) else { return }
        switch p["stage"]?.description {
        case "loading": state = .running(.loading)
        case "replay": state = .running(.replaying)
        default: break
        }
    }
}
