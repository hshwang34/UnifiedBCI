import AppKit
import Foundation

/// Help ▸ Export Diagnostics… (brief 009, decision #56): one folder with this and the
/// previous launch's log files, recent crash reports, `about.json` and a README. Never EEG
/// data or project files, never an overwrite.
enum DiagnosticsExport {
    struct Written: Sendable, Equatable { var logs: [String]; var crashes: [String] }

    enum ExportError: Error { case alreadyExists }

    static func about(agentControlEnabled: Bool) -> JSON {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appVersion": .string(info["CFBundleShortVersionString"] as? String ?? "dev"),
            "appBuild": .string(info["CFBundleVersion"] as? String ?? "?"),
            "macOS": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "hardwareModel": .string(hardwareModel),
            "agentControlEnabled": .bool(agentControlEnabled),
            "exportedAt": .from(Date()),
        ]
    }

    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "?" }
        return String(cString: bytes)
    }

    /// Writes the folder at `destination`, which must not exist.
    static func write(to destination: URL, log: DiagnosticsLog, crashDirectory: URL = CrashReports.defaultDirectory,
                      agentControlEnabled: Bool, now: Date = Date()) throws -> Written {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ExportError.alreadyExists }
        log.flush()
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var written = Written(logs: [], crashes: [])
        let logs = [log.previousFile, log.fileURL].compactMap { $0 }.filter { fm.fileExists(atPath: $0.path) }
        if !logs.isEmpty {
            let dir = destination.appendingPathComponent("logs", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            for url in logs {
                try fm.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
                written.logs.append(url.lastPathComponent)
            }
        }
        let crashes = CrashReports.files(in: crashDirectory, since: CrashReports.cutoff(previousLaunch: nil, now: now))
        if !crashes.isEmpty {
            let dir = destination.appendingPathComponent("crashes", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            for url in crashes {
                try fm.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
                written.crashes.append(url.lastPathComponent)
            }
        }
        try about(agentControlEnabled: agentControlEnabled).data(pretty: true)
            .write(to: destination.appendingPathComponent("about.json"), options: .withoutOverwriting)
        let readme = DiagnosticsCopy.readme(logs: written.logs, crashes: written.crashes, exportedAt: JSON.from(now).stringValue ?? "")
        try Data(readme.utf8).write(to: destination.appendingPathComponent("README.txt"), options: .withoutOverwriting)
        return written
    }
}

extension Workspace {
    /// Asks where to write the folder, writes it off the main thread, then shows it in Finder.
    func exportDiagnosticsPanel() {
        let panel = NSSavePanel()
        panel.title = DiagnosticsCopy.panelTitle
        panel.message = DiagnosticsCopy.panelMessage
        panel.prompt = DiagnosticsCopy.panelPrompt
        panel.canCreateDirectories = true
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = DiagnosticsCopy.defaultName(stamp: stamp)
        panel.directoryURL = Self.documents
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enabled = ControlSettings.standard.enabled
        AppLog.info(.ui, "export_diagnostics")
        Task {
            let outcome: Result<DiagnosticsExport.Written, Error> = await Task.detached {
                Result { try DiagnosticsExport.write(to: url, log: .shared, agentControlEnabled: enabled) }
            }.value
            switch outcome {
            case .success:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(DiagnosticsExport.ExportError.alreadyExists):
                Self.alert(DiagnosticsCopy.existsTitle, info: DiagnosticsCopy.existsInfo(url.lastPathComponent))
            case .failure(let e):
                AppLog.error(.ui, "export_diagnostics_failed", ["error": AppLog.kind(e)], detail: "\(e)")
                Self.alert(DiagnosticsCopy.failedTitle, info: e.localizedDescription)
            }
        }
    }
}
