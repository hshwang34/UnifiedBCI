import Foundation

/// Mirrors worker/src/bciworkspace_worker/protocol.py. Bump both together.
public enum WorkerProtocol {
    public static let version = 1
}

public struct WorkerError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "worker error \(code): \(message)" }
}

/// What the worker announces on startup (the `ready` event / `hello` method).
public struct WorkerHello: Codable, Sendable, Equatable {
    public let `protocol`: Int
    public let pid: Int
    public let versions: [String: String]
    public let methods: [String]
}

public struct WorkerEvent: Sendable {
    public let name: String
    public let requestID: String?
    /// Raw JSON of the event's `data` field.
    public let data: Data
}

/// Owns one worker process and multiplexes JSON-line requests over its stdio.
/// Lifetime: `start()` → any number of `call()` → `shutdown()`. If the process dies,
/// every pending call fails with `worker_exited` and the client must be recreated;
/// the app treats that as a visible "analysis unavailable" state, never a silent retry.
public actor WorkerClient {
    public enum State: Sendable, Equatable { case idle, starting, ready, exited(Int32) }

    public private(set) var state: State = .idle
    public private(set) var hello: WorkerHello?
    public let events: AsyncStream<WorkerEvent>
    private let eventContinuation: AsyncStream<WorkerEvent>.Continuation

    private let launch: WorkerLaunch
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var readyWaiters: [CheckedContinuation<WorkerHello, Error>] = []
    private var nextID = 0
    private var stderrTail: [String] = []

    public init(launch: WorkerLaunch) {
        self.launch = launch
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: Lifecycle

    @discardableResult
    public func start(readyTimeout: Duration = .seconds(30)) async throws -> WorkerHello {
        guard state == .idle else { throw WorkerError(code: "bad_state", message: "worker already started") }
        state = .starting

        let proc = Process()
        proc.executableURL = launch.python
        proc.arguments = ["-m", "bciworkspace_worker"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if let path = launch.pythonPath { env["PYTHONPATH"] = path }
        proc.environment = env
        proc.currentDirectoryURL = launch.workingDirectory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.logStderr(String(decoding: data, as: UTF8.self)) }
        }
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            guard let self else { return }
            Task { await self.didExit(status) }
        }

        do {
            try proc.run()
        } catch {
            state = .exited(-1)
            throw WorkerError(code: "launch_failed", message: "\(error.localizedDescription) (\(launch.python.path))")
        }
        process = proc
        stdinHandle = stdin.fileHandleForWriting

        return try await withThrowingTaskGroup(of: WorkerHello.self) { group in
            group.addTask { try await self.waitForReady() }
            group.addTask {
                try await Task.sleep(for: readyTimeout)
                throw WorkerError(code: "ready_timeout", message: "worker did not announce ready within \(readyTimeout)")
            }
            let hello = try await group.next()!
            group.cancelAll()
            return hello
        }
    }

    public func shutdown() async {
        guard let proc = process, proc.isRunning else { return }
        _ = try? await call("shutdown")
        try? await Task.sleep(for: .milliseconds(200))
        if proc.isRunning { proc.terminate() }
    }

    // MARK: Requests

    /// Sends `method` and returns the raw JSON bytes of `result`, for the caller to decode.
    public func call(_ method: String, params: [String: any Sendable] = [:]) async throws -> Data {
        guard state == .ready || method == "shutdown", let stdinHandle else {
            throw WorkerError(code: "bad_state", message: "worker is \(state)")
        }
        nextID += 1
        let id = "\(nextID)"
        let envelope: [String: Any] = ["v": WorkerProtocol.version, "id": id, "method": method, "params": params]
        var line = try JSONSerialization.data(withJSONObject: envelope)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pending[id] = nil
                cont.resume(throwing: WorkerError(code: "write_failed", message: error.localizedDescription))
            }
        }
    }

    public func call<T: Decodable>(_ method: String, params: [String: any Sendable] = [:], as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call(method, params: params))
    }

    // MARK: Internals

    private func waitForReady() async throws -> WorkerHello {
        if let hello { return hello }
        if case .exited(let code) = state {
            throw WorkerError(code: "worker_exited", message: "exited with status \(code) before ready\n\(stderrTail.suffix(10).joined())")
        }
        return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            dispatch(line)
        }
    }

    private func dispatch(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            logStderr("[client] unparseable line from worker: \(String(decoding: line.prefix(200), as: UTF8.self))\n")
            return
        }
        guard (obj["v"] as? Int) == WorkerProtocol.version else {
            logStderr("[client] protocol version mismatch: \(String(describing: obj["v"]))\n")
            return
        }
        if let name = obj["event"] as? String {
            let data = (try? JSONSerialization.data(withJSONObject: obj["data"] ?? NSNull())) ?? Data()
            if name == "ready", let hello = try? JSONDecoder().decode(WorkerHello.self, from: data) {
                self.hello = hello
                state = .ready
                readyWaiters.forEach { $0.resume(returning: hello) }
                readyWaiters.removeAll()
            }
            eventContinuation.yield(WorkerEvent(name: name, requestID: obj["id"] as? String, data: data))
            return
        }
        guard let id = obj["id"] as? String, let cont = pending.removeValue(forKey: id) else { return }
        if (obj["ok"] as? Bool) == true {
            let result = (try? JSONSerialization.data(withJSONObject: obj["result"] ?? NSNull())) ?? Data()
            cont.resume(returning: result)
        } else {
            let err = obj["error"] as? [String: Any]
            cont.resume(throwing: WorkerError(
                code: err?["code"] as? String ?? "unknown",
                message: err?["message"] as? String ?? "no message"))
        }
    }

    private func logStderr(_ text: String) {
        stderrTail.append(text)
        if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        FileHandle.standardError.write(Data(("[worker] " + text).utf8))
    }

    private func didExit(_ status: Int32) {
        state = .exited(status)
        let err = WorkerError(code: "worker_exited", message: "worker exited with status \(status)\n\(stderrTail.suffix(10).joined())")
        pending.values.forEach { $0.resume(throwing: err) }
        pending.removeAll()
        readyWaiters.forEach { $0.resume(throwing: err) }
        readyWaiters.removeAll()
        eventContinuation.finish()
        process?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process?.standardError.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
    }
}
