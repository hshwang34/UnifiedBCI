import AppKit
import Foundation

/// Dispatches control requests on the main actor (brief 008). Every handler goes through
/// the same `Workspace` / `ProjectSession` methods the views use, so the windows show what
/// the agent did and the one-session-per-project rule holds. An action is refused for the
/// same reasons its button would be disabled, with the button's own words (`data.reason`).
@MainActor
final class ControlRouter {
    let workspace: Workspace
    /// Hardware toggles; tests replace them.
    var settings: ControlSettings
    private(set) var jobs: [ControlJob] = []
    /// In-flight requests by connection and request id, for `cancel`.
    private var inflight: [String: ControlJob] = [:]
    private var activity: AgentActivity { .shared }
    /// Serial ports the person allowed this launch (decision #48: once per launch).
    var allowedPorts: Set<String> = []
    /// Asks the person to allow a serial connect; tests replace it.
    var confirmHardware: (_ port: String, _ session: ProjectSession) async -> Bool = ControlRouter.askForHardware

    init(workspace: Workspace, settings: ControlSettings = .standard) {
        self.workspace = workspace
        self.settings = settings
    }

    typealias Reply = @Sendable (ControlMessage) -> Void

    /// Handles one request from a connection; `reply` sends lines back on it.
    func handle(_ request: ControlRequest, client: String = "agent", connection: String = "local", reply: @escaping Reply) async {
        if request.method == "cancel" {
            let target = request.params?["id"]?.stringValue ?? ""
            let job = inflight["\(connection)/\(target)"] ?? jobs.first { $0.id == target }
            job?.cancel()
            return reply(.response(request.id, ["cancelled": .bool(job != nil)]))
        }
        guard let spec = ControlCatalog.spec(request.method) else {
            AppLog.notice(.control, "request", ["method": "unknown", "outcome": ControlError.Code.unknownMethod.rawValue])
            return reply(.failure(request.id, ControlError(.unknownMethod, "no method \(request.method); see bci describe")))
        }
        let started = ContinuousClock.now
        if let e = ControlCatalog.validate(spec, request.params) {
            AppLog.notice(.control, "request", ["method": spec.name, "outcome": e.code, "ms": AppLog.ms(since: started)])
            return reply(.failure(request.id, e))
        }
        let call = ControlCall(router: self, spec: spec, params: request.params?.objectValue ?? [:], client: client)
        let project = call.projectURL
        guard spec.kind == .job else {
            let outcome = await run(call)
            Self.logRequest(spec.name, outcome, started: started, job: nil)
            log(call, outcome: outcome, job: nil)
            switch outcome {
            case .success(let r): reply(.response(request.id, r))
            case .failure(let e): reply(.failure(request.id, e))
            }
            return
        }
        let job = ControlJob(method: spec.name, project: project)
        call.job = job
        jobs.insert(job, at: 0)
        prune()
        activity.jobStarted(spec.name, project: project)
        let key = "\(connection)/\(request.id)"
        inflight[key] = job
        let listener = request.async == true ? nil : job.listen { reply(ControlMessage(id: request.id, event: $0.event, data: $0.data)) }
        job.task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.run(call)
            job.finish(outcome)
            Self.logRequest(spec.name, outcome, started: started, job: job.id)
            self.log(call, outcome: outcome, job: job.id)
            self.activity.jobEnded(project: project, stillRunning: self.jobs.filter { !$0.isFinished }.count)
        }
        if request.async == true {
            inflight[key] = nil
            return reply(.response(request.id, job.status))
        }
        await job.waitUntilFinished()
        if let listener { job.unlisten(listener) }
        inflight[key] = nil
        if let e = job.error { reply(.failure(request.id, e)) } else { reply(.response(request.id, job.result ?? .null)) }
    }

    private func run(_ call: ControlCall) async -> Result<JSON, ControlError> {
        do {
            return .success(try await dispatch(call))
        } catch let e as ControlError {
            return .failure(e)
        } catch is CancellationError {
            return .failure(ControlError(.cancelled, "cancelled"))
        } catch {
            return .failure(ControlError(.failed, "\(error)"))
        }
    }

    private func dispatch(_ c: ControlCall) async throws -> JSON {
        switch c.spec.name {
        case "app.status": return appStatus()
        case "app.diagnostics": return await appDiagnostics(c)
        case "jobs.list": return .object(["jobs": .array(jobs.map(\.status))])
        case "jobs.status": return try job(c).status
        case "jobs.wait":
            let job = try job(c)
            await job.wait(timeout: .seconds(min(600, max(0, c.double("timeoutS") ?? 30))))
            return job.status
        case "jobs.cancel":
            let job = try job(c)
            job.cancel()
            return job.status
        case "operator.pending":
            return .object(["prompts": .array(activity.prompts.map { ["project": .string($0.project.path), "message": .string($0.message), "needsAnswer": .bool($0.asks)] })])
        case "operator.request": return try await operatorRequest(c)
        case "project.create": return try await projectCreate(c)
        case "project.import_example": return try await projectImportExample(c)
        case "project.open": return try await projectSummary(c.session())
        case "project.close": return try await projectClose(c)
        case "project.show": return try await projectSummary(c.session())
        case "recordings.list": return try await recordingsList(c)
        case "recordings.show": return try await recordingsShow(c)
        case "recordings.verify": return try await recordingsVerify(c)
        case "recordings.inspect": return try await recordingsInspect(c)
        case "evaluate.defaults": return try await evaluateDefaults(c)
        case "evaluate.run": return try await evaluateRun(c)
        case "results.list": return try await resultsList(c)
        case "results.show": return try await resultsShow(c)
        case "export.result": return try await exportResult(c)
        case "protocols.list": return try await protocolsList(c)
        case "protocols.create_version": return try await protocolsCreate(c)
        case "models.list": return try await modelsList(c)
        case "models.freeze": return try await modelsFreeze(c)
        case "replay.run": return try await replayRun(c)
        case "sources.list": return try await sourcesList(c)
        case "acquisition.connect": return try await acquisitionConnect(c)
        case "acquisition.status": return try await acquisitionStatus(c.session())
        case "acquisition.record": return try await acquisitionRecord(c)
        case "acquisition.stop": return try await acquisitionStop(c)
        case "acquisition.disconnect": return try await acquisitionDisconnect(c)
        case "protocol.run": return try await protocolRun(c)
        case "live.test": return try await liveTest(c)
        default: throw ControlError(.unknownMethod, "\(c.spec.name) is not implemented")
        }
    }

    private func job(_ c: ControlCall) throws -> ControlJob {
        let id = try c.require("job")
        guard let job = jobs.first(where: { $0.id == id }) else { throw ControlError(.notFound, "no job \(id) in this app launch") }
        return job
    }

    /// Keeps finished jobs for an hour, and never more than 200.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        jobs.removeAll { $0.isFinished && ($0.endedAt ?? .distantFuture) < cutoff }
        if jobs.count > 200 { jobs = Array(jobs.prefix(200)) }
    }

    func appStatus() -> JSON {
        .object([
            "appVersion": .string(ControlServer.appVersion),
            "protocol": .int(Int64(ControlProtocol.version)),
            "controlEnabled": .bool(settings.enabled),
            "hardwareAllowed": .bool(settings.hardwareAllowed),
            "openProjects": .array(workspace.sessions.values.sorted { $0.url.path < $1.url.path }.map { s in
                ["path": .string(s.url.path), "name": .string(s.name), "evaluating": .bool(s.isRunning),
                 "recording": .bool(s.isRecording), "liveRunning": .bool(s.isLiveRunning), "streaming": .bool(s.live?.state == .streaming)]
            }),
            "activeJobs": .array(jobs.filter { !$0.isFinished }.map(\.status)),
            // Decision #26: this interface never says a board was tested.
            "hardwareTested": false,
        ])
    }

    /// One line per call in the app log (brief 009): method, outcome code, duration, job.
    private static func logRequest(_ method: String, _ outcome: Result<JSON, ControlError>, started: ContinuousClock.Instant, job: String?) {
        let code: String
        switch outcome {
        case .success: code = "ok"
        case .failure(let e): code = e.code
        }
        let level: AppLog.Level = code == "ok" || code == ControlError.Code.cancelled.rawValue ? .info : .notice
        AppLog.log(level, .control, "request", ["method": method, "outcome": code, "ms": AppLog.ms(since: started), "job": job ?? "-"])
    }

    // MARK: Action log (decision #49)

    private func log(_ call: ControlCall, outcome: Result<JSON, ControlError>, job: String?) {
        guard call.spec.kind != .read, let project = call.projectURL ?? call.createdProject else { return }
        var params = call.params
        params["draft"] = params["draft"].map { _ in "…" }
        var entry: [String: JSON] = [
            "ts": .from(Date()), "client": .string(call.client), "method": .string(call.spec.name), "params": .object(params),
            "job": .from(job),
        ]
        switch outcome {
        case .success(let r):
            entry["outcome"] = "ok"
            // What the call made, so the log (and attempt accounting) can name it.
            for key in ["resultID", "recordingID", "modelID", "liveRunID", "protocolID"] { if let v = r[key], !v.isNull { entry[key == "resultID" ? "result" : key] = v } }
        case .failure(let e):
            entry["outcome"] = .string(e.code)
        }
        AgentActionLog.append(.object(entry), project: project)
    }

    // MARK: Helpers for handlers

    /// The project's session: the open one, else opened (its window shown) the way Open… does.
    func session(at url: URL) async throws -> ProjectSession {
        if let s = workspace.sessions[Workspace.canonical(url)] { return s }
        do {
            let s = try await workspace.session(for: url)
            s.openedByAgent = true
            workspace.noteRecent(s.url)
            workspace.show(s.url)
            return s
        } catch {
            throw ControlError(.notFound, Workspace.openFailureMessage(error), data: ["path": .string(url.path)])
        }
    }

    /// Refuses while a sheet is up: the person is in the middle of something here.
    func requireIdleUI(_ s: ProjectSession) throws {
        if s.isSheetUp { throw ControlError(.uiBusy, "A sheet is open in \(s.name); finish or close it in the app first.") }
    }

    static func askForHardware(port: String, session: ProjectSession) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let a coding agent connect to \(port)?"
        alert.informativeText = "The agent asked to connect this board in \(session.name). Human steps (starting runs, resuming) stay with you. You're asked once per launch for each port."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate()
        guard let window = session.projectWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { c in
            alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }
}

