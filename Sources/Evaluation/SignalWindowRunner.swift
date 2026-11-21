import Foundation
import Observation

/// Where `SignalWindowRunner` gets windows: the inspection worker (tests use a fake).
@MainActor
public protocol SignalWindowSource: AnyObject {
    var projectDirectory: URL { get }
    func signalWindow(params: [String: JSONValue], requestID: String) async throws -> SignalWindow
    func cancelSignalWindow(requestID: String)
}

extension InspectionRunner: SignalWindowSource {}

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

    private let inspector: any SignalWindowSource
    private var cache: [Request: SignalWindow] = [:]
    private var cacheOrder: [Request] = []
    private var task: Task<Void, Never>?
    private var currentRequestID: String?
    /// The request the running task is fetching, and whether its cancel was already sent.
    private var inFlight: Request?
    private var inFlightCancelled = false
    /// The latest request asked for: the one that must end up on screen.
    private var wanted: Request?

    public init(inspector: any SignalWindowSource) { self.inspector = inspector }

    public var isBusy: Bool { task != nil }

    /// Shows `request`'s window: from the cache at once, else after the running fetch (if
    /// any) ends. A fetch for anything other than the latest request is cancelled. Asking
    /// again for a request whose fetch was already cancelled (A, then B, then back to A)
    /// starts it afresh once the cancelled one returns, so the latest request always loads.
    public func load(_ request: Request) {
        wanted = request
        if let cached = cache[request] {
            cancelInFlight()
            window = cached
            state = .ready(request)
            return
        }
        state = .loading(request)
        if let inFlight {
            if inFlight != request { cancelInFlight() }
            return
        }
        start(request)
    }

    public func loadAndWait(_ request: Request) async -> State {
        load(request)
        while let t = task { await t.value }
        return state
    }

    private func start(_ request: Request) {
        inFlight = request
        inFlightCancelled = false
        task = Task { [weak self] in
            await self?.fetch(request)
            guard let self else { return }
            self.task = nil
            self.inFlight = nil
            self.inFlightCancelled = false
            // Still waiting: a newer request, or this one after its fetch was cancelled.
            if let next = self.wanted, self.state == .loading(next) { self.start(next) }
        }
    }

    private func cancelInFlight() {
        guard inFlight != nil, !inFlightCancelled else { return }
        inFlightCancelled = true
        if let id = currentRequestID { inspector.cancelSignalWindow(requestID: id) }
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
            // A newer request is waiting or already shows its cached window: leave it.
            guard state == .loading(request) else { return }
            window = w
            state = .ready(request)
        } catch let error as WorkerError {
            guard state == .loading(request) else { return }
            // Our own cancel: the completion handler restarts the request if still wanted.
            if error.code == "cancelled", inFlightCancelled { return }
            // A cancel we never sent (the worker shutting down) is the worker going away, not
            // "nothing to show": idle would leave the old trace up with no spinner or Retry.
            let gone = ["cancelled", "worker_exited", "launch_failed", "ready_timeout", "protocol_mismatch", "bad_state", "write_failed", "timeout"].contains(error.code)
            state = gone ? .unavailable(request, reason: error.message) : .failed(request, reason: error.description)
        } catch {
            guard state == .loading(request) else { return }
            state = .failed(request, reason: "unreadable signal_window response: \(error)")
        }
    }

    private func store(_ w: SignalWindow, for request: Request) {
        if cache.updateValue(w, forKey: request) == nil { cacheOrder.append(request) }
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }
}
