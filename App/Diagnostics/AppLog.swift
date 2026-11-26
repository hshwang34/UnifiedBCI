import Foundation
import os
import Synchronization

/// The app's log (brief 009, decision #53): `os.Logger` under one subsystem, plus a ring of
/// recent events kept in memory and appended to a bounded per-launch file in
/// `~/Library/Logs/BCIWorkspace/`. Nothing leaves the Mac.
///
/// Privacy rule: `fields` are the only text that reaches the ring buffer and the file, and
/// they hold ids, states, error codes, counts and durations only. Anything else (paths, error
/// text) goes in `detail`, which only `os.Logger` sees, as `.private`. EEG samples, channel
/// labels, event labels, participant info and project contents are never logged at all.
enum AppLog {
    static let subsystem = "com.hshwang34.BCIWorkspace"

    enum Category: String, CaseIterable, Sendable {
        case control, jobs, evaluation, acquisition, runs, store, ui, app
    }

    enum Level: String, Sendable, Codable {
        case debug, info, notice, error, fault

        var osType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .error: .error
            case .fault: .fault
            }
        }

        var isError: Bool { self == .error || self == .fault }
    }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    /// One event. `event` is a fixed name ("request", "job_state"); `fields` are public.
    static func log(_ level: Level, _ category: Category, _ event: String, _ fields: KeyValuePairs<String, String> = [:], detail: String? = nil) {
        let text = ([event] + fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
        let logger = loggers[category]!
        if let detail {
            logger.log(level: level.osType, "\(text, privacy: .public) \(detail, privacy: .private)")
        } else {
            logger.log(level: level.osType, "\(text, privacy: .public)")
        }
        DiagnosticsLog.shared.append(.init(ts: Date(), category: category.rawValue, level: level, message: text))
    }

    static func info(_ c: Category, _ event: String, _ fields: KeyValuePairs<String, String> = [:], detail: String? = nil) {
        log(.info, c, event, fields, detail: detail)
    }

    static func notice(_ c: Category, _ event: String, _ fields: KeyValuePairs<String, String> = [:], detail: String? = nil) {
        log(.notice, c, event, fields, detail: detail)
    }

    static func error(_ c: Category, _ event: String, _ fields: KeyValuePairs<String, String> = [:], detail: String? = nil) {
        log(.error, c, event, fields, detail: detail)
    }

    /// The type of an error, never its text (which can carry paths or labels).
    static func kind(_ error: Error) -> String { String(describing: type(of: error)) }

    static func ms(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        return String(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// One logged event as the ring buffer and the per-launch file keep it.
struct LogEvent: Sendable, Codable, Equatable {
    var ts: Date
    var category: String
    var level: AppLog.Level
    var message: String

    var json: JSON {
        ["ts": .from(ts), "category": .string(category), "level": .string(level.rawValue), "message": .string(message)]
    }
}

/// The ring buffer and the per-launch JSONL file. Appends are cheap and thread-safe; file
/// writes happen on a private serial queue, never on the caller's thread.
final class DiagnosticsLog: Sendable {
    static let fileExtension = "jsonl"

    struct Limits: Sendable {
        var events = 2000
        var fileBytes = 5 * 1024 * 1024
        /// Launch files kept, this one included.
        var launches = 10
    }

    static let shared = DiagnosticsLog(directory: DiagnosticsLog.defaultDirectory)

    let directory: URL
    let fileURL: URL
    let launchedAt: Date
    let limits: Limits
    /// The previous launch's file, found before older ones were deleted.
    let previousFile: URL?

    private struct State {
        var ring: [LogEvent] = []
        var head = 0
        var bytes = 0
        var capped = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.hshwang34.BCIWorkspace.diagnostics-log")
    private let handle: FileHandle?

    /// `~/Library/Logs/BCIWorkspace/`; under XCTest a temp folder, so tests never write there.
    static var defaultDirectory: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("BCIWorkspace-test-logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BCIWorkspace", isDirectory: true)
    }

    /// `2026-11-26T10-15-30Z-1234.jsonl`: sorts by launch time; no colons in the name.
    static func fileName(launchedAt: Date, pid: Int32) -> String {
        "\(stampFormatter().string(from: launchedAt))-\(pid).\(fileExtension)"
    }

    /// The launch time a file name starts with.
    static func launchDate(ofFile url: URL) -> Date? {
        stampFormatter().date(from: String(url.lastPathComponent.prefix(20)))
    }

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }

    /// When the previous launch started (its file name), for "crashes since the last launch".
    var previousLaunchAt: Date? { previousFile.flatMap(Self.launchDate(ofFile:)) }

    init(directory: URL, limits: Limits = .init(), launchedAt: Date = Date(), pid: Int32 = getpid()) {
        self.directory = directory
        self.limits = limits
        self.launchedAt = launchedAt
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.fileName(launchedAt: launchedAt, pid: pid))
        fileURL = file
        let older = Self.launchFiles(in: directory).filter { $0.lastPathComponent != file.lastPathComponent }
        previousFile = older.last
        // Keep the newest `launches - 1` older files; this launch's file is the last one.
        for url in older.dropLast(max(0, limits.launches - 1)) { try? fm.removeItem(at: url) }
        fm.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
    }

    /// The launch files in `directory`, oldest first.
    static func launchFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix("." + fileExtension) }.sorted().map { directory.appendingPathComponent($0) }
    }

    func append(_ event: LogEvent) {
        var line = event.json.data()
        line.append(0x0A)
        let write: Data? = state.withLock { s in
            if s.ring.count < limits.events { s.ring.append(event) } else {
                s.ring[s.head] = event
                s.head = (s.head + 1) % limits.events
            }
            guard !s.capped else { return nil }
            if s.bytes + line.count > limits.fileBytes {
                s.capped = true
                var marker = LogEvent(ts: event.ts, category: "app", level: .notice, message: "log_file_capped bytes=\(s.bytes)").json.data()
                marker.append(0x0A)
                return marker
            }
            s.bytes += line.count
            return line
        }
        guard let write, let handle else { return }
        queue.async { try? handle.write(contentsOf: write) }
    }

    /// Recent events, oldest first; at most `limit`.
    func recent(_ limit: Int = .max) -> [LogEvent] {
        state.withLock { s in
            let ordered = Array(s.ring[s.head...] + s.ring[..<s.head])
            return Array(ordered.suffix(max(0, limit)))
        }
    }

    /// Waits until queued file writes are done (tests, export).
    func flush() {
        queue.sync {}
        try? handle?.synchronize()
    }
}

/// Resident memory of this process (`task_info`), for `app.diagnostics`.
enum ProcessMemory {
    struct Usage: Sendable { var residentBytes: UInt64; var footprintBytes: UInt64 }

    static func current() -> Usage? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Usage(residentBytes: info.resident_size, footprintBytes: info.phys_footprint)
    }
}