/// One call's parameters and context.
@MainActor
final class ControlCall {
    let router: ControlRouter
    let spec: MethodSpec
    let params: [String: JSON]
    let client: String
    var job: ControlJob?
    /// A project this call created (logged there).
    var createdProject: URL?

    init(router: ControlRouter, spec: MethodSpec, params: [String: JSON], client: String) {
        self.router = router; self.spec = spec; self.params = params; self.client = client
    }

    var projectURL: URL? { string("project").map { Workspace.canonical(URL(fileURLWithPath: $0)) } }

    func string(_ k: String) -> String? { params[k]?.stringValue }
    func int(_ k: String) -> Int? { params[k]?.intValue }
    func double(_ k: String) -> Double? { params[k]?.doubleValue }

    func require(_ k: String) throws -> String {
        guard let v = string(k), !v.isEmpty else { throw ControlError(.badRequest, "\(spec.name) needs \(k)") }
        return v
    }

    func uuid(_ k: String) throws -> UUID {
        let v = try require(k)
        guard let u = UUID(uuidString: v) else { throw ControlError(.badRequest, "\(k) is not a UUID: \(v)") }
        return u
    }

    func session() async throws -> ProjectSession {
        guard let url = projectURL else { throw ControlError(.badRequest, "\(spec.name) needs project") }
        return try await router.session(at: url)
    }

    func progress(_ data: JSON) { job?.report(data) }
}
