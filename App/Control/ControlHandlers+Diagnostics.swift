import Foundation

/// `app.diagnostics` (brief 009): what the app was doing just before something broke.
extension ControlRouter {
    func appDiagnostics(_ c: ControlCall) async -> JSON {
        let log = DiagnosticsLog.shared
        let limit = min(log.limits.events, max(0, c.int("limit") ?? 200))
        let status = appStatus()
        let events = log.recent()
        let since = CrashReports.cutoff(previousLaunch: log.previousLaunchAt)
        let crashes = await Task.detached { CrashReports.summaries(since: since) }.value
        let memory = ProcessMemory.current()
        let projects = (status["openProjects"]?.arrayValue ?? []).map { p -> JSON in
            guard var o = p.objectValue, let path = p["path"]?.stringValue,
                  let s = workspace.sessions[Workspace.canonical(URL(fileURLWithPath: path))] else { return p }
            o["acquisition"] = .from(s.live.map { Self.stateName($0.state) })
            o["evaluation"] = .string(Self.stateName(s.runner.state))
            return .object(o)
        }
        return [
            "appVersion": .string(ControlServer.appVersion),
            "pid": .int(Int64(getpid())),
            "launchedAt": .from(log.launchedAt),
            "uptimeS": .double((Date().timeIntervalSince(log.launchedAt) * 10).rounded() / 10),
            "memory": memory.map { ["residentBytes": .int(Int64($0.residentBytes)), "footprintBytes": .int(Int64($0.footprintBytes))] } ?? .null,
            "openProjects": .array(projects),
            "activeJobs": status["activeJobs"] ?? [],
            "recentEvents": .array(events.suffix(limit).map(\.json)),
            "recentErrors": .array(events.filter(\.level.isError).suffix(50).map(\.json)),
            "logFile": .string(log.fileURL.path),
            "crashReports": ["since": .from(since), "reports": .array(crashes.map(\.json))],
        ]
    }

    /// The case name only: reasons can carry device or file text.
    static func stateName(_ state: AcquisitionSession.State) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .ready: "ready"
        case .streaming: "streaming"
        case .interrupted: "interrupted"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    static func stateName(_ state: EvaluationRunner.State) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .done: "done"
        case .analysisUnavailable: "analysis_unavailable"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}
