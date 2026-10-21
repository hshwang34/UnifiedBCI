import Foundation
import Observation

/// Drives one evaluation at a time: starts (or restarts) the worker, calls
/// `fit_evaluate_project`, forwards its progress as typed values, and commits the result
/// through `ProjectStore` with the reproduction bookkeeping the brief asks for.
///
/// `@MainActor @Observable` rather than an actor: the only reason it exists is to be bound
/// to a view (PR 3), and its state must change on the main actor to be observed without
/// hops. All the work happens inside `WorkerClient` and `ProjectStore`, which are actors;
/// this class only sequences them, so nothing heavy runs on the main actor.
@MainActor
@Observable
public final class EvaluationRunner {
    public enum Progress: Sendable, Equatable {
        case starting
        case loading
        case fitting(model: String, fold: Int, of: Int, step: Int, steps: Int)
        case holdout(model: String, step: Int, steps: Int)
        case storing

        /// Determinate position in [0, 1], non-decreasing through a run.
        public var fraction: Double {
            switch self {
            case .starting: return 0.0
            case .loading: return 0.05
            case .fitting(_, let fold, let of, let step, let steps):
                let perModel = 0.8 / Double(max(steps, 1))
                return 0.1 + perModel * (Double(step - 1) + 0.9 * Double(fold) / Double(max(of, 1)))
            case .holdout(_, let step, let steps):
                return 0.1 + 0.8 * Double(step) / Double(max(steps, 1))
            case .storing: return 0.95
            }
        }

        public var label: String {
            switch self {
            case .starting: return "starting worker"
            case .loading: return "loading"
            case .fitting(let model, let fold, let of, _, _): return "fit:\(model):fold \(fold)/\(of)"
            case .holdout(let model, _, _): return "holdout:\(model)"
            case .storing: return "storing"
            }
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case running(Progress)
        case done(resultID: UUID)
        /// The worker could not be started, died, or stopped answering. The recording
        /// stays usable; `retry()` starts a fresh worker and runs the same request again.
        case analysisUnavailable(reason: String)
        /// The worker ran and refused: integrity error, bad parameters, or an internal
        /// error. Retrying without changing something will fail the same way.
        case failed(reason: String)
    }

    /// What to evaluate. `window` and `labels` default to the bundled example's imagery
    /// window; the worker records them in the pipeline configuration and its hash.
    public struct Request: Sendable, Equatable {
        public var recordingID: UUID
        public var seed: Int
        public var windowOffsetSeconds: Double = 0.5
        public var windowLengthSeconds: Double = 3.5
        public var cspComponents: Int = 4
        public var leftLabel: String = "cue_left_fist"
        public var rightLabel: String = "cue_right_fist"

        public init(recordingID: UUID, seed: Int) {
            self.recordingID = recordingID
            self.seed = seed
        }
    }

    public private(set) var state: State = .idle
    /// Every progress value of the current (or last) run, in order; for tests and a log view.
    public private(set) var progressLog: [Progress] = []
    public let store: ProjectStore

    private let launch: WorkerLaunch?
    private var client: WorkerClient?
    private var eventTask: Task<Void, Never>?
    private var lastRequest: Request?
    private var runTask: Task<Void, Never>?
    private var currentRequestID: String?
    private var workerTimings: [String: Double] = [:]
    private var sawDone = false

    public init(store: ProjectStore, launch: WorkerLaunch?) {
        self.store = store
        self.launch = launch
    }

    // MARK: Driving

    /// Starts an evaluation; `state` reports progress. A run already in flight is left alone.
    public func evaluate(_ request: Request) {
        guard runTask == nil else { return }
        lastRequest = request
        runTask = Task { [weak self] in
            await self?.run(request)
            self?.runTask = nil
        }
    }

    /// Runs the request and returns the terminal state. For tests and scripted callers.
    @discardableResult
    public func evaluateAndWait(_ request: Request) async -> State {
        evaluate(request)
        await runTask?.value
        return state
    }

    /// Re-runs the last request with a fresh worker if the previous one is gone.
    public func retry() {
        guard let lastRequest else { return }
        evaluate(lastRequest)
    }

    @discardableResult
    public func retryAndWait() async -> State {
        retry()
        await runTask?.value
        return state
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        if let client { await client.shutdown() }
        client = nil
    }

    // MARK: Internals

