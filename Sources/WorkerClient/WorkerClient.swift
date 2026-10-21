import Foundation

/// Mirrors worker/src/bciworkspace_worker/protocol.py. Bump both together.
public enum WorkerProtocol {
    public static let version = 1
}

public struct WorkerError: Error, CustomStringConvertible, Sendable, Equatable {
    public let code: String
    public let message: String
    public var description: String { "worker error \(code): \(message)" }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
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
    /// Raw JSON of the event's `data` field, byte-for-byte as the worker sent it.
    public let data: Data
}

/// A JSON value for request parameters. `Encodable` rather than `JSONSerialization`
/// so a NaN or an unsupported type is a thrown Swift error, never an NSException.
public enum JSONValue: Sendable, Equatable, Encodable,
                       ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
                       ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(nilLiteral: ()) { self = .null }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Owns one worker process and multiplexes JSON-line requests over its stdio.
/// Lifetime: `start()` → any number of `call()` → `shutdown()`. If the process dies,
/// every pending call fails with `worker_exited` and the client must be recreated;
/// the app treats that as a visible "analysis unavailable" state, never a silent retry.
///
/// Output is consumed in order by a single actor-owned task fed from the pipe's
/// readability handler, so a large response arriving in many reads is reassembled
/// exactly as sent. `didExit` runs only once both pipes reached EOF *and* the process
/// terminated, so a final response is never discarded.
public actor WorkerClient {
    public enum State: Sendable, Equatable { case idle, starting, ready, exited(Int32) }

    public private(set) var state: State = .idle
    public private(set) var hello: WorkerHello?
    public nonisolated let events: AsyncStream<WorkerEvent>
    private let eventContinuation: AsyncStream<WorkerEvent>.Continuation

    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let launch: WorkerLaunch
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var pending: [String: Pending] = [:]
    private var readyWaiters: [CheckedContinuation<WorkerHello, Error>] = []
    private var nextID = 0
    private var stderrTail: [String] = []
    private var stdoutEOF = false
    private var stderrEOF = false
    private var terminationStatus: Int32?
    private var exitHandled = false
    private var consumerTasks: [Task<Void, Never>] = []
    private var readyTimeoutTask: Task<Void, Never>?

    /// A worker that dies mid-write would otherwise kill the app with SIGPIPE.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(launch: WorkerLaunch) {
        _ = Self.ignoreSigpipe
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
        proc.arguments = launch.arguments
        proc.environment = launch.environment()
        proc.currentDirectoryURL = launch.workingDirectory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let stdoutStream = Self.reads(from: stdout.fileHandleForReading)
        let stderrStream = Self.reads(from: stderr.fileHandleForReading)
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { await self?.noteTermination(status) }
        }

        do {
            try proc.run()
        } catch {
            state = .exited(-1)
            throw WorkerError(code: "launch_failed", message: "\(error.localizedDescription) (\(launch.python.path))")
        }
        process = proc
        stdinHandle = stdin.fileHandleForWriting

        consumerTasks = [
            Task { [weak self] in
                for await chunk in stdoutStream { await self?.consume(chunk) }
                await self?.noteEOF(stdout: true)
            },
            Task { [weak self] in
                for await chunk in stderrStream { await self?.logStderr(String(decoding: chunk, as: UTF8.self)) }
                await self?.noteEOF(stdout: false)
            },
        ]
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: readyTimeout)
            guard !Task.isCancelled else { return }
            await self?.readyTimedOut(after: readyTimeout)
        }
        defer { readyTimeoutTask?.cancel(); readyTimeoutTask = nil }
        return try await waitForReady()
    }

    /// Asks the worker to exit, then terminates it if it has not within a short grace.
    public func shutdown() async {
        guard let proc = process, proc.isRunning else { return }
        _ = try? await call("shutdown", timeout: .seconds(2))
        for _ in 0..<40 where proc.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if proc.isRunning { proc.terminate() }
    }

    // MARK: Requests

    /// Sends `method` and returns the raw JSON bytes of `result`, for the caller to decode.
    /// `timeout` fails the call with `timeout` and asks the worker to cancel it; cancelling
    /// the calling Task sends the worker a `cancel` and the call then fails with `cancelled`.
    /// `requestID` lets a caller choose the id so it can `cancel(requestID:)` later.
    public func call(_ method: String, params: [String: JSONValue] = [:], timeout: Duration? = nil, requestID: String? = nil) async throws -> Data {
        guard state == .ready || method == "shutdown", let stdinHandle else {
            throw WorkerError(code: "bad_state", message: "worker is \(state)")
        }
        nextID += 1
        let id = requestID ?? "\(nextID)"
        guard pending[id] == nil else { throw WorkerError(code: "bad_request", message: "request id \(id) is already in flight") }
        var line = try Self.lineEncoder.encode(RequestEnvelope(v: WorkerProtocol.version, id: id, method: method, params: params))
        line.append(0x0A)
        let bytes = line
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                pending[id] = Pending(continuation: cont, timeoutTask: nil)
                do {
                    try stdinHandle.write(contentsOf: bytes)
                } catch {
                    pending[id] = nil
                    cont.resume(throwing: WorkerError(code: "write_failed", message: error.localizedDescription))
                    return
                }
                if let timeout {
                    pending[id]?.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        await self?.timedOut(id, after: timeout)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelIfPending(id) }
        }
    }

    public func call<T: Decodable>(_ method: String, params: [String: JSONValue] = [:], timeout: Duration? = nil, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call(method, params: params, timeout: timeout))
    }

    /// Sends the worker's `cancel` for an in-flight request. Returns what the worker
    /// said: true if it found the request queued or running. The original call then
    /// fails with `cancelled` once the worker reaches a checkpoint.
    @discardableResult
    public func cancel(requestID: String) async throws -> Bool {
        struct Reply: Decodable { let cancelled: Bool }
        return try await call("cancel", params: ["id": .string(requestID)], timeout: .seconds(5), as: Reply.self).cancelled
    }

    // MARK: Internals

    private struct RequestEnvelope: Encodable {
        let v: Int
        let id: String
        let method: String
        let params: [String: JSONValue]
    }

    private struct Envelope: Decodable {
        struct ErrorBody: Decodable { let code: String; let message: String }
        let v: Int
        let id: String?
        let event: String?
        let ok: Bool?
        let error: ErrorBody?
    }

    /// Serial, in-order delivery of everything the pipe produces. The readability
    /// handler only yields; all parsing happens on the actor.
    private static func reads(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    cont.finish()
                } else {
                    cont.yield(data)
                }
            }
        }
    }

    private func waitForReady() async throws -> WorkerHello {
        if let hello { return hello }
        if case .exited(let code) = state {
            throw WorkerError(code: "worker_exited", message: "exited with status \(code) before ready\n\(stderrTail.suffix(10).joined())")
        }
        return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func failStartup(_ error: WorkerError) {
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        if let proc = process, proc.isRunning { proc.terminate() }
    }

    private func readyTimedOut(after timeout: Duration) {
        guard state == .starting else { return }
        logStderr("[client] ready timeout after \(timeout); terminating\n")
        failStartup(WorkerError(code: "ready_timeout", message: "worker did not announce ready within \(timeout)\n\(stderrTail.suffix(10).joined())"))
    }

    private func timedOut(_ id: String, after timeout: Duration) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.continuation.resume(throwing: WorkerError(code: "timeout", message: "no response to request \(id) within \(timeout)"))
        Task { _ = try? await self.cancel(requestID: id) }
    }

    private func cancelIfPending(_ id: String) async {
        guard pending[id] != nil else { return }
        _ = try? await cancel(requestID: id)
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            if !line.isEmpty { dispatch(line) }
        }
    }

    private func dispatch(_ line: Data) {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: line) else {
            logStderr("[client] non-protocol line from worker: \(String(decoding: line.prefix(200), as: UTF8.self))\n")
            return
        }
        guard env.v == WorkerProtocol.version else {
            if state == .starting {
                failStartup(WorkerError(code: "protocol_mismatch", message: "worker speaks protocol v\(env.v), app speaks v\(WorkerProtocol.version)"))
            } else {
                logStderr("[client] protocol version mismatch on a line: v\(env.v)\n")
            }
            return
        }
        if let name = env.event {
            let data = JSONLineScanner.topLevelValue(for: "data", in: line) ?? Data("null".utf8)
            if name == "ready" {
                guard let hello = try? JSONDecoder().decode(WorkerHello.self, from: data) else {
                    failStartup(WorkerError(code: "protocol_mismatch", message: "unreadable ready event"))
                    return
                }
                guard hello.protocol == WorkerProtocol.version else {
                    failStartup(WorkerError(code: "protocol_mismatch", message: "worker announced protocol v\(hello.protocol), app speaks v\(WorkerProtocol.version)"))
                    return
                }
                self.hello = hello
                state = .ready
                readyWaiters.forEach { $0.resume(returning: hello) }
                readyWaiters.removeAll()
            }
            eventContinuation.yield(WorkerEvent(name: name, requestID: env.id, data: data))
            return
        }
        guard let id = env.id, let p = pending.removeValue(forKey: id) else {
            logStderr("[client] response for unknown request id \(env.id ?? "null")\n")
            return
        }
        p.timeoutTask?.cancel()
        if env.ok == true {
            p.continuation.resume(returning: JSONLineScanner.topLevelValue(for: "result", in: line) ?? Data("null".utf8))
        } else {
            p.continuation.resume(throwing: WorkerError(code: env.error?.code ?? "unknown", message: env.error?.message ?? "no message"))
        }
    }

    private func logStderr(_ text: String) {
        stderrTail.append(text)
        if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        FileHandle.standardError.write(Data(("[worker] " + text).utf8))
    }

    private func noteEOF(stdout: Bool) {
        if stdout { stdoutEOF = true } else { stderrEOF = true }
        checkExit()
    }

    private func noteTermination(_ status: Int32) {
        terminationStatus = status
        checkExit()
        // A leaked pipe end (e.g. a forked grandchild) could keep EOF from ever arriving.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.forceExitIfStuck()
        }
    }

    private func forceExitIfStuck() {
        guard let status = terminationStatus, !exitHandled else { return }
        logStderr("[client] process exited but pipes did not reach EOF; closing anyway\n")
        didExit(status)
    }

    private func checkExit() {
        guard let status = terminationStatus, stdoutEOF, stderrEOF, !exitHandled else { return }
        didExit(status)
    }

    private func didExit(_ status: Int32) {
        exitHandled = true
        state = .exited(status)
        let err = WorkerError(code: "worker_exited", message: "worker exited with status \(status)\n\(stderrTail.suffix(10).joined())")
        for p in pending.values {
            p.timeoutTask?.cancel()
            p.continuation.resume(throwing: err)
        }
        pending.removeAll()
        readyWaiters.forEach { $0.resume(throwing: err) }
        readyWaiters.removeAll()
        eventContinuation.finish()
        consumerTasks.forEach { $0.cancel() }
        consumerTasks.removeAll()
    }
}

