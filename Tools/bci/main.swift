import AppKit
import Foundation

// `bci`: drives BCI Workspace for coding agents and terminals (brief 008). A thin client:
// every command runs in the app, over the control socket. See docs/agent-interface.md.

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ json: JSON, to handle: FileHandle = .standardOutput, pretty: Bool = true) {
    var d = json.data(pretty: pretty)
    d.append(0x0A)
    handle.write(d)
}

func fail(_ message: String, code: ExitCode, data: JSON? = nil) -> Never {
    var o: [String: JSON] = ["error": .object(["message": .string(message), "data": data ?? .null])]
    o["exitCode"] = .int(Int64(code.rawValue))
    emit(.object(o), to: .standardError, pretty: false)
    exit(code.rawValue)
}

let clientName = "bci/\(MCPAdapter.version)"

// MARK: Finding and launching the app

enum Launcher {
    static var controlDir: URL { ControlProtocol.directory() }

    static func connect() -> ControlClientConnection? {
        let dir = controlDir
        guard let token = try? String(contentsOf: ControlProtocol.tokenURL(in: dir), encoding: .utf8),
              let c = try? ControlClientConnection(socketPath: ControlProtocol.socketURL(in: dir).path) else { return nil }
        do {
            _ = try c.hello(token: token.trimmingCharacters(in: .whitespacesAndNewlines), client: clientName)
            return c
        } catch let e as ControlError where e.code == ControlError.Code.protocolMismatch.rawValue {
            fail("This bci speaks control protocol \(ControlProtocol.version); the app doesn't. Use the bci inside the app (bci install).", code: .protocolMismatch, data: e.data)
        } catch {
            return nil
        }
    }

    /// The app this tool belongs to: `BCI_APP_PATH`, the app around `Contents/Helpers/bci`
    /// (through the install symlink), a sibling build product, else by bundle id.
    static func appURL() -> URL? {
        if let p = ProcessInfo.processInfo.environment["BCI_APP_PATH"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let helpers = me.deletingLastPathComponent()
        if helpers.lastPathComponent == "Helpers" {
            let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app }
        }
        let sibling = helpers.appendingPathComponent("BCIWorkspace.app")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: ControlProtocol.bundleIdentifier)
    }

    static var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ControlProtocol.bundleIdentifier).isEmpty
    }

    static func launch(activate: Bool) -> Bool {
        guard let url = appURL() else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        config.addsToRecentItems = false
        final class Outcome: @unchecked Sendable { var ok = false }
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in outcome.ok = app != nil; done.signal() }
        done.wait()
        return outcome.ok
    }

    /// A connection to the running app, launching it in the background if needed.
    static func require() -> ControlClientConnection {
        if let c = connect() { return c }
        let wasRunning = isAppRunning
        if !wasRunning {
            guard launch(activate: false) else { fail("BCI Workspace isn't installed where bci can find it (set BCI_APP_PATH).", code: .unreachable) }
        }
        let deadline = Date().addingTimeInterval(wasRunning ? 2 : 20)
        while Date() < deadline {
            if let c = connect() { return c }
            Thread.sleep(forTimeInterval: 0.25)
        }
        fail("Agent control is off in BCI Workspace. Run `bci enable` (you confirm it in the app), or turn it on in Settings ▸ Agent Control.", code: .unreachable)
    }
}

// MARK: Commands

func runCall(method: String, params: JSON, async: Bool, noWait: Bool) -> Never {
    let c = Launcher.require()
    let spec = ControlCatalog.spec(method)
    do {
        if spec?.kind == .job, noWait || async {
            var status = try c.call(method, params: params, async: true)
            if noWait, let job = status["job"]?.stringValue {
                while true {
                    status = try c.call("jobs.wait", params: ["job": .string(job), "timeoutS": 30])
                    let state = status["state"]?.stringValue
                    if state == "awaiting_operator" { emit(status); exit(ExitCode.awaitingOperator.rawValue) }
                    if state != "running" { break }
                }
                if status["state"]?.stringValue == "done" { emit(status["result"] ?? status); exit(0) }
                emit(status)
                exit(ExitCode.for(status["error"]?["code"]?.stringValue ?? "failed").rawValue)
            }
            emit(status)
            exit(0)
        }
        let result = try c.call(method, params: params) { event in
            emit(.object(["event": .from(event.event), "data": event.data ?? .null]), to: .standardError, pretty: false)
        }
        emit(result)
        exit(0)
    } catch let e as ControlError {
        emit(.object(["error": .object(["code": .string(e.code), "message": .string(e.message), "data": e.data ?? .null])]))
        exit(e.exitCode.rawValue)
    } catch {
        fail("\(error)", code: .failed)
    }
}

