import Foundation

/// `bci mcp`: the control catalogue as MCP tools over stdio JSON-RPC (decision #51).
/// It handles initialize, ping, tools/list and tools/call, and ignores notifications.
/// The tool does the I/O; this type only maps messages, so tests can drive it.
public final class MCPAdapter: @unchecked Sendable {
    /// Calls one control method and returns its result (throws `ControlError`).
    public typealias Call = (_ method: String, _ params: JSON, _ async: Bool) throws -> JSON
    /// Sends a notification (progress) to the MCP client.
    public typealias Notify = (JSON) -> Void

    private let call: Call
    private let notify: Notify
    /// How long one tool call may block before it returns the job to poll (client timeouts).
    public var jobBudgetSeconds: Double = 50

    public init(call: @escaping Call, notify: @escaping Notify) {
        self.call = call; self.notify = notify
    }

    public static let instructions = """
    BCI Workspace runs EEG experiments. These tools drive the running app; the person at the Mac sees every step.
    Rules:
    (1) The held-out runs are fixed before fitting. Never choose a configuration by its held-out score, and report every attempt (each result carries `accounting`).
    (2) A job in state awaiting_operator is waiting for the person at the Mac (electrodes, participant ready, resume). Relay its prompt to your user and call bci_jobs_wait. Never claim you confirmed it.
    (3) Never say hardware was tested unless the person says so.
    (4) Give an explicit channel map when connecting: "declared", "undeclared", or labels. Never guess 10-20 positions from the channel count.
    (5) Two-class classifiers don't detect "no intent"; abstention is a policy.
    """

    /// Handles one JSON-RPC message; returns the response, or nil for a notification.
    public func handle(_ message: JSON) -> JSON? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            return id.map { Self.error(id: $0, code: -32600, "not a JSON-RPC request") }
        }
        guard let id else { return nil }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? "2025-06-18"
            return Self.result(id: id, [
                "protocolVersion": .string(requested),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "bci-workspace", "version": .string(Self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(Self.tools)])
        case "tools/call":
            guard let name = params["name"]?.stringValue, let spec = ControlCatalog.spec(tool: name) else {
                return Self.error(id: id, code: -32602, "unknown tool \(params["name"]?.stringValue ?? "")")
            }
            let args = params["arguments"] ?? .object([:])
            let token = params["_meta"]?["progressToken"]
            return Self.result(id: id, toolCall(spec, args, progressToken: token))
        default:
            return Self.error(id: id, code: -32601, "method not found: \(method)")
        }
    }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    public static var tools: [JSON] {
        ControlCatalog.methods.map { m in
            var description = m.summary
            if m.kind == .job { description += ". Long-running: returns the result when done within ~50 s, else the job to follow with bci_jobs_wait." }
            if m.hardware { description += " Needs \"Allow agents to use hardware\" for serial boards; human steps wait for the operator." }
            return .object([
                "name": .string(m.toolName),
                "description": .string(description),
                "inputSchema": ControlCatalog.inputSchema(m),
                "annotations": ["readOnlyHint": .bool(m.kind == .read), "openWorldHint": false],
            ])
        }
    }

    func toolCall(_ spec: MethodSpec, _ args: JSON, progressToken: JSON?) -> JSON {
        do {
            if let e = ControlCatalog.validate(spec, args) { throw e }
            guard spec.kind == .job else { return Self.content(try call(spec.name, args, false), isError: false) }
            let started = try call(spec.name, args, true)
            guard let job = started["job"]?.stringValue else { return Self.content(started, isError: false) }
            let deadline = Date().addingTimeInterval(jobBudgetSeconds)
            var tick = 0
            while true {
                let left = deadline.timeIntervalSinceNow
                let status = try call("jobs.wait", ["job": .string(job), "timeoutS": .double(max(1, min(10, left)))], false)
                let state = status["state"]?.stringValue ?? ""
                if state == "done" { return Self.content(status["result"] ?? status, isError: false) }
                if ["failed", "cancelled"].contains(state) { return Self.content(status, isError: true) }
                if state == "awaiting_operator" {
                    var s = status.objectValue ?? [:]
                    s["note"] = .string("The app is waiting for the person at the Mac: \(status["prompt"]?.stringValue ?? "a confirmation"). Tell your user, then call bci_jobs_wait with this job.")
                    return Self.content(.object(s), isError: false)
                }
                tick += 1
                if let progressToken {
                    var p: [String: JSON] = ["progressToken": progressToken, "progress": .int(Int64(tick))]
                    if let stage = status["progress"]?["stage"]?.stringValue { p["message"] = .string(stage) }
                    notify(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object(p)])
                }
                if deadline.timeIntervalSinceNow <= 0 {
                    var s = status.objectValue ?? [:]
                    s["note"] = .string("Still running. Call bci_jobs_wait with this job to keep waiting.")
                    return Self.content(.object(s), isError: false)
                }
            }
        } catch let e as ControlError {
            return Self.content(["error": .object(["code": .string(e.code), "message": .string(e.message), "data": e.data ?? .null])], isError: true)
        } catch {
            return Self.content(["error": ["code": "internal", "message": .string("\(error)")]], isError: true)
        }
    }

    static func content(_ value: JSON, isError: Bool) -> JSON {
        var o: [String: JSON] = ["content": [["type": "text", "text": .string(String(decoding: value.data(pretty: true), as: UTF8.self))]],
                                 "isError": .bool(isError)]
        if value.objectValue != nil { o["structuredContent"] = value }
        return .object(o)
    }

    static func result(id: JSON, _ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func error(id: JSON, code: Int64, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
