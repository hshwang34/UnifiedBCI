import XCTest
@testable import BCIWorkspace

/// Brief 009: the app log's ring buffer and per-launch file, crash report summaries, the
/// diagnostics export and `app.diagnostics`.
final class DiagnosticsTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static func event(_ i: Int, level: AppLog.Level = .info) -> LogEvent {
        LogEvent(ts: Date(), category: "control", level: level, message: "e\(i)")
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    // MARK: Ring buffer

    func testRingKeepsTheNewestEventsInOrder() {
        var limits = DiagnosticsLog.Limits()
        limits.events = 5
        let log = DiagnosticsLog(directory: scratch, limits: limits)
        for i in 0..<12 { log.append(Self.event(i)) }
        XCTAssertEqual(log.recent().map(\.message), ["e7", "e8", "e9", "e10", "e11"])
        XCTAssertEqual(log.recent(2).map(\.message), ["e10", "e11"])
        XCTAssertEqual(log.recent(0), [])
    }

    func testConcurrentAppendsAreAllKept() {
        let log = DiagnosticsLog(directory: scratch)
        DispatchQueue.concurrentPerform(iterations: 1000) { i in log.append(Self.event(i)) }
        XCTAssertEqual(log.recent().count, 1000)
        XCTAssertEqual(Set(log.recent().map(\.message)).count, 1000)
        log.flush()
        XCTAssertEqual(try lines(log.fileURL).count, 1000, "every event reached the file")
    }

    // MARK: Per-launch file

