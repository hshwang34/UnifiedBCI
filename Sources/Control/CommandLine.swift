import Foundation

/// `bci` argument parsing, built from `ControlCatalog` (decision #51). It lives here, not in
/// the tool, so the app's tests can check it.
///
///     bci evaluate run --project x.bciproj --recording <uuid> --seed 3 [--async] [--no-wait]
///     bci protocols create-version --project x.bciproj --draft '{"name":…}'
///     bci call evaluate.run '{"project":"…","recording":"…"}'
public enum BCICommand: Equatable, Sendable {
    case help(topic: String?)
    case version
    case describe
    case enable
    case install(prefix: String?)
    case mcp
    /// A control method; `noWait`: exit 7 instead of waiting when the job needs the operator.
    case call(method: String, params: JSON, async: Bool, noWait: Bool)

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ m: String) { message = m }
        public var description: String { message }
    }

    public static func parse(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> BCICommand {
        guard let first = args.first else { return .help(topic: nil) }
        switch first {
        case "help", "-h", "--help": return .help(topic: args.dropFirst().first)
        case "version", "--version": return .version
        case "describe": return .describe
        case "enable": return .enable
        case "mcp": return .mcp
        case "install":
            var prefix: String?
            var rest = Array(args.dropFirst())
            while !rest.isEmpty {
                let a = rest.removeFirst()
                guard a == "--prefix", !rest.isEmpty else { throw UsageError("usage: bci install [--prefix DIR]") }
                prefix = rest.removeFirst()
            }
            return .install(prefix: prefix)
        case "call":
            guard args.count >= 2, let spec = ControlCatalog.spec(args[1]) else { throw UsageError("usage: bci call <method> ['{json params}'] (see bci describe)") }
            let params = args.count >= 3 ? try parseJSON(args[2], what: "params") : .object([:])
            guard params.objectValue != nil else { throw UsageError("params must be a JSON object") }
            let flags = args.dropFirst(3)
            return .call(method: spec.name, params: params, async: flags.contains("--async"), noWait: flags.contains("--no-wait"))
        default: break
        }
        guard args.count >= 2, let spec = ControlCatalog.spec(group: first, verb: args[1]) else {
            let group = ControlCatalog.methods.filter { $0.commandWords.group == first }
            if group.isEmpty { throw UsageError("unknown command \"\(first)\"; run bci help") }
            throw UsageError("usage: bci \(first) <\(group.map(\.commandWords.verb).joined(separator: "|"))>")
        }
        var params: [String: JSON] = [:]
        var isAsync = false, noWait = false
        var rest = Array(args.dropFirst(2))
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            if flag == "--async" { isAsync = true; continue }
            if flag == "--no-wait" { noWait = true; continue }
            guard let p = spec.params.first(where: { $0.flag == flag }) else {
                throw UsageError("bci \(first) \(args[1]) has no option \(flag); options: \(spec.params.map(\.flag).joined(separator: " "))")
            }
            if p.kind == .boolean, rest.first.map({ $0.hasPrefix("--") }) ?? true { params[p.name] = .bool(true); continue }
            guard !rest.isEmpty else { throw UsageError("\(flag) needs a value") }
            params[p.name] = try value(rest.removeFirst(), for: p)
        }
        if spec.params.contains(where: { $0.name == "project" }), params["project"] == nil, let p = environment["BCI_PROJECT"], !p.isEmpty {
            params["project"] = .string(p)
        }
        for key in ["project", "path", "destination"] { if let s = params[key]?.stringValue { params[key] = .string(absolutePath(s)) } }
        let json = JSON.object(params)
        if let e = ControlCatalog.validate(spec, json) { throw UsageError(e.message) }
        return .call(method: spec.name, params: json, async: isAsync, noWait: noWait)
    }

    static func value(_ text: String, for p: ParamSpec) throws -> JSON {
        switch p.kind {
        case .string: return .string(text)
        case .integer:
            guard let i = Int64(text) else { throw UsageError("\(p.flag) must be an integer") }
            return .int(i)
        case .number:
            guard let d = Double(text), d.isFinite else { throw UsageError("\(p.flag) must be a number") }
            return .double(d)
        case .boolean:
            guard let b = JSON.string(text).boolValue else { throw UsageError("\(p.flag) must be true or false") }
            return .bool(b)
        case .object, .array: return try parseJSON(text, what: p.flag)
        case .any:
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("{") || t.hasPrefix("[") ? try parseJSON(t, what: p.flag) : .string(text)
        }
    }

    static func parseJSON(_ text: String, what: String) throws -> JSON {
        do { return try JSON.parse(text) } catch { throw UsageError("\(what) is not valid JSON") }
    }

    static func absolutePath(_ s: String) -> String {
        let expanded = (s as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
    }

    public static var usage: String {
        var lines = [
            "bci: drive BCI Workspace from a coding agent or a terminal (brief 008)",
            "",
            "  bci enable                 ask BCI Workspace to allow agent control (confirm in the app)",
            "  bci install [--prefix DIR] link this tool into DIR (default ~/.local/bin)",
            "  bci describe               the command catalogue as JSON",
            "  bci mcp                    serve the commands as MCP tools over stdio",
            "  bci call <method> '{…}'    any method with JSON params",
            "",
            "Results print as JSON on stdout; progress and operator prompts as JSON lines on stderr.",
            "Long commands accept --async (return a job id) and --no-wait (exit 7 when the job waits for the operator).",
            "BCI_PROJECT sets --project. Exit codes: 0 ok, 1 failed, 2 usage, 3 protocol mismatch, 4 app unreachable or control off,",
            "5 refused, 6 cancelled, 7 waiting for the operator.",
            "",
        ]
        var group = ""
        for m in ControlCatalog.methods {
            let w = m.commandWords
            if w.group != group { group = w.group; lines.append("") }
            let flags = m.params.map { $0.required ? "\($0.flag) …" : "[\($0.flag) …]" }.joined(separator: " ")
            lines.append("  bci \(w.group) \(w.verb) \(flags)")
            lines.append("      \(m.summary)")
        }
        return lines.joined(separator: "\n")
    }
}
