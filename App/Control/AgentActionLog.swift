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
        let dir = file.deletingLastPathComponent()
        do {
            // A project may come from anyone: never follow a `logs` link out of it.
            var isDir: ObjCBool = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw UnixSocket.Failure(call: "logs is a symbolic link", errno: ELOOP)
            }
            if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
                guard mkdir(dir.path, 0o755) == 0 || errno == EEXIST else { throw UnixSocket.Failure(call: "mkdir logs", errno: errno) }
            }
            var line = entry.data()
            line.append(0x0A)
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw UnixSocket.Failure(call: "open", errno: errno) }
            defer { Darwin.close(fd) }
            guard UnixSocket.writeAll(fd, line) else { throw UnixSocket.Failure(call: "write", errno: errno) }
        } catch {
            NSLog("BCI Workspace: agent action not logged in %@: %@", project.path, "\(error)")
        }
    }

    /// Result ids an agent's `evaluate.run` produced, for attempt accounting.
    static func agentResultIDs(project: URL) -> Set<String> {
        let file = url(for: project)
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Bounded: a log is small; a huge one is read only up to 16 MB.
        guard let data = try? handle.read(upToCount: 16 << 20) else { return [] }
        var ids: Set<String> = []
        for line in data.split(separator: 0x0A) {
            guard let j = try? JSON.parse(Data(line)), j["method"]?.stringValue == "evaluate.run",
                  let id = j["result"]?.stringValue else { continue }
            ids.insert(id.uppercased())
        }
        return ids
    }
}
