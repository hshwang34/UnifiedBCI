import XCTest
@testable import BCIWorkspace

/// Brief 002 PR 3: `inspect_recording` through the real worker on tiny.bciproj, and the
/// runner's failure split, cancel and per-session cache with stand-in workers.
@MainActor
final class InspectionRunnerTests: XCTestCase {
    private var scratch: URL!
    private var projectDir: URL!
    private var recordingID: UUID!
    private var runner: InspectionRunner?

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        projectDir = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: projectDir)
        let ids = try await store.recordingIDs()
        recordingID = try XCTUnwrap(ids.first)
    }

    override func tearDown() async throws {
        await runner?.shutdown()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func realLaunch() throws -> WorkerLaunch {
        try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
    }

    private func makeRunner(_ launch: WorkerLaunch? = nil, timeout: Duration = .seconds(120)) throws -> InspectionRunner {
        let r = InspectionRunner(projectDirectory: projectDir, launch: try launch ?? realLaunch(), callTimeout: timeout)
        runner = r
        return r
    }

    private func fakeLaunch(_ body: String) throws -> WorkerLaunch {
        let real = try realLaunch()
        let dir = scratch.appendingPathComponent("fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake_worker.py")
        try (Self.prologue + body).write(to: url, atomically: true, encoding: .utf8)
        return WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(url))
    }

    private static let prologue = """
    import os, sys, json, time
    def out(o):
        sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
    out({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": ["inspect_recording"]}})
    def requests():
        for line in sys.stdin:
            if line.strip():
                yield json.loads(line)

    """

    private func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Real worker

    func testWorkerClient_inspectRecordingOnTinyFixture() async throws {
        let client = WorkerClient(launch: try realLaunch())
        let hello = try await client.start()
        defer { Task { await client.shutdown() } }
        XCTAssertTrue(hello.methods.contains("inspect_recording"))
        let data = try await client.call("inspect_recording", params: [
            "project_dir": .string(projectDir.path), "recording_id": .string(recordingID.uuidString),
        ], timeout: .seconds(60))
        let report = try InspectionReport.decode(data)
        XCTAssertEqual(report.rules.map(\.id), ["flatline", "pinned", "large_deflection", "mains_line", "outlier_amplitude", "outlier_high_frequency"])
        XCTAssertEqual(report.segments.count, 3)
        XCTAssertEqual(report.segments.map { $0.channels.count }, [8, 8, 8])
        // The committed fixture is this same response (worker test keeps it current).
        XCTAssertEqual(report.segments.map(\.runId), try QualityModelTests.fixture("inspect_recording_tiny").segments.map(\.runId))
        let unreadable = await expectWorkerError {
            _ = try await client.call("inspect_recording", params: ["project_dir": .string(self.projectDir.path), "recording_id": "not-a-uuid"])
        }
        XCTAssertEqual(unreadable, "bad_request")
    }

    func testInspect_reportsSegmentProgressCachesAndWritesNothing() async throws {
        let before = try Self.listing(projectDir)
        let runner = try makeRunner()
        let final = await runner.inspectAndWait(recordingID: recordingID)
        XCTAssertEqual(final, .done(recordingID: recordingID))
        XCTAssertEqual(runner.progressLog.first, .starting)
        XCTAssertTrue(runner.progressLog.contains(.loading))
        XCTAssertEqual(runner.progressLog.filter { if case .segment = $0 { true } else { false } },
                       [.segment(1, of: 3), .segment(2, of: 3), .segment(3, of: 3)])
        let fractions = runner.progressLog.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        let report = try XCTUnwrap(runner.report(for: recordingID))
        XCTAssertEqual(report.segments.count, 3)
        XCTAssertEqual(try Self.listing(projectDir), before, "inspection writes nothing into the project")

        // Cached: a second inspect answers at once, without a new run.
        runner.inspect(recordingID: recordingID)
        XCTAssertEqual(runner.state, .done(recordingID: recordingID))
        XCTAssertFalse(runner.isBusy)
    }

    func testUnknownRecording_isRefusedNotUnavailable() async throws {
        let runner = try makeRunner()
        guard case .failed(let reason) = await runner.inspectAndWait(recordingID: UUID()) else { return XCTFail("\(runner.state)") }
        XCTAssertTrue(reason.contains("bad_request"), reason)
        XCTAssertNil(runner.report(for: recordingID))
    }

    // MARK: Stand-in workers

    func testCancel_endsCancelledCachesNothingAndRunsAgain() async throws {
        let runner = try makeRunner(try fakeLaunch("""
        for req in requests():
            if req["method"] == "inspect_recording":
                out({"v": 1, "event": "progress", "id": req["id"], "data": {"stage": "inspect", "segment": 1, "of": 3}})
            elif req["method"] == "cancel":
                out({"v": 1, "id": req["id"], "ok": True, "result": {"cancelled": True}})
                out({"v": 1, "id": req["params"]["id"], "ok": False, "error": {"code": "cancelled", "message": "request was cancelled"}})
            elif req["method"] == "shutdown":
                out({"v": 1, "id": req["id"], "ok": True, "result": {}})
                break
        """))
        for attempt in 0..<2 {
            if attempt == 0 { runner.inspect(recordingID: recordingID) } else { runner.retry() }
            await waitUntil { runner.progressLog.contains(.segment(1, of: 3)) }
            XCTAssertEqual(runner.state, .running(recordingID: recordingID, .segment(1, of: 3)), "attempt \(attempt)")
            let final = await runner.cancelAndWait()
            XCTAssertEqual(final, .cancelled, "attempt \(attempt)")
            XCTAssertNil(runner.report(for: recordingID))
        }
    }

    func testWorkerDeath_isAnalysisUnavailable_andRetryUsesAFreshWorker() async throws {
        let marker = scratch.appendingPathComponent("died-once")
        let runner = try makeRunner(try fakeLaunch("""
        marker = \(String(reflecting: marker.path))
        for req in requests():
            if req["method"] == "inspect_recording":
                if not os.path.exists(marker):
                    open(marker, "w").close()
                    os._exit(3)
                out({"v": 1, "id": req["id"], "ok": True, "result": {"rules": [], "segments": []}})
            elif req["method"] == "shutdown":
                break
        """))
        guard case .analysisUnavailable = await runner.inspectAndWait(recordingID: recordingID) else { return XCTFail("\(runner.state)") }
        runner.retry()
        await waitUntil { !runner.isBusy }
        XCTAssertEqual(runner.state, .done(recordingID: recordingID))
        XCTAssertEqual(runner.report(for: recordingID)?.segments, [])
    }

    func testIntegrityError_isFailed() async throws {
        let runner = try makeRunner(try fakeLaunch("""
        for req in requests():
            if req["method"] == "inspect_recording":
                out({"v": 1, "id": req["id"], "ok": False, "error": {"code": "integrity", "message": "chunk 3 does not match"}})
            elif req["method"] == "shutdown":
                break
        """))
        let final = await runner.inspectAndWait(recordingID: recordingID)
        XCTAssertEqual(final, .failed(reason: "worker error integrity: chunk 3 does not match"))
    }

    func testHungWorker_timesOutAsAnalysisUnavailable() async throws {
        let runner = try makeRunner(try fakeLaunch("""
        for req in requests():
            if req["method"] == "shutdown":
                break
        """), timeout: .milliseconds(500))
        guard case .analysisUnavailable = await runner.inspectAndWait(recordingID: recordingID) else { return XCTFail("\(runner.state)") }
    }

    func testNoWorker_isAnalysisUnavailable() async throws {
        let r = InspectionRunner(projectDirectory: projectDir, launch: nil)
        guard case .analysisUnavailable = await r.inspectAndWait(recordingID: recordingID) else { return XCTFail("\(r.state)") }
    }

    func testLateProgressForAnotherRequest_isIgnored() async throws {
        let r = InspectionRunner(projectDirectory: projectDir, launch: nil)
        r.handle(WorkerEvent(name: "progress", requestID: "other", data: Data(#"{"stage":"loading"}"#.utf8)))
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.progressLog, [])
    }

    // MARK: Helpers

    private func expectWorkerError(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let e as WorkerError { return e.code } catch { return "\(error)" }
    }

    private static func listing(_ dir: URL) throws -> [String] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        return try (e?.allObjects as? [URL] ?? []).map {
            let date = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return "\($0.path):\(date?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }
}
