import Darwin
import Foundation

/// `logs/agent-actions.jsonl` (decision #49): one line per agent call that changes
/// something. It is not provenance, export never copies it, and nothing reads it back.
/// A project may come from anyone, so the log is opened relative to a `logs` directory that
/// is never a link, and it must be a regular file (never a FIFO or device that would block).
enum AgentActionLog {
    static func url(for project: URL) -> URL {
        project.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("agent-actions.jsonl")
    }

    private static let name = "agent-actions.jsonl"

    /// Opens `logs/` with O_NOFOLLOW|O_DIRECTORY (creating it when asked), then the log
    /// inside it non-blocking, refusing anything that isn't a regular file.
    private static func openLog(_ project: URL, write: Bool) throws -> Int32 {
        let dirPath = project.appendingPathComponent("logs").path
        var dir = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dir < 0, errno == ENOENT, write {
            guard mkdir(dirPath, 0o755) == 0 || errno == EEXIST else { throw UnixSocket.Failure(call: "mkdir logs", errno: errno) }
            dir = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dir >= 0 else { throw UnixSocket.Failure(call: "open logs (a link or not a folder?)", errno: errno) }
        defer { Darwin.close(dir) }
        let flags = (write ? O_WRONLY | O_CREAT | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let fd = openat(dir, name, flags, 0o644)
        guard fd >= 0 else { throw UnixSocket.Failure(call: "open \(name)", errno: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw UnixSocket.Failure(call: "\(name) is not a regular file", errno: EINVAL)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return fd
    }

    /// Appends one line (O_APPEND). A failure is reported to the console only; it never
    /// fails the action it describes.
    static func append(_ entry: JSON, project: URL) {
        do {
            var line = entry.data()
            line.append(0x0A)
            let fd = try openLog(project, write: true)
            defer { Darwin.close(fd) }
            guard UnixSocket.writeAll(fd, line) else { throw UnixSocket.Failure(call: "write", errno: errno) }
        } catch {
            NSLog("BCI Workspace: agent action not logged in %@: %@", project.path, "\(error)")
        }
    }

    /// Result ids an agent's `evaluate.run` produced, for attempt accounting.
    static func agentResultIDs(project: URL) -> Set<String> {
        guard let fd = try? openLog(project, write: false) else { return [] }
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
