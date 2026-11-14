import Foundation
import Observation

/// Runs `inspect_recording` for the Quality tab (brief 002): one inspection at a time,
/// per-segment progress, cancel, and the same three failure kinds as `EvaluationRunner`.
/// Reports are cached in memory per recording for the life of the runner (one project
/// session); nothing is written to the project, because inspection is not evidence yet.
///
/// It owns its own worker, started on first use, so inspecting never queues behind a
/// running evaluation (the worker runs one request at a time) and never shares that
/// runner's single event stream. Instead of a progress-silence watchdog it gives each call
/// an overall timeout: a whole inspection is seconds on the bundled example.
@MainActor
@Observable
public final class InspectionRunner {
    public enum Progress: Sendable, Equatable {
        case starting
        case loading
        case segment(Int, of: Int)

        /// Determinate position in [0, 1], non-decreasing through a run.
        public var fraction: Double {
            switch self {
            case .starting: return 0.0
            case .loading: return 0.05
            case .segment(let k, let of): return 0.1 + 0.9 * Double(k - 1) / Double(max(of, 1))
            }
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case running(recordingID: UUID, Progress)
        /// `report(for:)` returns the result.
        case done(recordingID: UUID)
        /// The worker could not be started, died, or timed out; `retry()` uses a fresh one.
        case analysisUnavailable(reason: String)
        /// The worker ran and refused (integrity error, unknown recording, internal error).
        case failed(reason: String)
        /// The user cancelled; nothing was cached.
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var progressLog: [Progress] = []
    public let projectDirectory: URL
    public let callTimeout: Duration

    private let launch: WorkerLaunch?
    private var cache: [UUID: InspectionReport] = [:]
    private var client: WorkerClient?
    private var eventTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var currentRequestID: String?
    private var lastRecordingID: UUID?
    private var cancelRequested = false
    private var isShutDown = false

    public init(projectDirectory: URL, launch: WorkerLaunch?, callTimeout: Duration = .seconds(120)) {
        self.projectDirectory = projectDirectory
        self.launch = launch
        self.callTimeout = callTimeout
    }

    /// The cached report for a recording, if one was inspected in this session.
    public func report(for recordingID: UUID) -> InspectionReport? { cache[recordingID] }

    public var isBusy: Bool { runTask != nil }

    /// Inspects a recording, or reports the cached result at once. A run in flight is left alone.
    public func inspect(recordingID: UUID) {
        guard runTask == nil else { return }
        lastRecordingID = recordingID
        if cache[recordingID] != nil {
            state = .done(recordingID: recordingID)
            return
        }
        progressLog = []
        cancelRequested = false
        runTask = Task { [weak self] in
            await self?.run(recordingID)
            self?.runTask = nil
        }
    }

    @discardableResult
    public func inspectAndWait(recordingID: UUID) async -> State {
        inspect(recordingID: recordingID)
        await runTask?.value
        return state
    }

    public func retry() {
        guard let lastRecordingID else { return }
        inspect(recordingID: lastRecordingID)
    }

    /// Asks the worker to stop; the run ends as `.cancelled` even if it had finished.
    public func cancel() {
        guard runTask != nil, !cancelRequested else { return }
        cancelRequested = true
        guard let client, let id = currentRequestID else { return }   // not sent yet: `run` checks the flag
        Task { _ = try? await client.cancel(requestID: id) }
    }

    @discardableResult
    public func cancelAndWait() async -> State {
        cancel()
        await runTask?.value
        return state
    }

    /// Stops the worker for good (window closing). Nothing starts a worker afterwards.
    public func shutdown() async {
        isShutDown = true
        cancel()
        let old = client
        discardClient()
        if let old { await old.shutdown() }
    }

    // MARK: Internals

    private func run(_ recordingID: UUID) async {
        set(.starting, recordingID)
        let client: WorkerClient
        do {
            client = try await readyClient()
        } catch {
            finish(cancelRequested ? .cancelled : .analysisUnavailable(reason: "\(error)"))
            return
        }
        guard !cancelRequested else { return finish(.cancelled) }
        let requestID = "inspect-\(UUID().uuidString)"
        currentRequestID = requestID
        let params: [String: JSONValue] = [
            "project_dir": .string(projectDirectory.path),
            "recording_id": .string(recordingID.uuidString),
        ]
        do {
            let data = try await client.call("inspect_recording", params: params, timeout: callTimeout, requestID: requestID)
            guard !cancelRequested else { return finish(.cancelled) }
            cache[recordingID] = try InspectionReport.decode(data)
            finish(.done(recordingID: recordingID))
        } catch let error as WorkerError {
            if Self.isWorkerGone(error.code) { discardClient(client) }
            if cancelRequested || error.code == "cancelled" {
                finish(.cancelled)
            } else if Self.isWorkerGone(error.code) {
                finish(.analysisUnavailable(reason: error.message))
            } else {
                finish(.failed(reason: error.description))
            }
        } catch {
            finish(cancelRequested ? .cancelled : .failed(reason: "unreadable inspect_recording response: \(error)"))
        }
    }

    private func set(_ progress: Progress, _ recordingID: UUID) {
        progressLog.append(progress)
        state = .running(recordingID: recordingID, progress)
    }

    private func finish(_ terminal: State) {
        currentRequestID = nil
        state = terminal
    }

    private static func isWorkerGone(_ code: String) -> Bool {
        ["worker_exited", "launch_failed", "ready_timeout", "protocol_mismatch", "bad_state", "write_failed", "timeout"].contains(code)
    }

    /// The running worker, or a fresh one. Only `run` calls this, and runs never overlap.
    private func readyClient() async throws -> WorkerClient {
        guard !isShutDown else { throw WorkerError(code: "launch_failed", message: "the analysis worker was shut down with its project window") }
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
        guard !isShutDown, client === fresh else {
            await fresh.shutdown()
            throw WorkerError(code: "launch_failed", message: "the analysis worker was shut down with its project window")
        }
        return fresh
    }

    private func discardClient(_ expected: WorkerClient? = nil) {
        if let expected, expected !== client { return }
        eventTask?.cancel()
        eventTask = nil
        if let old = client { Task { await old.shutdown() } }
        client = nil
    }

    /// Internal so tests can deliver a late event directly.
    func handle(_ event: WorkerEvent) {
        guard event.name == "progress", let current = currentRequestID, event.requestID == current,
              case .running(let recordingID, _) = state,
              let p = try? JSONDecoder().decode(ProgressEvent.self, from: event.data) else { return }
        switch p.stage {
        case "loading": set(.loading, recordingID)
        case "inspect": if let k = p.segment, let of = p.of { set(.segment(k, of: of), recordingID) }
        default: break
        }
    }

    private struct ProgressEvent: Decodable {
        let stage: String
        let segment: Int?
        let of: Int?
    }
}
