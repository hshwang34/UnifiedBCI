import XCTest
@testable import BCIWorkspace

/// Brief 008: the control router over the real store, worker and synthetic board, as an
/// agent drives it. Every call goes through the same session methods the views use.
@MainActor
final class ControlRouterTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!
    private var workspace: Workspace!
    private var router: ControlRouter!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("tiny.bciproj")
        _ = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        let launch = try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
        workspace = Workspace(recents: InMemoryRecentDocuments(), launch: launch)
        defaults = UserDefaults(suiteName: "bci-tests-control")
        defaults.removePersistentDomain(forName: "bci-tests-control")
        router = ControlRouter(workspace: workspace, settings: ControlSettings(defaults: defaults))
    }

    override func tearDown() async throws {
        for url in Array(workspace.sessions.keys) { await workspace.close(url) }
        try? FileManager.default.removeItem(at: scratch)
    }

    /// One call as a client makes it; events are collected.
    private func call(_ method: String, _ params: JSON = [:], async: Bool? = nil) async -> (message: ControlMessage, events: [ControlMessage]) {
        final class Box: @unchecked Sendable { var lines: [ControlMessage] = [] }
        let box = Box()
        let lock = NSLock()
        await router.handle(ControlRequest(id: "t", method: method, params: params, async: async)) { m in lock.withLock { box.lines.append(m) } }
        let lines = lock.withLock { box.lines }
        return (lines.last { !$0.isEvent } ?? .failure("t", ControlError(.internal, "no answer")), lines.filter(\.isEvent))
    }

    private func result(_ method: String, _ params: JSON = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> JSON {
        let (m, _) = await call(method, params)
        if let e = m.error { XCTFail("\(method): \(e)", file: file, line: line) }
        return try XCTUnwrap(m.result, file: file, line: line)
    }

    private var p: JSON { .string(project.path) }

    // MARK: Read, evaluate, freeze, replay, export

    func testOfflineWorkflowEndToEnd() async throws {
        let shown = try await result("project.show", ["project": p])
        XCTAssertEqual(shown["recordings"]?.arrayValue?.count, 1)
        let rec = try XCTUnwrap(shown["recordings"]?.arrayValue?.first?["recordingID"]?.stringValue)
        XCTAssertNotNil(workspace.sessions[Workspace.canonical(project)], "the project is open in the app")

        let verify = try await result("recordings.verify", ["project": p, "recording": .string(rec)])
        XCTAssertEqual(verify["ok"], true)

        let (evaluated, events) = await call("evaluate.run", ["project": p, "recording": .string(rec)])
        let r = try XCTUnwrap(evaluated.result, "\(String(describing: evaluated.error))")
        XCTAssertFalse(events.filter { $0.event == "progress" }.isEmpty, "progress reaches the client")
        let resultID = try XCTUnwrap(r["resultID"]?.stringValue)
        XCTAssertEqual(r["accounting"]?["evaluationsOnRecording"], 1)
        XCTAssertEqual(r["accounting"]?["agentInitiated"], 1, "the action log names the agent's result")
        XCTAssertEqual(r["accounting"]?["heldOutFixedBeforeFitting"], true)
        XCTAssertNotNil(r["evaluation"]?["split_manifest"], "the stored evaluation record comes back as-is")
        XCTAssertEqual(workspace.sessions[Workspace.canonical(project)]?.selectedResultID?.uuidString, resultID, "the window shows the result")

        // Another seed: counted, and flagged as a different split.
        let again = try await result("evaluate.run", ["project": p, "recording": .string(rec), "seed": 7])
        XCTAssertEqual(again["accounting"]?["distinctSeeds"], 2)
        XCTAssertEqual(again["accounting"]?["warnings"], ["several_seeds"])

        let model = try await result("models.freeze", ["project": p, "result": .string(resultID), "name": "agent model"])
        let modelID = try XCTUnwrap(model["modelID"]?.stringValue)
        XCTAssertEqual(model["name"], "agent model")
        XCTAssertNil(workspace.sessions[Workspace.canonical(project)]?.frozen.sheet, "the Freeze sheet closed")

        let replay = try await result("replay.run", ["project": p, "model": .string(modelID), "recording": .string(rec)])
        XCTAssertNotNil(replay["liveRunID"]?.stringValue)

        let destination = scratch.appendingPathComponent("export")
        let exported = try await result("export.result", ["project": p, "result": .string(resultID), "destination": .string(destination.path)])
        XCTAssertEqual(exported["path"]?.stringValue, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("evaluation.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("logs").path), "the agent log is never exported")

        let log = try String(contentsOf: AgentActionLog.url(for: Workspace.canonical(project)), encoding: .utf8)
        let methods = log.split(separator: "\n").compactMap { try? JSON.parse(String($0))["method"]?.stringValue }
        XCTAssertEqual(methods, ["evaluate.run", "evaluate.run", "models.freeze", "replay.run", "export.result"], "reads are not logged")
    }

    func testRefusalsUseTheAppsOwnReasons() async throws {
        let (m, _) = await call("acquisition.record", ["project": p, "seconds": 1])
        XCTAssertEqual(m.error?.code, "refused")
        XCTAssertEqual(m.error?.data?["reason"]?.stringValue, RecordGate.notStreaming)

        let unknown = await call("evaluate.run", ["project": p, "recording": .string(UUID().uuidString)])
        XCTAssertEqual(unknown.message.error?.code, "not_found")

        let typo = await call("evaluate.run", ["project": p, "recordng": "x"])
        XCTAssertEqual(typo.message.error?.code, "bad_request")

        let missing = await call("project.show", ["project": .string(scratch.appendingPathComponent("none.bciproj").path)])
        XCTAssertEqual(missing.message.error?.code, "not_found")

        let session = try await workspace.session(for: project)
        session.presentGuidePicker()
        let busy = await call("evaluate.run", ["project": p, "recording": .string(session.recordings[0].id.uuidString)])
        XCTAssertEqual(busy.message.error?.code, "ui_busy", "never acts under a sheet the person has open")
    }

    func testAsyncJobsCanBeWaitedOnAndCancelled() async throws {
        let shown = try await result("project.show", ["project": p])
        let rec = try XCTUnwrap(shown["recordings"]?.arrayValue?.first?["recordingID"])
        let started = await call("evaluate.run", ["project": p, "recording": rec], async: true)
        let job = try XCTUnwrap(started.message.result?["job"]?.stringValue)
        XCTAssertEqual(started.message.result?["state"], "running")
        _ = try await result("jobs.cancel", ["job": .string(job)])
        let status = try await result("jobs.wait", ["job": .string(job), "timeoutS": 60])
        XCTAssertTrue(["cancelled", "done"].contains(status["state"]?.stringValue ?? ""), "\(status)")
        let listed = try await result("jobs.list")
        XCTAssertEqual(listed["jobs"]?.arrayValue?.first?["job"]?.stringValue, job)
    }

    // MARK: Acquisition (synthetic board; decision #26: no hardware in tests)

    func testSyntheticConnectRecordAndDisconnect() async throws {
        let bad = await call("acquisition.connect", ["project": p, "source": "synthetic", "map": "declared"])
        XCTAssertEqual(bad.message.error?.code, "refused", "synthetic declares no map; never guessed")

        let connected = try await result("acquisition.connect", ["project": p, "source": "synthetic", "map": "undeclared"])
        XCTAssertEqual(connected["state"], "streaming")
        XCTAssertEqual(connected["map"], "undeclared")
        XCTAssertEqual(connected["simulated"], true)

        let twice = await call("acquisition.connect", ["project": p, "source": "synthetic", "map": "undeclared"])
        XCTAssertEqual(twice.message.error?.code, "refused")

        let recorded = try await result("acquisition.record", ["project": p, "seconds": 2])
        let id = try XCTUnwrap(recorded["recordingID"]?.stringValue)
        let list = try await result("recordings.list", ["project": p])
        XCTAssertTrue(list["recordings"]?.arrayValue?.contains { $0["recordingID"]?.stringValue == id } ?? false)

        let done = try await result("acquisition.disconnect", ["project": p])
        XCTAssertEqual(done["state"], "disconnected")
    }

    func testAgentOperatorIsRefusedWithoutASimulatedSource() async throws {
        let (m, _) = await call("protocol.run", ["project": p, "protocol": .string(UUID().uuidString), "operator": "agent"])
        XCTAssertEqual(m.error?.code, "refused", "nothing streams, so nothing runs")
        XCTAssertNil(workspace.sessions[Workspace.canonical(project)]?.runs)
    }

    func testOperatorRequestWaitsForThePerson() async throws {
        _ = try await workspace.session(for: project)
        let started = await call("operator.request", ["project": p, "message": "Check the cap"], async: true)
        let job = try XCTUnwrap(started.message.result?["job"]?.stringValue)
        var waiting = try await result("jobs.wait", ["job": .string(job), "timeoutS": 5])
        XCTAssertEqual(waiting["state"], "awaiting_operator")
        XCTAssertEqual(waiting["prompt"], "Check the cap")
        let prompt = try XCTUnwrap(AgentActivity.shared.prompts(for: Workspace.canonical(project)).first)
        XCTAssertTrue(prompt.asks)
        AgentActivity.shared.answer(prompt.id, true)          // the person presses Confirm
        waiting = try await result("jobs.wait", ["job": .string(job), "timeoutS": 5])
        XCTAssertEqual(waiting["state"], "done")
        XCTAssertEqual(waiting["result"]?["confirmed"], true)
    }
}