    private func run(_ request: Request) async {
        progressLog = []
        workerTimings = [:]
        sawDone = false
        set(.starting)
        let t0 = Date()
        let client: WorkerClient
        do {
            client = try await readyClient()
        } catch {
            discardClient()
            state = .analysisUnavailable(reason: "\(error)")
            return
        }
        let hello = await client.hello
        let origin = launch?.origin == .bundled ? "bundled" : "development_venv"

        let requestID = "evaluate-\(UUID().uuidString)"
        currentRequestID = requestID
        let staging: URL
        do {
            staging = try await store.stagingDirectory()
        } catch {
            state = .failed(reason: "\(error)")
            return
        }
        let arraysPath = staging.appendingPathComponent(ProjectStore.fittedFileName)
        let params: [String: JSONValue] = [
            "project_dir": .string(store.directory.path),
            "recording_id": .string(request.recordingID.uuidString),
            "window": .object(["offset_s": .double(request.windowOffsetSeconds), "length_s": .double(request.windowLengthSeconds)]),
            "labels": .object(["left": .string(request.leftLabel), "right": .string(request.rightLabel)]),
            "seed": .int(request.seed),
            "csp_components": .int(request.cspComponents),
            "fitted_arrays_path": .string(arraysPath.path),
        ]

        let responseData: Data
        do {
            responseData = try await client.call("fit_evaluate_project", params: params, requestID: requestID)
        } catch let error as WorkerError {
            try? FileManager.default.removeItem(at: staging)
            if Self.isWorkerGone(error.code) {
                discardClient()
                state = .analysisUnavailable(reason: error.message)
            } else {
                state = .failed(reason: error.description)
            }
            return
        } catch {
            try? FileManager.default.removeItem(at: staging)
            state = .failed(reason: "\(error)")
            return
        }
        await awaitDoneEvent()
        set(.storing)

        do {
            guard let evaluationJSON = JSONLineScanner.topLevelValue(for: "evaluation", in: responseData),
                  let pipelineJSON = JSONLineScanner.topLevelValue(for: "pipeline", in: responseData) else {
                throw WorkerError(code: "protocol_mismatch", message: "fit_evaluate_project response lacks evaluation/pipeline")
            }
            let draft = try JSONDecoder().decode(PipelineDraft.self, from: pipelineJSON)
            let pipeline = PipelineRecord(
                pipelineID: UUID(), recipe: draft.recipe, configuration: draft.configuration, expectedChannelIDs: draft.expectedChannelIDs,
                expectedSampleRateHz: draft.expectedSampleRateHz, preprocessingStatePolicy: draft.preprocessingStatePolicy,
                trainingRecordingIDs: [request.recordingID], splitManifest: draft.splitManifest, dependencyVersions: draft.dependencyVersions,
                seed: draft.seed, fittedParametersFile: nil, configHash: draft.configHash)
            let digest = AtomicFile.sha256Hex(evaluationJSON)

            // Reproduction: an earlier result for the same recording, configuration and
            // seed is the original. We ran anyway (that is the evidence), and the link is
            // only claimed when the bytes agree; otherwise the divergence is recorded.
            let earlier = try await store.results()
                .filter { $0.recordingID == request.recordingID && $0.configHash == draft.configHash && $0.seed == request.seed }
            let original = earlier.first { $0.reproductionOf == nil } ?? earlier.first
            var durations = workerTimings
            durations["total"] = Date().timeIntervalSince(t0)
            let meta = ResultMeta(
                resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: request.recordingID, createdAt: Date(), seed: request.seed,
                configHash: draft.configHash, evaluationSHA256: digest, durationsSeconds: durations,
                workerVersions: hello?.versions ?? [:], workerOrigin: origin,
                reproductionOf: original.flatMap { $0.evaluationSHA256 == digest ? $0.resultID : nil },
                divergedFrom: original.flatMap { $0.evaluationSHA256 == digest ? nil : $0.resultID })
            let id = try await store.storeResult(evaluationJSON: evaluationJSON, meta: meta, pipeline: pipeline, fittedArraysFile: arraysPath)
            state = .done(resultID: id)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            state = .failed(reason: "\(error)")
        }
    }

    private func set(_ progress: Progress) {
        progressLog.append(progress)
        state = .running(progress)
    }

    private static func isWorkerGone(_ code: String) -> Bool {
        ["worker_exited", "launch_failed", "ready_timeout", "protocol_mismatch", "bad_state", "write_failed", "timeout"].contains(code)
    }

    private func readyClient() async throws -> WorkerClient {
        if let client, await client.state == .ready { return client }
        discardClient()
        guard let launch else { throw WorkerError(code: "launch_failed", message: "no analysis worker is available (bundled worker missing and no development venv)") }
        let client = WorkerClient(launch: launch)
        self.client = client
        eventTask = Task { [weak self] in
            // Inherits the main actor, so `handle` runs where `state` lives.
            for await event in client.events {
                self?.handle(event)
            }
        }
        _ = try await client.start()
        return client
    }

    private func discardClient() {
        eventTask?.cancel()
        eventTask = nil
        if let old = client { Task { await old.shutdown() } }
        client = nil
    }

    private func handle(_ event: WorkerEvent) {
        guard event.requestID == currentRequestID else { return }
        switch event.name {
        case "progress":
            guard let p = try? JSONDecoder().decode(ProgressEvent.self, from: event.data) else { return }
            switch p.stage {
            case "loading": set(.loading)
            case "fit":
                if let model = p.model, let fold = p.fold, let of = p.of, let step = p.step, let steps = p.steps {
                    set(.fitting(model: model, fold: fold, of: of, step: step, steps: steps))
                }
            case "holdout":
                if let model = p.model, let step = p.step, let steps = p.steps { set(.holdout(model: model, step: step, steps: steps)) }
            default: break
            }
        case "done":
            if let d = try? JSONDecoder().decode(DoneEvent.self, from: event.data) {
                workerTimings = d.stages ?? [:]
                workerTimings["worker_elapsed"] = d.elapsed_seconds
            }
            sawDone = true
        default: break
        }
    }

    /// The worker writes `done` before its response, so it is already queued when the
    /// call returns; the event task just needs to be scheduled. Bounded wait.
    private func awaitDoneEvent() async {
        for _ in 0..<200 where !sawDone {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct ProgressEvent: Decodable {
        let stage: String
        let model: String?
        let fold: Int?
        let of: Int?
        let step: Int?
        let steps: Int?
    }

    private struct DoneEvent: Decodable {
        let elapsed_seconds: Double
        let stages: [String: Double]?
    }

    /// The `pipeline` block of a `fit_evaluate_project` response: every PipelineRecord
    /// field the worker determines. The app adds ids and the training recording.
    private struct PipelineDraft: Decodable {
        let recipe: String
        let configuration: [String: String]
        let expectedChannelIDs: [String]
        let expectedSampleRateHz: Double
        let preprocessingStatePolicy: String
        let splitManifest: String
        let dependencyVersions: [String: String]
        let seed: Int
        let configHash: String
    }
}