    func testFileLinesAreJSONAndTheFileIsCapped() throws {
        var limits = DiagnosticsLog.Limits()
        limits.fileBytes = 1000
        let log = DiagnosticsLog(directory: scratch, limits: limits)
        for i in 0..<100 { log.append(Self.event(i, level: .error)) }
        log.flush()
        let written = try lines(log.fileURL)
        XCTAssertLessThan(written.count, 100)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 1000 + 200, "the cap plus one marker line")
        let first = try JSON.parse(written[0])
        XCTAssertEqual(first["message"], "e0")
        XCTAssertEqual(first["level"], "error")
        XCTAssertEqual(first["category"], "control")
        XCTAssertNotNil(first["ts"]?.stringValue)
        XCTAssertTrue(written.last?.contains("log_file_capped") == true)
        XCTAssertEqual(log.recent().count, 100, "the ring keeps going after the file is capped")
    }

    func testOldLaunchFilesAreDeleted() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<12 {
            let name = DiagnosticsLog.fileName(launchedAt: base.addingTimeInterval(Double(i) * 60), pid: 100 + Int32(i))
            FileManager.default.createFile(atPath: scratch.appendingPathComponent(name).path, contents: Data("{}\n".utf8))
        }
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("notes.txt").path, contents: nil)
        let now = base.addingTimeInterval(3600)
        let log = DiagnosticsLog(directory: scratch, launchedAt: now, pid: 999)
        let files = DiagnosticsLog.launchFiles(in: scratch)
        XCTAssertEqual(files.count, 10)
        XCTAssertEqual(files.last, log.fileURL)
        XCTAssertEqual(log.previousFile?.lastPathComponent, DiagnosticsLog.fileName(launchedAt: base.addingTimeInterval(11 * 60), pid: 111))
        XCTAssertEqual(log.previousLaunchAt, base.addingTimeInterval(11 * 60))
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasSuffix("-100.jsonl") }, "the oldest went")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("notes.txt").path), "other files are left alone")
    }

    func testTestsNeverWriteToLibraryLogs() {
        XCTAssertFalse(DiagnosticsLog.defaultDirectory.path.contains("Library/Logs"))
        XCTAssertFalse(DiagnosticsLog.shared.fileURL.path.contains("Library/Logs"))
    }

    func testAppLogKeepsDetailOutOfTheRing() {
        AppLog.error(.store, "diag_test_event", ["code": "x1"], detail: "/Users/someone/secret.bciproj")
        let mine = DiagnosticsLog.shared.recent().last { $0.message.hasPrefix("diag_test_event") }
        XCTAssertEqual(mine?.message, "diag_test_event code=x1")
        XCTAssertEqual(mine?.level, .error)
        XCTAssertEqual(mine?.category, "store")
    }

    // MARK: Crash reports

    private static let ips = #"""
    {"app_name":"BCIWorkspace","timestamp":"2026-11-26 09:08:48.00 -0800","app_version":"0.1.0","bug_type":"309","name":"BCIWorkspace"}
    {"pid":123,"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"indicator":"Segmentation fault: 11"},"faultingThread":1,"usedImages":[{"name":"BCIWorkspace.debug.dylib"},{"name":"libswiftCore.dylib"}],"threads":[{"frames":[{"symbol":"mach_msg","imageIndex":1,"imageOffset":4}]},{"frames":[{"symbol":"swift_getObjectType","imageIndex":1,"imageOffset":10},{"imageIndex":0,"imageOffset":4242},{"symbol":"a3"},{"symbol":"a4"},{"symbol":"a5"},{"symbol":"a6"},{"symbol":"a7"},{"symbol":"a8"},{"symbol":"a9"}]}]}
    """#

    func testCrashReportSummary() {
        let s = CrashReports.summarize(Self.ips, file: "BCIWorkspace-2026-11-26-090848.ips")
        XCTAssertEqual(s.file, "BCIWorkspace-2026-11-26-090848.ips")
        XCTAssertEqual(s.time, "2026-11-26 09:08:48.00 -0800")
        XCTAssertEqual(s.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(s.signal, "SIGSEGV")
        XCTAssertEqual(s.termination, "Segmentation fault: 11")
        XCTAssertEqual(s.appVersion, "0.1.0")
        XCTAssertEqual(s.faultingThread, 1)
        XCTAssertEqual(s.symbols, ["swift_getObjectType", "BCIWorkspace.debug.dylib+4242", "a3", "a4", "a5", "a6", "a7", "a8"],
                       "the faulting thread's first 8 frames; an unsymbolicated frame names its image")
    }

    func testUnreadableCrashReportStillGetsARow() {
        let s = CrashReports.summarize("not json\nnor this", file: "BCIWorkspace-x.ips")
        XCTAssertEqual(s.file, "BCIWorkspace-x.ips")
        XCTAssertNil(s.exceptionType)
        XCTAssertEqual(s.symbols, [])
    }

    func testCrashFilesFilterByNameAndTime() throws {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-3600)
        for name in ["BCIWorkspace-new.ips", "BCIWorkspace-old.ips", "Other-new.ips", "BCIWorkspace-new.txt"] {
            let url = scratch.appendingPathComponent(name)
            try Data(Self.ips.utf8).write(to: url)
            if name.contains("old") { try fm.setAttributes([.modificationDate: old.addingTimeInterval(-60)], ofItemAtPath: url.path) }
        }
        let found = CrashReports.files(in: scratch, since: old).map(\.lastPathComponent)
        XCTAssertEqual(found, ["BCIWorkspace-new.ips"])
        XCTAssertEqual(CrashReports.summaries(in: scratch, since: old).first?.exceptionType, "EXC_BAD_ACCESS")
        let now = Date()
        XCTAssertEqual(CrashReports.cutoff(previousLaunch: nil, now: now), now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(CrashReports.cutoff(previousLaunch: now.addingTimeInterval(-10), now: now), now.addingTimeInterval(-10))
        XCTAssertEqual(CrashReports.cutoff(previousLaunch: now.addingTimeInterval(-30 * 86400), now: now), now.addingTimeInterval(-7 * 86400))
    }

    // MARK: Export

    func testExportWritesTheFolderAndNeverOverwrites() throws {
        let logs = scratch.appendingPathComponent("logs", isDirectory: true)
        let crashes = scratch.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try Data(Self.ips.utf8).write(to: crashes.appendingPathComponent("BCIWorkspace-1.ips"))
        _ = DiagnosticsLog(directory: logs, launchedAt: Date().addingTimeInterval(-600), pid: 1)
        let log = DiagnosticsLog(directory: logs, pid: 2)
        log.append(Self.event(1))
        let out = scratch.appendingPathComponent("BCI Workspace Diagnostics test", isDirectory: true)
        let written = try DiagnosticsExport.write(to: out, log: log, crashDirectory: crashes, agentControlEnabled: true)
        XCTAssertEqual(written.logs.count, 2, "this launch and the previous one")
        XCTAssertEqual(written.crashes, ["BCIWorkspace-1.ips"])
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, ["README.txt", "about.json", "crashes", "logs"])
        let about = try JSON.parse(Data(contentsOf: out.appendingPathComponent("about.json")))
        XCTAssertEqual(about["agentControlEnabled"], true)
        XCTAssertNotNil(about["macOS"]?.stringValue)
        XCTAssertNotNil(about["hardwareModel"]?.stringValue)
        let readme = try String(contentsOf: out.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("No EEG data"))
        XCTAssertTrue(readme.contains("BCIWorkspace-1.ips"))
        XCTAssertThrowsError(try DiagnosticsExport.write(to: out, log: log, crashDirectory: crashes, agentControlEnabled: false)) {
            XCTAssertTrue($0 is DiagnosticsExport.ExportError)
        }
    }

    // MARK: app.diagnostics

    @MainActor
    func testAppDiagnosticsReturnsItsKeys() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bci-tests-diagnostics"))
        let router = ControlRouter(workspace: Workspace(recents: InMemoryRecentDocuments(), launch: nil), settings: ControlSettings(defaults: defaults))
        AppLog.error(.control, "diag_router_test")
        final class Box: @unchecked Sendable { var lines: [ControlMessage] = [] }
        let box = Box()
        let lock = NSLock()
        await router.handle(ControlRequest(id: "d", method: "app.diagnostics", params: ["limit": 5])) { m in lock.withLock { box.lines.append(m) } }
        let r = try XCTUnwrap(lock.withLock { box.lines.last }?.result)
        for key in ["appVersion", "pid", "launchedAt", "uptimeS", "memory", "openProjects", "activeJobs", "recentEvents", "recentErrors", "crashReports", "logFile"] {
            XCTAssertNotNil(r[key], key)
        }
        XCTAssertEqual(r["pid"]?.intValue, Int(getpid()))
        XCTAssertGreaterThan(r["memory"]?["residentBytes"]?.intValue ?? 0, 0)
        XCTAssertLessThanOrEqual(r["recentEvents"]?.arrayValue?.count ?? 99, 5)
        XCTAssertTrue(r["recentErrors"]?.arrayValue?.contains { $0["message"] == "diag_router_test" } == true)
        XCTAssertNotNil(r["crashReports"]?["reports"]?.arrayValue)
    }

    func testLimitMustBeAnInteger() throws {
        let spec = try XCTUnwrap(ControlCatalog.spec("app.diagnostics"))
        XCTAssertEqual(spec.kind, .read)
        XCTAssertEqual(spec.commandWords.group, "app")
        XCTAssertEqual(spec.commandWords.verb, "diagnostics")
        XCTAssertNil(ControlCatalog.validate(spec, nil))
        XCTAssertNil(ControlCatalog.validate(spec, ["limit": 10]))
        XCTAssertNotNil(ControlCatalog.validate(spec, ["limit": "ten"]))
        XCTAssertNotNil(ControlCatalog.validate(spec, ["since": 1]))
    }
}
