import CryptoKit
import Foundation

/// The single list of control methods (decision #51). It feeds `hello`, `bci describe`,
/// the `bci` flags and MCP `tools/list`, so the three can't drift apart.
public struct MethodSpec: Sendable, Equatable {
    public enum Kind: String, Sendable { case read, write, job }

    public var name: String
    public var summary: String
    public var params: [ParamSpec]
    /// `job`: long-running; accepts `async` and reports progress and operator prompts.
    public var kind: Kind
    /// Touches a board or a participant session (decision #48).
    public var hardware: Bool

    public init(_ name: String, _ kind: Kind, _ summary: String, hardware: Bool = false, _ params: [ParamSpec] = []) {
        self.name = name; self.kind = kind; self.summary = summary; self.hardware = hardware; self.params = params
    }

    /// `bci <group> <verb>`; the verb uses dashes (`import-example`).
    public var commandWords: (group: String, verb: String) {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1].replacingOccurrences(of: "_", with: "-") : "")
    }

    /// MCP tool name: `bci_evaluate_run`.
    public var toolName: String { "bci_" + name.replacingOccurrences(of: ".", with: "_") }
}

public struct ParamSpec: Sendable, Equatable {
    public enum Kind: String, Sendable { case string, integer, number, boolean, object, array, any }
    public var name: String
    public var kind: Kind
    public var required: Bool
    public var summary: String

    public init(_ name: String, _ kind: Kind, required: Bool = false, _ summary: String) {
        self.name = name; self.kind = kind; self.required = required; self.summary = summary
    }

    /// `windowOffsetS` → `--window-offset-s`.
    public var flag: String {
        var out = "--"
        for ch in name {
            if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }

    public var jsonSchema: JSON {
        var o: [String: JSON] = ["description": .string(summary)]
        switch kind {
        case .any: break
        default: o["type"] = .string(kind.rawValue)
        }
        return .object(o)
    }
}

public enum ControlCatalog {
    private static let project = ParamSpec("project", .string, required: true, "Path of the .bciproj project (opened in the app if it isn't open)")
    private static let recording = ParamSpec("recording", .string, required: true, "Recording UUID")
    private static let result = ParamSpec("result", .string, required: true, "Result UUID")
    private static let job = ParamSpec("job", .string, required: true, "Job id")

    public static let methods: [MethodSpec] = [
        // App and jobs
        .init("app.status", .read, "App version, whether control and hardware are allowed, open projects and active jobs"),
        .init("jobs.list", .read, "Jobs started in this app launch, newest first"),
        .init("jobs.status", .read, "One job's state, progress, operator prompt, and result once done", [job]),
        .init("jobs.wait", .read, "Waits until a job ends or needs the operator, or until the timeout", [
            job, .init("timeoutS", .number, "Seconds to wait (default 30, at most 600)")]),
        .init("jobs.cancel", .write, "Cancels a job (an evaluation is discarded; a run is aborted and its recording kept)", [job]),
        .init("operator.pending", .read, "Prompts waiting for the person at the Mac, across projects"),
        .init("operator.request", .job, "Shows a prompt in the project window and waits until the person confirms or declines it", [
            project, .init("message", .string, required: true, "What the person should do or check")]),

        // Projects
        .init("project.create", .write, "Creates an empty project and opens it", [
            .init("path", .string, required: true, "New .bciproj path (must not exist)"),
            .init("name", .string, "Display name (default: the file name)")]),
        .init("project.import_example", .write, "Copies the bundled example recording (PhysioNet EEGMMIDB S001) into a new project and opens it", [
            .init("path", .string, required: true, "New .bciproj path (must not exist)")]),
        .init("project.open", .write, "Opens a project in the app (shows its window)", [project]),
        .init("project.close", .write, "Closes a project's window; refused while recording or running", [project]),
        .init("project.show", .read, "Project summary: recordings, results, protocols, models, live state", [project]),

        // Recordings
        .init("recordings.list", .read, "Recordings with source, channels, rate, duration and evaluable runs", [project]),
        .init("recordings.show", .read, "A recording's full manifest, event counts and run plans", [project, recording]),
        .init("recordings.verify", .read, "Re-hashes every chunk of a recording; lists integrity issues", [project, recording]),
        .init("recordings.inspect", .job, "Signal-quality inspection (brief 002): flagged and unassessable checks per channel", [project, recording]),

        // Evaluation
        .init("evaluate.defaults", .read, "The worker's default evaluation parameters and recipes", [project]),
        .init("evaluate.run", .job, "Evaluates a recording (CSP + shrinkage LDA vs log-variance baseline, held-out runs fixed before fitting)", [
            project, recording,
            .init("seed", .integer, "Split seed (default: the worker's)"),
            .init("windowOffsetS", .number, "Window start after the cue, seconds"),
            .init("windowLengthS", .number, "Window length, seconds"),
            .init("cspComponents", .integer, "CSP components")]),
        .init("results.list", .read, "Stored results (newest last), optionally for one recording", [
            project, .init("recording", .string, "Only results of this recording")]),
        .init("results.show", .read, "A result's evaluation record, metadata, pipeline and attempt accounting", [project, result]),
        .init("export.result", .write, "Writes a result's export folder (samples, events, pipeline, model arrays, evaluation)", [
            project, result, .init("destination", .string, required: true, "New folder path (never overwritten)")]),

        // Protocols
        .init("protocols.list", .read, "Cued protocol versions and how many recordings use each", [project]),
        .init("protocols.create_version", .write, "Stores a new protocol version (immutable)", [
            project,
            .init("draft", .object, required: true, "ProtocolDraft: name, classes [{label, displayName, cue}], timing {fixationMs, cueMs, restMinMs, restMaxMs}, trialsPerClass, runsPerSession, instructions"),
            .init("basedOn", .string, "Protocol UUID this version follows")]),

        // Models and replay
        .init("models.list", .read, "Frozen models, live runs and replays", [project]),
        .init("models.freeze", .write, "Freezes a result's training-run fit for live use (decision #38)", [
            project, result, .init("name", .string, "Model name"), .init("role", .string, "reference (default) or baseline")]),
        .init("replay.run", .job, "Replays a recording through a frozen model with the live causal path; reports parity", [
            project, .init("model", .string, required: true, "Model UUID"), recording,
            .init("threshold", .number, "Abstention confidence threshold (default 0.6)")]),

        // Acquisition
        .init("sources.list", .read, "Sources the app can connect: serial ports, the synthetic board, the Demo", [
            .init("project", .string, "Project whose live board would connect")]),
        .init("acquisition.connect", .write, "Connects a source, sets the channel map, and starts the preview", hardware: true, [
            project, .init("source", .string, required: true, "Source id from sources.list: synthetic, demo or a serial port path"),
            .init("map", .any, required: true, "\"declared\" (the source's own map, e.g. the Demo's), \"undeclared\" (record without positions), or {labels:[…], montage?, reference?}")]),
        .init("acquisition.status", .read, "Board, stream state, health and recording state", [project]),
        .init("acquisition.record", .job, "Starts recording; with seconds, stops after that long and returns the recording", hardware: true, [
            project, .init("seconds", .number, "Record this long, then stop")]),
        .init("acquisition.stop", .write, "Stops the recording in progress", [project]),
        .init("acquisition.disconnect", .write, "Ends the stream and releases the board", [project]),

        // Cued runs and live tests
        .init("protocol.run", .job, "Cued protocol runs on the live stream, with the participant window; each run waits for the operator", hardware: true, [
            project, .init("protocol", .string, required: true, "Protocol UUID"),
            .init("seed", .integer, "Session seed (default: a new one)"),
            .init("runs", .integer, "Runs in this session (default: the protocol's)"),
            .init("operator", .string, "\"human\" (default) or \"agent\" (synthetic/Demo only: runs start without a person)")]),
        .init("live.test", .job, "A live run with feedback from a frozen model, then its replay check", hardware: true, [
            project, .init("model", .string, required: true, "Model UUID"), .init("protocol", .string, required: true, "Protocol UUID"),
            .init("seed", .integer, "Session seed"), .init("threshold", .number, "Abstention threshold (default 0.6)"),
            .init("operator", .string, "\"human\" (default) or \"agent\" (synthetic/Demo only)")]),
    ]