func enable() -> Never {
    if Launcher.connect() != nil { emit(["enabled": true]); exit(0) }
    if !Launcher.isAppRunning { _ = Launcher.launch(activate: true); Thread.sleep(forTimeInterval: 1.5) }
    // The app shows "Allow coding agents to control BCI Workspace?"; the person answers there.
    NSWorkspace.shared.open(ControlProtocol.enableURL)
    FileHandle.standardError.write(Data("Confirm in BCI Workspace…\n".utf8))
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        if Launcher.connect() != nil { emit(["enabled": true]); exit(0) }
        Thread.sleep(forTimeInterval: 0.5)
    }
    fail("Agent control wasn't turned on (declined, or no answer within 2 minutes).", code: .unreachable)
}

func install(prefix: String?) -> Never {
    let dir = URL(fileURLWithPath: ((prefix ?? "~/.local/bin") as NSString).expandingTildeInPath, isDirectory: true)
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let link = dir.appendingPathComponent("bci")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard existing != me.path else { emit(["installed": .string(link.path), "target": .string(me.path)]); exit(0) }
            try FileManager.default.removeItem(at: link)
        } else if FileManager.default.fileExists(atPath: link.path) {
            fail("\(link.path) exists and isn't a link; remove it first.", code: .failed)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: me)
        var out: [String: JSON] = ["installed": .string(link.path), "target": .string(me.path)]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(dir.path)) { out["note"] = .string("\(dir.path) is not on PATH") }
        emit(.object(out))
        exit(0)
    } catch {
        fail("\(error)", code: .failed)
    }
}

/// MCP over stdio: one thread reads requests; each tool call runs on its own connection.
func serveMCP() -> Never {
    let out = NSLock()
    func send(_ j: JSON) {
        var d = j.data()
        d.append(0x0A)
        out.withLock { FileHandle.standardOutput.write(d) }
    }
    let adapter = MCPAdapter(call: { method, params, async in
        // A fresh connection per call: tool calls may overlap, and each waits on its own.
        let c = Launcher.require()
        return try c.call(method, params: params, async: async)
    }, notify: send)
    var lines = LineBuffer()
    let group = DispatchGroup()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        guard let batch = try? lines.append(chunk) else { break }
        for line in batch {
            guard let message = try? JSON.parse(line) else {
                send(["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            let isCall = message["method"]?.stringValue == "tools/call"
            if isCall {
                group.enter()
                DispatchQueue.global().async {
                    if let r = adapter.handle(message) { send(r) }
                    group.leave()
                }
            } else if let r = adapter.handle(message) {
                send(r)
            }
        }
    }
    group.wait()
    exit(0)
}

// MARK: Main

do {
    switch try BCICommand.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help: print(BCICommand.usage); exit(0)
    case .version: emit(["bci": .string(MCPAdapter.version), "protocol": .int(Int64(ControlProtocol.version))]); exit(0)
    case .describe: emit(ControlCatalog.describe); exit(0)
    case .enable: enable()
    case .install(let prefix): install(prefix: prefix)
    case .mcp: serveMCP()
    case .call(let method, let params, let async, let noWait): runCall(method: method, params: params, async: async, noWait: noWait)
    }
} catch let e as BCICommand.UsageError {
    FileHandle.standardError.write(Data((e.message + "\n").utf8))
    exit(ExitCode.usage.rawValue)
}