/// Finds the raw bytes of one top-level member of a JSON object without re-encoding,
/// so `result` and event `data` reach callers byte-for-byte (and `evaluation.json` can be
/// stored verbatim). Returns nil if the key is absent or the text is not an object.
enum JSONLineScanner {
    static func topLevelValue(for key: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        func skipWS() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        func skipString() -> Bool {
            guard i < bytes.count, bytes[i] == 0x22 else { return false }
            i += 1
            while i < bytes.count {
                if bytes[i] == 0x5C { i += 2; continue }
                if bytes[i] == 0x22 { i += 1; return true }
                i += 1
            }
            return false
        }
        func skipValue() -> Bool {
            guard i < bytes.count else { return false }
            switch bytes[i] {
            case 0x22: return skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while i < bytes.count {
                    switch bytes[i] {
                    case 0x22: guard skipString() else { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1; if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:
                while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
                return true
            }
        }

        skipWS()
        guard i < bytes.count, bytes[i] == 0x7B else { return nil }
        i += 1
        while i < bytes.count {
            skipWS()
            if i < bytes.count, bytes[i] == 0x7D { return nil }
            let keyStart = i
            guard skipString() else { return nil }
            let rawKey = bytes[(keyStart + 1)..<(i - 1)]
            skipWS()
            guard i < bytes.count, bytes[i] == 0x3A else { return nil }
            i += 1
            skipWS()
            let valueStart = i
            guard skipValue() else { return nil }
            if String(decoding: rawKey, as: UTF8.self) == key {
                return data.subdata(in: (data.startIndex + valueStart)..<(data.startIndex + i))
            }
            skipWS()
            if i < bytes.count, bytes[i] == 0x2C { i += 1 }
        }
        return nil
    }
}
