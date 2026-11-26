import Darwin
import Foundation

/// `logs/agent-actions.jsonl` (decision #49): one line per agent call that changes
/// something. It is not provenance, export never copies it, and nothing reads it back.
enum AgentActionLog {
    static func url(for project: URL) -> URL {
        project.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("agent-actions.jsonl")
    }

    /// Appends one line (O_APPEND). A failure is reported to the console only; it never
    /// fails the action it describes.
    static func append(_ entry: JSON, project: URL) {
        let file = url(for: project)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var line = entry.data()
            line.append(0x0A)
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw UnixSocket.Failure(call: "open", errno: errno) }
            defer { Darwin.close(fd) }
            guard UnixSocket.writeAll(fd, line) else { throw UnixSocket.Failure(call: "write", errno: errno) }
        } catch {
            NSLog("BCI Workspace: agent action not logged in %@: %@", project.path, "\(error)")
        }
    }

    /// Result ids an agent's `evaluate.run` produced, for attempt accounting.
    static func agentResultIDs(project: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url(for: project)) else { return [] }
        var ids: Set<String> = []
        for line in data.split(separator: 0x0A) {
            guard let j = try? JSON.parse(Data(line)), j["method"]?.stringValue == "evaluate.run",
                  let id = j["result"]?.stringValue else { continue }
            ids.insert(id.uppercased())
        }
        return ids
    }
}
