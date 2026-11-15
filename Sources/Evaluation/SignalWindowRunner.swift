import Foundation
import Observation

/// Fetches trace windows for the Quality tab (brief 002) on the inspection worker. One
/// request at a time; while one runs, a newer request cancels it and waits its turn, so
/// moving the window quickly never builds a backlog (latest wins). The last window stays
/// on screen while the next one loads. Windows are cached in memory for the session.
@MainActor
@Observable
public final class SignalWindowRunner {
    public struct Request: Hashable, Sendable {
        public var recordingID: UUID
        public var segment: Int
        public var startS: Double
        public init(recordingID: UUID, segment: Int, startS: Double) {
            self.recordingID = recordingID
            self.segment = segment
            self.startS = startS
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case loading(Request)
        case ready(Request)
        case unavailable(Request, reason: String)
        case failed(Request, reason: String)
    }

    public nonisolated static let durationS = 10.0
    /// Points per channel; above any lane's width in points, well under the worker's 2,000.
    public nonisolated static let maxPoints = 1000
    static let cacheLimit = 24

    public private(set) var state: State = .idle
    /// The latest window received, shown until the next one arrives.
    public private(set) var window: SignalWindow?

    private let inspector: InspectionRunner
    private var cache: [Request: SignalWindow] = [:]
    private var cacheOrder: [Request] = []
    private var task: Task<Void, Never>?
    private var currentRequestID: String?
    private var queued: Request?

    public init(inspector: InspectionRunner) { self.inspector = inspector }

    public var isBusy: Bool { task != nil }

    public func load(_ request: Request) {
        if let cached = cache[request] {
            queued = nil
            if let id = currentRequestID { inspector.cancelSignalWindow(requestID: id) }
            window = cached
            state = .ready(request)
            return
        }
        if task != nil {
            if case .loading(let r) = state, r == request { queued = nil; return }
            queued = request
            if let id = currentRequestID { inspector.cancelSignalWindow(requestID: id) }
            return
        }
        state = .loading(request)
        task = Task { [weak self] in
            await self?.fetch(request)
            guard let self else { return }
            self.task = nil
            if let next = self.queued {
                self.queued = nil
                self.load(next)
            }
        }
    }

    public func loadAndWait(_ request: Request) async -> State {
        load(request)
        while let t = task { await t.value }
        return state
    }

    private func fetch(_ request: Request) async {
        let id = "window-\(UUID().uuidString)"
        currentRequestID = id
        defer { currentRequestID = nil }
        let params = SignalWindow.params(projectDirectory: inspector.projectDirectory, recordingID: request.recordingID,
                                         segment: request.segment, startS: request.startS, durationS: Self.durationS,
                                         maxPoints: Self.maxPoints)
        do {
            let w = try await inspector.signalWindow(params: params, requestID: id)
            store(w, for: request)
            // A newer request already shows its cached window: keep that on screen.
            guard queued == nil, state == .loading(request) else { return }
            window = w
            state = .ready(request)
        } catch let error as WorkerError {
            guard queued == nil, state == .loading(request) else { return }
            if error.code == "cancelled" { state = .idle; return }
            let gone = ["worker_exited", "launch_failed", "ready_timeout", "protocol_mismatch", "bad_state", "write_failed", "timeout"].contains(error.code)
            state = gone ? .unavailable(request, reason: error.message) : .failed(request, reason: error.description)
        } catch {
            guard queued == nil, state == .loading(request) else { return }
            state = .failed(request, reason: "unreadable signal_window response: \(error)")
        }
    }

    private func store(_ w: SignalWindow, for request: Request) {
        if cache.updateValue(w, forKey: request) == nil { cacheOrder.append(request) }
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }
}