    public static func spec(_ name: String) -> MethodSpec? { methods.first { $0.name == name } }

    public static func spec(group: String, verb: String) -> MethodSpec? {
        methods.first { $0.commandWords.group == group && $0.commandWords.verb == verb }
    }

    public static func spec(tool: String) -> MethodSpec? { methods.first { $0.toolName == tool } }

    /// The catalogue as `bci describe` prints it.
    public static var describe: JSON {
        .object([
            "protocol": .int(Int64(ControlProtocol.version)),
            "schemaHash": .string(schemaHash),
            "methods": .array(methods.map { m in
                .object([
                    "name": .string(m.name),
                    "command": .string("bci \(m.commandWords.group) \(m.commandWords.verb)"),
                    "kind": .string(m.kind.rawValue),
                    "hardware": .bool(m.hardware),
                    "summary": .string(m.summary),
                    "params": .array(m.params.map { p in
                        .object(["name": .string(p.name), "flag": .string(p.flag), "type": .string(p.kind.rawValue),
                                 "required": .bool(p.required), "summary": .string(p.summary)])
                    }),
                ])
            }),
        ])
    }

    public static var schemaHash: String {
        let text = methods.map { m in m.name + ":" + m.params.map { "\($0.name)/\($0.kind.rawValue)/\($0.required)" }.joined(separator: ",") }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The JSON Schema MCP shows for a method's arguments.
    public static func inputSchema(_ m: MethodSpec) -> JSON {
        var props: [String: JSON] = [:]
        for p in m.params { props[p.name] = p.jsonSchema }
        return .object(["type": "object", "properties": .object(props),
                        "required": .array(m.params.filter(\.required).map { .string($0.name) })])
    }

    /// Checks `params` against the method: required ones present, types right. Unknown
    /// keys are refused so a typo never runs with a default.
    public static func validate(_ m: MethodSpec, _ params: JSON?) -> ControlError? {
        let given = params?.objectValue ?? [:]
        for key in given.keys where !m.params.contains(where: { $0.name == key }) {
            return ControlError(.badRequest, "\(m.name) has no parameter \"\(key)\"")
        }
        for p in m.params {
            guard let v = given[p.name], !v.isNull else {
                if p.required { return ControlError(.badRequest, "\(m.name) needs \(p.name)") }
                continue
            }
            let ok: Bool
            switch p.kind {
            case .string: ok = v.stringValue != nil
            case .integer: ok = v.intValue != nil
            case .number: ok = v.doubleValue != nil
            case .boolean: ok = v.boolValue != nil
            case .object: ok = v.objectValue != nil
            case .array: ok = v.arrayValue != nil
            case .any: ok = true
            }
            if !ok { return ControlError(.badRequest, "\(m.name): \(p.name) must be \(p.kind.rawValue)") }
        }
        return nil
    }
}
