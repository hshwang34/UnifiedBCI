import XCTest
@testable import BCIWorkspace

final class WorkerClientTests: XCTestCase {
    private func realLaunch() throws -> WorkerLaunch {
        try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
    }

    private func makeClient() throws -> WorkerClient {
        WorkerClient(launch: try realLaunch())
    }

    /// A stand-in worker: the dev venv's interpreter running a throwaway script.
    private func fakeClient(_ script: String) throws -> WorkerClient {
        let real = try realLaunch()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bci-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake_worker.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return WorkerClient(launch: WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(url)))
    }

    private static let fakePrelude = """
    import sys, json, time
    def ready(protocol=1):
        print(json.dumps({"v": 1, "event": "ready", "id": None, "data": {"protocol": protocol, "pid": 1, "versions": {}, "methods": ["ping"]}}), flush=True)
    def reply(req, result):
        print(json.dumps({"v": 1, "id": req["id"], "ok": True, "result": result}), flush=True)
    def requests():
        for line in sys.stdin:
            if line.strip():
                yield json.loads(line)

    """

    private func expectError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected worker error \(code)", file: file, line: line)
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("expected WorkerError \(code), got \(error)", file: file, line: line)
        }
    }

    private func waitForExit(_ client: WorkerClient, seconds: Double = 5) async -> WorkerClient.State {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .exited = await client.state { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await client.state
    }

    // MARK: Real worker

    func testStartAnnouncesProtocolAndPinnedDependencies() async throws {
        let client = try makeClient()
        let hello = try await client.start()
        defer { Task { await client.shutdown() } }
        XCTAssertEqual(hello.protocol, WorkerProtocol.version)
        XCTAssertNotEqual(hello.versions["brainflow"], "missing")
        XCTAssertNotEqual(hello.versions["scikit-learn"], "missing")
        XCTAssertNil(hello.versions["mne"], "MNE is a dev dependency only; the worker must not report it")
        XCTAssertTrue(hello.methods.contains("fit_evaluate_synthetic"))
        XCTAssertTrue(hello.methods.contains("cancel"))
        let brainflowSwift = try BrainFlowBoard.libraryVersion()
        XCTAssertEqual(hello.versions["brainflow"], brainflowSwift, "worker and bridge must share one BrainFlow build")
    }

    func testPingRoundTripAndUnknownMethodError() async throws {
        let client = try makeClient()
        _ = try await client.start()
        struct Pong: Decodable { let pong: Bool; let echo: String? }
        let pong = try await client.call("ping", params: ["echo": "x"], as: Pong.self)
        XCTAssertTrue(pong.pong)
        XCTAssertEqual(pong.echo, "x")
        await expectError("unknown_method") { _ = try await client.call("does_not_exist") }
        await client.shutdown()
        guard case .exited(let status) = await waitForExit(client) else { return XCTFail("worker should have exited after shutdown") }
        XCTAssertEqual(status, 0)
    }

    func testFitEvaluateSyntheticReturnsGroupedSplitRecord() async throws {
        let client = try makeClient()
        _ = try await client.start()
        defer { Task { await client.shutdown() } }

        let data = try await client.call("fit_evaluate_synthetic", params: ["seed": 1, "n_runs": 4, "trials_per_run": 6, "n_channels": 8])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let split = try XCTUnwrap(obj["split_policy"] as? [String: Any])
        XCTAssertEqual(split["grouping"] as? String, "run")
        XCTAssertEqual(split["unit"] as? String, "trial")
        let manifest = try XCTUnwrap(obj["split_manifest"] as? [String: Any])
        let holdout = try XCTUnwrap(manifest["holdout_runs"] as? [String])
        let training = try XCTUnwrap(manifest["training_runs"] as? [String])
        XCTAssertTrue(Set(holdout).isDisjoint(with: training))
        let models = try XCTUnwrap(obj["models"] as? [String: Any])
        XCTAssertNotNil(models["reference_csp_rlda"])
        XCTAssertNotNil(models["baseline_logvar_rlda"])
        XCTAssertNotNil(obj["comparison"])
        XCTAssertEqual((obj["data_source"] as? [String: Any])?["kind"] as? String, "synthetic")
    }

    func testCancelDuringFitFailsTheCallWithCancelled() async throws {
        let client = try makeClient()
        _ = try await client.start()
        defer { Task { await client.shutdown() } }

        let fit = Task {
            try await client.call("fit_evaluate_synthetic",
                                  params: ["seed": 2, "n_runs": 8, "trials_per_run": 30, "n_channels": 16],
                                  requestID: "fit-under-test")
        }
        var sawProgress = false
        for await ev in client.events where ev.name == "progress" && ev.requestID == "fit-under-test" {
            sawProgress = true
            break
        }
        XCTAssertTrue(sawProgress)
        let found = try await client.cancel(requestID: "fit-under-test")
        XCTAssertTrue(found)
        await expectError("cancelled") { _ = try await fit.value }
        // The worker is still healthy afterwards.
        struct Pong: Decodable { let pong: Bool }
        let pong = try await client.call("ping", as: Pong.self)
        XCTAssertTrue(pong.pong)
    }

    func testNaNParameterIsAThrownErrorNotACrash() async throws {
        let client = try makeClient()
        _ = try await client.start()
        defer { Task { await client.shutdown() } }
        do {
            _ = try await client.call("ping", params: ["echo": .double(.nan)])
            XCTFail("expected an encoding error")
        } catch is EncodingError {
            // expected
        }
    }

    // MARK: Fault injection with a fake worker

    func testStdoutNoiseAroundProtocolLinesIsIgnored() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        print("Computing rank from data with rank=None")
        print("    Using tolerance 0.041 (2.2e-16 eps * 4 dim)")
        ready()
        print("Estimated rank (data): 4")
        for req in requests():
            print("noise before")
            if req["method"] == "ping":
                reply(req, {"pong": True})
            print("noise after", flush=True)
            if req["method"] == "shutdown":
                reply(req, {"bye": True}); break
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        struct Pong: Decodable { let pong: Bool }
        let pong = try await client.call("ping", as: Pong.self)
        XCTAssertTrue(pong.pong)
        await client.shutdown()
    }

    func testProtocolMismatchFailsStartInsteadOfHanging() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        ready(protocol=2)
        time.sleep(30)
        """)
        await expectError("protocol_mismatch") { _ = try await client.start(readyTimeout: .seconds(10)) }
        guard case .exited = await waitForExit(client) else { return XCTFail("mismatched worker must be terminated") }
    }

    func testLargeResultIsReassembledInOrder() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        ready()
        for req in requests():
            if req["method"] == "big":
                n = req["params"]["n"]
                reply(req, {"blob": "".join(chr(97 + (i % 26)) for i in range(n)), "n": n})
            elif req["method"] == "shutdown":
                reply(req, {"bye": True}); break
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        struct Big: Decodable { let blob: String; let n: Int }
        let n = 1_500_000
        let big = try await client.call("big", params: ["n": .int(n)], timeout: .seconds(30), as: Big.self)
        XCTAssertEqual(big.n, n)
        XCTAssertEqual(big.blob.count, n)
        let expected = String((0..<n).map { Character(UnicodeScalar(97 + ($0 % 26))!) })
        XCTAssertEqual(big.blob, expected, "bytes arrived out of order or were dropped")
        await client.shutdown()
    }

    func testResultBytesArePassedThroughVerbatim() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        ready()
        for req in requests():
            if req["method"] == "raw":
                sys.stdout.write('{"v":1,"id":"%s","ok":true,"result":{"b":1.50,"a":"x}y{","nested":[1,{"k":"]"}]}}\\n' % req["id"]); sys.stdout.flush()
            elif req["method"] == "shutdown":
                reply(req, {"bye": True}); break
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        let data = try await client.call("raw")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"b\":1.50,\"a\":\"x}y{\",\"nested\":[1,{\"k\":\"]\"}]}")
        await client.shutdown()
    }

    func testWorkerKilledMidCallFailsWithWorkerExited() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        import os
        ready()
        for req in requests():
            if req["method"] == "pid":
                reply(req, {"pid": os.getpid()})
            elif req["method"] == "hang":
                time.sleep(60)
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        struct Pid: Decodable { let pid: Int32 }
        let pid = try await client.call("pid", as: Pid.self).pid
        let hang = Task { try await client.call("hang") }
        try await Task.sleep(for: .milliseconds(200))
        kill(pid, SIGKILL)
        await expectError("worker_exited") { _ = try await hang.value }
        guard case .exited(let status) = await waitForExit(client) else { return XCTFail("state must reflect the exit") }
        XCTAssertNotEqual(status, 0)
        await expectError("bad_state") { _ = try await client.call("ping") }
    }

    func testFinalResponseBeforeExitIsDelivered() async throws {
        // The worker answers and exits immediately; `didExit` must wait for pipe EOF so the
        // answer is not discarded in favour of a `worker_exited` error.
        let client = try fakeClient(Self.fakePrelude + """
        ready()
        for req in requests():
            reply(req, {"last": True}); break
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        struct Last: Decodable { let last: Bool }
        let last = try await client.call("anything", as: Last.self)
        XCTAssertTrue(last.last)
        guard case .exited(0) = await waitForExit(client) else { return XCTFail("expected clean exit") }
    }

    func testReadyTimeoutFiresAndTerminatesSlowWorker() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        time.sleep(20)
        ready()
        """)
        let t0 = Date()
        await expectError("ready_timeout") { _ = try await client.start(readyTimeout: .milliseconds(700)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "timeout must fire promptly, not after the script finishes")
        guard case .exited = await waitForExit(client) else { return XCTFail("slow worker must be terminated") }
    }

    func testPerCallTimeoutFailsTheCallAndSendsCancel() async throws {
        let client = try fakeClient(Self.fakePrelude + """
        ready()
        seen = []
        for req in requests():
            seen.append(req["method"])
            if req["method"] == "cancel":
                reply(req, {"cancelled": True})
            elif req["method"] == "seen":
                reply(req, {"seen": seen})
            elif req["method"] == "shutdown":
                reply(req, {"bye": True}); break
        """)
        _ = try await client.start(readyTimeout: .seconds(10))
        await expectError("timeout") { _ = try await client.call("never_answered", timeout: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(300))
        struct Seen: Decodable { let seen: [String] }
        let seen = try await client.call("seen", as: Seen.self).seen
        XCTAssertTrue(seen.contains("cancel"), "a timed-out call must ask the worker to cancel: \(seen)")
        await client.shutdown()
    }

    // MARK: Launch configuration

    func testLaunchScrubsInheritedPythonEnvironment() {
        let dev = WorkerLaunch(origin: .developmentVenv, python: URL(fileURLWithPath: "/v/bin/python"), pythonPath: nil, workingDirectory: URL(fileURLWithPath: "/v"))
        let env = dev.environment(inheriting: ["PYTHONHOME": "/usr", "PYTHONPATH": "/evil", "VIRTUAL_ENV": "/x", "PYTHONSTARTUP": "/s", "PYTHONUSERBASE": "/u",
                                               "PYTHONINSPECT": "1", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "DYLD_LIBRARY_PATH": "/evil", "HOME": "/h"])
        for key in ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONINSPECT", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"] { XCTAssertNil(env[key], key) }
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(env["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(env["OMP_NUM_THREADS"], "1")
        XCTAssertEqual(dev.arguments, ["-I", "-u", "-B", "-X", "utf8", "-m", "bciworkspace_worker"])

        let bundled = WorkerLaunch(origin: .bundled, python: URL(fileURLWithPath: "/b/python/bin/python3"), pythonPath: "/b/site", workingDirectory: URL(fileURLWithPath: "/b"))
        let benv = bundled.environment(inheriting: ["PYTHONPATH": "/evil"])
        XCTAssertEqual(benv["PYTHONPATH"], "/b/site", "bundled worker needs exactly our site dir, never the inherited one")
        XCTAssertEqual(bundled.arguments.prefix(2), ["-s", "-P"], "-I would discard PYTHONPATH, so the bundled case uses -s -P")
    }

    func testJSONLineScannerExtractsVerbatimValues() {
        let line = Data("{\"v\":1, \"id\":\"7\",\"ok\":true,\"result\": {\"s\":\"a\\\"}b\",\"arr\":[1,2,{\"x\":null}],\"n\":-1.0e3} ,\"tail\":\"}\"}".utf8)
        XCTAssertEqual(JSONLineScanner.topLevelValue(for: "result", in: line).map { String(decoding: $0, as: UTF8.self) },
                       "{\"s\":\"a\\\"}b\",\"arr\":[1,2,{\"x\":null}],\"n\":-1.0e3}")
        XCTAssertEqual(JSONLineScanner.topLevelValue(for: "id", in: line).map { String(decoding: $0, as: UTF8.self) }, "\"7\"")
        XCTAssertEqual(JSONLineScanner.topLevelValue(for: "ok", in: line).map { String(decoding: $0, as: UTF8.self) }, "true")
        XCTAssertEqual(JSONLineScanner.topLevelValue(for: "tail", in: line).map { String(decoding: $0, as: UTF8.self) }, "\"}\"")
        XCTAssertNil(JSONLineScanner.topLevelValue(for: "missing", in: line))
        XCTAssertNil(JSONLineScanner.topLevelValue(for: "result", in: Data("[1,2]".utf8)))
    }
}
