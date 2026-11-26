import Foundation
import Observation

/// One long-running agent call (brief 008): an evaluation, an inspection, a replay, a
/// recording, a cued run or a live test. Jobs outlive the connection that started them.
@MainActor
final class ControlJob: Identifiable {
    enum State: String { case running, awaitingOperator = "awaiting_operator", done, failed, cancelled }

    let id: String
    let method: String
    let project: URL?
    let startedAt = Date()
    private(set) var state: State = .running
    private(set) var progress: JSON?
    /// What the person at the Mac is asked to do, while `awaitingOperator`.
    private(set) var prompt: String?
    private(set) var result: JSON?
    private(set) var error: ControlError?
    private(set) var endedAt: Date?
    /// Set by the handler: how this job is called off (runner cancel, run abort, …).
    var onCancel: (() -> Void)?
    var task: Task<Void, Never>?
    private var listeners: [UUID: (ControlMessage) -> Void] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(method: String, project: URL?) {
        id = "job-" + UUID().uuidString.prefix(8).lowercased()
        self.method = method
        self.project = project
    }

    var isFinished: Bool { [.done, .failed, .cancelled].contains(state) }

    func report(_ data: JSON) {
        progress = data
        emit("progress", data)
    }

    /// The job waits for the person; the prompt goes to listeners and `jobs.wait`.
    func awaitOperator(_ text: String) {
        guard state == .running || state == .awaitingOperator, prompt != text else { return }
        state = .awaitingOperator
        prompt = text
        emit("operator", ["job": .string(id), "prompt": .string(text)])
        wake()
    }

    func operatorDone() {
        guard state == .awaitingOperator else { return }
        state = .running
        prompt = nil
        emit("operator", ["job": .string(id), "prompt": .null])
    }

    func finish(_ outcome: Result<JSON, ControlError>) {
        guard !isFinished else { return }
        switch outcome {
        case .success(let r): result = r; state = .done
        case .failure(let e): error = e; state = e.code == ControlError.Code.cancelled.rawValue ? .cancelled : .failed
        }
        prompt = nil
        endedAt = Date()
        wake()
    }

    func cancel() {
        guard !isFinished else { return }
        onCancel?()
        task?.cancel()
    }

    func listen(_ f: @escaping (ControlMessage) -> Void) -> UUID {
        let key = UUID()
        listeners[key] = f
        return key
    }

    func unlisten(_ key: UUID) { listeners[key] = nil }

    private func emit(_ event: String, _ data: JSON) {
        for l in listeners.values { l(.event(event, id: id, data)) }
    }

    private func wake() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    /// Returns when the job ends or needs the operator, or after `timeout`.
    func wait(timeout: Duration) async {
        if isFinished || state == .awaitingOperator { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.wake()
        }
        await withCheckedContinuation { waiters.append($0) }
        timer.cancel()
    }

    /// Waits for the very end (a call without `async`).
    func waitUntilFinished() async {
        while !isFinished { await withCheckedContinuation { waiters.append($0) } }
    }

    var status: JSON {
        var o: [String: JSON] = [
            "job": .string(id), "method": .string(method), "state": .string(state.rawValue),
            "project": .from(project?.path), "startedAt": .from(startedAt),
        ]
        if let progress { o["progress"] = progress }
        if let prompt { o["prompt"] = .string(prompt) }
        if let endedAt { o["endedAt"] = .from(endedAt) }
        if let result { o["result"] = result }
        if let error { o["error"] = .object(["code": .string(error.code), "message": .string(error.message), "data": error.data ?? .null]) }
        return .object(o)
    }
}

/// What agents are doing right now, for the project windows (the "Agent" banner, operator
/// prompts) and for keeping the app awake while jobs run.
@MainActor
@Observable
final class AgentActivity {
    static let shared = AgentActivity()

    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let project: URL
        let message: String
        /// Confirm / Decline buttons (`operator.request`); otherwise text only, and the step
        /// is done in the app itself (Space in the participant window, Resume).
        let asks: Bool
        static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
    }

    private(set) var prompts: [Prompt] = []
    /// Projects with a job running, and what it is.
    private(set) var running: [URL: String] = [:]
    private(set) var connections = 0
    @ObservationIgnored private var answers: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?

    func connectionOpened() { connections += 1 }
    func connectionClosed() { connections = max(0, connections - 1) }

    func jobStarted(_ method: String, project: URL?) {
        if let project { running[project] = method }
        keepAwake()
    }

    func jobEnded(project: URL?, stillRunning: Int) {
        if let project { running[project] = nil }
        if stillRunning == 0, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    private func keepAwake() {
        guard activity == nil else { return }
        // App Nap would throttle a hidden app mid-run; idle sleep stays the system's call.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                        reason: "A coding agent is running a job in BCI Workspace")
    }

    func prompts(for project: URL) -> [Prompt] { prompts.filter { $0.project == project } }

    /// Shows a text prompt (the step happens elsewhere in the app); returns its id to clear.
    @discardableResult
    func show(_ message: String, project: URL) -> UUID {
        if let same = prompts.first(where: { $0.project == project && $0.message == message && !$0.asks }) { return same.id }
        let p = Prompt(project: project, message: message, asks: false)
        prompts.append(p)
        return p.id
    }

    func clear(_ id: UUID?) {
        guard let id else { return }
        prompts.removeAll { $0.id == id }
        answers.removeValue(forKey: id)?.resume(returning: false)
    }

    /// Shows Confirm / Decline and waits for the person's answer.
    func ask(_ message: String, project: URL) async -> Bool {
        let p = Prompt(project: project, message: message, asks: true)
        prompts.append(p)
        return await withCheckedContinuation { answers[p.id] = $0 }
    }

    func answer(_ id: UUID, _ yes: Bool) {
        prompts.removeAll { $0.id == id }
        answers.removeValue(forKey: id)?.resume(returning: yes)
    }
}
