import Foundation

/// Control protocol v1 (brief 008, decisions #47 and #51), shared by the app's control
/// server and the `bci` tool. It is JSON lines over a Unix socket that only the same user
/// can reach, in the same style as the worker protocol (`Sources/WorkerClient`):
///
///     → {"id":"1","method":"hello","params":{"protocol":1,"token":"…","client":"bci/0.1"}}
///     ← {"id":"1","result":{"protocol":1,"appVersion":"0.1.0","methods":[…],"schemaHash":"…"}}
///     → {"id":"2","method":"evaluate.run","params":{"project":"/…/x.bciproj"}}
///     ← {"event":"progress","id":"2","data":{"stage":"fitting",…}}
///     ← {"event":"operator","id":"2","data":{"prompt":"…","job":"…"}}
///     ← {"id":"2","result":{…}}            or {"id":"2","error":{"code":"refused","message":"…"}}
///
/// Each request gets exactly one response, matched by id (several may share a connection).
/// `"async": true` on a job method answers at once with `{job, state}`; `jobs.wait` and
/// `jobs.status` follow it. `cancel {id}` cancels a request in flight. A dropped
/// connection does not cancel its jobs. Methods may be added within v1; changing what one
/// means is v2.
public enum ControlProtocol {
    public static let version = 1
    /// No single line (request, event or response) may exceed this.
    public static let maxLineBytes = 4 << 20
    public static let bundleIdentifier = "com.hshwang34.BCIWorkspace"
    /// The app's URL scheme; `bciworkspace://enable-control` asks the person to turn control on.
    public static let urlScheme = "bciworkspace"
    public static let enableURL = URL(string: "bciworkspace://enable-control")!

    /// `~/Library/Application Support/com.hshwang34.BCIWorkspace/control` (0700). Tests and
    /// a second dev copy override it with `BCI_CONTROL_DIR`.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["BCI_CONTROL_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent("control", isDirectory: true)
    }

    public static func socketURL(in dir: URL) -> URL { dir.appendingPathComponent("control.sock") }
    public static func tokenURL(in dir: URL) -> URL { dir.appendingPathComponent("token") }
    public static func serverURL(in dir: URL) -> URL { dir.appendingPathComponent("server.json") }
}

/// One request line.
public struct ControlRequest: Codable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: JSON?
    /// Job methods only: answer at once with `{job, state}` instead of waiting for the end.
    public var async: Bool?

    public init(id: String, method: String, params: JSON? = nil, async: Bool? = nil) {
        self.id = id; self.method = method; self.params = params; self.async = async
    }
}

/// An error answer. `data.reason` carries the app's own disabled-button wording when an
/// action is refused for the reason the button would be disabled.
public struct ControlError: Codable, Sendable, Equatable, Error, CustomStringConvertible {
    public var code: String
    public var message: String
    public var data: JSON?

    public init(_ code: Code, _ message: String, data: JSON? = nil) {
        self.code = code.rawValue; self.message = message; self.data = data
    }

    public var description: String { "\(code): \(message)" }

    public enum Code: String, Sendable, CaseIterable {
        case badRequest = "bad_request"
        case unauthorized
        case protocolMismatch = "protocol_mismatch"
        case unknownMethod = "unknown_method"
        case notFound = "not_found"
        /// The app said no, for a reason the person would see (`data.reason`).
        case refused
        /// A sheet is open or the person is mid-action in this project.
        case uiBusy = "ui_busy"
        /// "Allow agents to use hardware" is off, or the person declined the connect.
        case hardwareNotAllowed = "hardware_not_allowed"
        case failed
        case cancelled
        case timeout
        case `internal`
    }

    public var exitCode: ExitCode { ExitCode.for(code) }
}

/// Every line the app sends: a response (`id` with `result` or `error`) or an event.
public struct ControlMessage: Codable, Sendable, Equatable {
    public var id: String?
    public var result: JSON?
    public var error: ControlError?
    public var event: String?
    public var data: JSON?

    public init(id: String?, result: JSON? = nil, error: ControlError? = nil, event: String? = nil, data: JSON? = nil) {
        self.id = id; self.result = result; self.error = error; self.event = event; self.data = data
    }

    public static func response(_ id: String, _ result: JSON) -> ControlMessage { .init(id: id, result: result) }
    public static func failure(_ id: String?, _ error: ControlError) -> ControlMessage { .init(id: id, error: error) }
    public static func event(_ name: String, id: String, _ data: JSON) -> ControlMessage { .init(id: id, event: name, data: data) }

    public var isEvent: Bool { event != nil }
}

/// `server.json`: where a running app listens (discovery; the socket is the truth).
public struct ControlServerInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var `protocol`: Int
    public var appVersion: String
    public var socket: String

    public init(pid: Int32, protocol: Int, appVersion: String, socket: String) {
        self.pid = pid; self.protocol = `protocol`; self.appVersion = appVersion; self.socket = socket
    }
}

/// `bci` exit codes (docs/agent-interface.md).
public enum ExitCode: Int32, Sendable {
    case ok = 0
    case failed = 1
    case usage = 2
    case protocolMismatch = 3
    /// The app can't be reached, or agent control is off (`bci enable`).
    case unreachable = 4
    case refused = 5
    case cancelled = 6
    /// `--no-wait` on a job that is waiting for the person at the Mac.
    case awaitingOperator = 7

    public static func `for`(_ code: String) -> ExitCode {
        switch ControlError.Code(rawValue: code) {
        case .badRequest?, .unknownMethod?: return .usage
        case .protocolMismatch?: return .protocolMismatch
        case .unauthorized?: return .unreachable
        case .refused?, .uiBusy?, .hardwareNotAllowed?: return .refused
        case .cancelled?: return .cancelled
        default: return .failed
        }
    }
}

/// Splits a byte stream into lines, refusing any line over `maxLineBytes`.
public struct LineBuffer: Sendable {
    private var buffer = Data()
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = ControlProtocol.maxLineBytes) { self.maxLineBytes = maxLineBytes }

    public enum Failure: Error, Equatable { case lineTooLong }

    /// Appends bytes and returns every complete line (without its newline).
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if line.count > maxLineBytes { throw Failure.lineTooLong }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > maxLineBytes { throw Failure.lineTooLong }
        return lines
    }

    public var isEmpty: Bool { buffer.isEmpty }
}

public extension ControlMessage {
    /// One wire line, newline included.
    func line() -> Data {
        var d = (try? JSON.encoder().encode(self)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }
}

public extension ControlRequest {
    func line() -> Data {
        var d = (try? JSON.encoder().encode(self)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }
}
