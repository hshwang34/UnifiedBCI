import XCTest
@testable import BCIWorkspace

/// Criteria 5, 6, 7 and 9 of the 001 test plan: the whole data path from a project on
/// disk through the real worker to a stored, exported result.
@MainActor
final class EvaluationRunnerTests: XCTestCase {
    private var scratch: URL!
    private var store: ProjectStore!
    private var recordingID: UUID!
    private var runner: EvaluationRunner?

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: scratch.appendingPathComponent("tiny.bciproj"))
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

    private func makeRunner(launch: WorkerLaunch? = nil, silence: Duration = .seconds(120)) throws -> EvaluationRunner {
        let r = EvaluationRunner(store: store, launch: try launch ?? realLaunch(), progressSilenceTimeout: silence)
        runner = r
        return r
    }

    /// F2: a stand-in worker script run by the dev venv's interpreter.
    private func fakeLaunch(_ script: String) throws -> WorkerLaunch {
        let real = try realLaunch()
        let dir = scratch.appendingPathComponent("fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake_worker.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(url))
    }

    private func evaluation(_ id: UUID) async throws -> [String: Any] {
        let stored = try await store.result(id: id)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: stored.evaluationJSON) as? [String: Any])
    }

    // MARK: Progress and result

    func testEvaluate_emitsMonotonicProgressThenResult() async throws {
        let runner = try makeRunner()
        let final = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .done(let id) = final else { return XCTFail("\(final)") }
        let log = runner.progressLog
        XCTAssertEqual(log.first, .starting)
        XCTAssertTrue(log.contains(.loading))
        XCTAssertTrue(log.contains { if case .fitting = $0 { return true } else { return false } })
        XCTAssertTrue(log.contains { if case .holdout = $0 { return true } else { return false } })
        XCTAssertEqual(log.last, .storing)
        let fractions = log.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must never go backwards: \(log.map(\.label))")
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
        // Each stage the brief names was reported at least once.
        let labels = log.map(\.label)
        XCTAssertTrue(labels.contains("loading"))
        XCTAssertTrue(labels.contains("fit:reference_csp_rlda:fold 1/2"), "\(labels)")
        XCTAssertTrue(labels.contains("holdout:baseline_logvar_rlda"), "\(labels)")
        let results = try await store.results()
        XCTAssertEqual(results.map(\.resultID), [id])
    }

    func testResult_containsAllRequiredFields() async throws {
        let runner = try makeRunner()
        guard case .done(let id) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0)) else { return XCTFail() }
        let stored = try await store.result(id: id)
        let ev = try await evaluation(id)
        let split = try XCTUnwrap(ev["split_policy"] as? [String: Any])
        XCTAssertEqual(split["grouping"] as? String, "run")
        XCTAssertEqual(split["unit"] as? String, "trial")
        XCTAssertEqual(split["evidence"] as? String, "unknown-session", "the dataset defines no session, so same-session may not be claimed")
        XCTAssertEqual(split["seed"] as? Int, 0)
        let models = try XCTUnwrap(ev["models"] as? [String: Any])
        for name in ["reference_csp_rlda", "baseline_logvar_rlda"] {
            let holdout = try XCTUnwrap((models[name] as? [String: Any])?["holdout"] as? [String: Any], name)
            let acc = try XCTUnwrap(holdout["accuracy"] as? Double)
            let bal = try XCTUnwrap(holdout["balanced_accuracy"] as? Double)
            let ci = try XCTUnwrap(holdout["accuracy_ci95"] as? [Double])
            let n = try XCTUnwrap(holdout["n_test_trials"] as? Int)
            let confusion = try XCTUnwrap(holdout["confusion_matrix"] as? [[Int]])
            XCTAssertTrue(ci[0] <= acc && acc <= ci[1], "\(name): \(ci) around \(acc)")
            XCTAssertTrue((0...1).contains(bal))
            XCTAssertGreaterThan(n, 0)
            XCTAssertEqual(confusion.flatMap { $0 }.reduce(0, +), n)
            XCTAssertNotNil(holdout["per_run"])
        }
        XCTAssertNotNil(ev["class_counts"])
        XCTAssertNotNil(ev["exclusions"])
        XCTAssertNotNil(ev["comparison"])
        XCTAssertNotNil(ev["split_manifest"])
        let source = try XCTUnwrap(ev["data_source"] as? [String: Any])
        XCTAssertEqual(source["kind"] as? String, "public_dataset")
        XCTAssertTrue((source["warning"] as? String)?.contains("not recorded on OpenBCI") ?? false)
        // Pipeline record and meta.
        XCTAssertEqual(stored.pipeline.recipe, "csp_rlda_v1")
        XCTAssertEqual(stored.pipeline.expectedChannelIDs.count, 8)
        XCTAssertEqual(stored.pipeline.expectedSampleRateHz, 160)
        XCTAssertEqual(stored.pipeline.trainingRecordingIDs, [recordingID])
        XCTAssertEqual(stored.pipeline.fittedParametersFile, "fitted.npz")
        XCTAssertEqual(stored.pipeline.configHash.count, 64)
        XCTAssertNotEqual(stored.pipeline.dependencyVersions["numpy"], nil)
        XCTAssertEqual(stored.meta.recordingID, recordingID)
        XCTAssertNil(stored.meta.reproductionOf)
        XCTAssertNotNil(stored.meta.durationsSeconds["total"])
        XCTAssertNotNil(stored.meta.durationsSeconds["fit"], "worker stage timings arrive via the done event: \(stored.meta.durationsSeconds)")
        XCTAssertEqual(stored.meta.workerOrigin, "development_venv")
        XCTAssertEqual(stored.meta.evaluationSHA256, AtomicFile.sha256Hex(stored.evaluationJSON))
        XCTAssertFalse(String(decoding: stored.evaluationJSON, as: UTF8.self).contains("elapsed"), "timing must not be in evaluation.json")
    }

    // MARK: Reproduction

    func testRerunSameSeed_storesReproductionLinkedToOriginal() async throws {
        let runner = try makeRunner()
        guard case .done(let first) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 5)) else { return XCTFail() }
        guard case .done(let second) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 5)) else { return XCTFail() }
        XCTAssertNotEqual(first, second)
        let a = try await store.result(id: first), b = try await store.result(id: second)
        XCTAssertEqual(a.evaluationJSON, b.evaluationJSON, "same recording, config and seed must be byte-identical")
        XCTAssertEqual(b.meta.reproductionOf, first)
        XCTAssertNil(b.meta.divergedFrom)
        XCTAssertNil(a.meta.reproductionOf)
        XCTAssertEqual(a.meta.configHash, b.meta.configHash)
        XCTAssertNotEqual(a.pipeline.pipelineID, b.pipeline.pipelineID, "each run keeps its own fitted arrays")
        // A third run links to the root original, not to the reproduction.
        guard case .done(let third) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 5)) else { return XCTFail() }
        let c = try await store.result(id: third)
        XCTAssertEqual(c.meta.reproductionOf, first)
        let listed = try await store.results().map(\.resultID)
        XCTAssertEqual(listed, [first, second, third])
    }

    func testNewSeed_addsSecondResultAndBothListed() async throws {
        let runner = try makeRunner()
        guard case .done(let first) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 1)) else { return XCTFail() }
        guard case .done(let second) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 2)) else { return XCTFail() }
        let a = try await store.result(id: first), b = try await store.result(id: second)
        XCTAssertNotEqual(a.evaluationJSON, b.evaluationJSON)
        XCTAssertNil(b.meta.reproductionOf)
        XCTAssertNil(b.meta.divergedFrom)
        XCTAssertEqual(b.meta.seed, 2)
        let listed = try await store.results().map(\.resultID)
        XCTAssertEqual(listed, [first, second])
        let reopened = try ProjectStore.open(at: store.directory)
        let afterReopen = try await reopened.results().map(\.resultID)
        XCTAssertEqual(afterReopen, [first, second], "results come from the directory scan, not from memory")
    }

    // MARK: Worker death

    func testWorkerExitDuringEvaluate_surfacesUnavailableAndRetrySucceeds() async throws {
        // Dies on the first request of its first launch; on the next launch it becomes the
        // real worker, so the retry exercises the complete path.
        let launch = try fakeLaunch("""
        import os, sys, json, pathlib
        marker = pathlib.Path(sys.argv[0]).with_suffix(".died")
        if not marker.exists():
            marker.write_text("1")
            print(json.dumps({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": ["fit_evaluate_project"]}}), flush=True)
            for line in sys.stdin:
                if line.strip():
                    os._exit(3)
        else:
            os.execv(sys.executable, [sys.executable, "-I", "-u", "-B", "-X", "utf8", "-m", "bciworkspace_worker"])
        """)
        let runner = try makeRunner(launch: launch)
        let first = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .analysisUnavailable(let reason) = first else { return XCTFail("expected analysisUnavailable, got \(first)") }
        XCTAssertTrue(reason.contains("exited"), reason)
        let noResults = try await store.results()
        XCTAssertEqual(noResults, [])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("pipelines").path)
        XCTAssertEqual(leftovers, [], "a failed run leaves no staging directory behind")

        let second = await runner.retryAndWait()
        guard case .done(let id) = second else { return XCTFail("retry should succeed with a fresh worker, got \(second)") }
        let ev = try await evaluation(id)
        XCTAssertNotNil(ev["models"])
    }

    func testRecordingStillOpensWhileWorkerDown() async throws {
        let runner = try makeRunner(launch: try fakeLaunch("import sys; sys.exit(1)"))
        let state = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .analysisUnavailable = state else { return XCTFail("\(state)") }
        let handle = try await store.recording(id: recordingID)
        XCTAssertEqual(handle.manifest.segments.count, 3)
        XCTAssertEqual(handle.verify(), [])
        let events = try await store.events(for: recordingID)
        XCTAssertEqual(events.count, 33, "15 cues + 18 rests in the first 42 s of three runs")
        XCTAssertEqual(try handle.chunk(handle.manifest.chunks[0]).count, 8 * 160)
    }

    /// Prologue for scripted fake workers: protocol output helpers and the ready event.
    private static let fakePrologue = """
    import os, sys, json, time
    def out(o):
        sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
    out({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": ["fit_evaluate_project"]}})

    """

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func pipelineLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("pipelines").path)
    }

    func testLateProgressAfterFailure_doesNotFlipStateBack() async throws {
        let launch = try fakeLaunch(Self.fakePrologue + """
        for line in sys.stdin:
            if not line.strip():
                continue
            req = json.loads(line)
            if req["method"] == "fit_evaluate_project":
                out({"v": 1, "id": req["id"], "ok": False, "error": {"code": "integrity", "message": "chunk 3 does not match"}})
                time.sleep(0.3)
                out({"v": 1, "event": "progress", "id": req["id"], "data": {"stage": "loading"}})
        """)
        let runner = try makeRunner(launch: launch)
        let final = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .failed(let reason) = final else { return XCTFail("\(final)") }
        XCTAssertTrue(reason.contains("integrity"), reason)
        let logged = runner.progressLog
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(runner.state, final, "a progress event after the terminal state must be ignored")
        XCTAssertEqual(runner.progressLog, logged)
        // And delivered directly, for the request id the worker used: still ignored.
        runner.handle(WorkerEvent(name: "progress", requestID: nil, data: Data(#"{"stage":"loading"}"#.utf8)))
        XCTAssertEqual(runner.state, final)
        XCTAssertEqual(try pipelineLeftovers(), [])
    }

    func testCancel_reportsCancelledStoresNothingAndRunsAgain() async throws {
        // Reports one stage, then waits for the app's cancel and answers it the way the
        // real worker does (the cancel reply, then `cancelled` for the original request).
        let launch = try fakeLaunch(Self.fakePrologue + """
        for line in sys.stdin:
            if not line.strip():
                continue
            req = json.loads(line)
            if req["method"] == "fit_evaluate_project":
                out({"v": 1, "event": "progress", "id": req["id"], "data": {"stage": "loading"}})
            elif req["method"] == "cancel":
                out({"v": 1, "id": req["id"], "ok": True, "result": {"cancelled": True}})
                out({"v": 1, "id": req["params"]["id"], "ok": False, "error": {"code": "cancelled", "message": "request was cancelled"}})
            elif req["method"] == "shutdown":
                out({"v": 1, "id": req["id"], "ok": True, "result": {"bye": True}})
                break
        """)
        let runner = try makeRunner(launch: launch)
        for attempt in 0..<2 {
            if attempt == 0 { runner.evaluate(.init(recordingID: recordingID, seed: 0)) } else { runner.retry() }
            // Generous: the first worker launch of a test run can be slow on a loaded machine.
            await waitUntil(.seconds(60)) { runner.progressLog.contains(.loading) }
            XCTAssertEqual(runner.state, .running(.loading), "attempt \(attempt)")
            let final = await runner.cancelAndWait()
            XCTAssertEqual(final, .cancelled, "attempt \(attempt)")
            let results = try await store.results()
            XCTAssertEqual(results, [], "a cancelled run saves nothing")
            XCTAssertEqual(try pipelineLeftovers(), [], "nor leaves its staging directory")
        }
    }

    func testCancelAfterWorkerAnswered_beforeStoring_savesNothing() async throws {
        // Answers with a complete result but never sends `done`, so the runner sits in its
        // bounded wait for that event (~1 s) between the response and storing.
        let launch = try fakeLaunch(Self.fakePrologue + """
        for line in sys.stdin:
            if not line.strip():
                continue
            req = json.loads(line)
            if req["method"] == "fit_evaluate_project":
                open(req["params"]["fitted_arrays_path"], "wb").write(b"PK")
                pipeline = {"recipe": "csp_rlda_v1", "configuration": {}, "expectedChannelIDs": ["ch00"], "expectedSampleRateHz": 160.0,
                            "preprocessingStatePolicy": "reset_on_segment_start", "splitManifest": "{}", "dependencyVersions": {},
                            "seed": 0, "configHash": "h"}
                out({"v": 1, "event": "progress", "id": req["id"], "data": {"stage": "loading"}})
                out({"v": 1, "id": req["id"], "ok": True, "result": {"evaluation": {"x": 1}, "pipeline": pipeline, "fitted_arrays_file": None}})
        """)
        let runner = try makeRunner(launch: launch)
        runner.evaluate(.init(recordingID: recordingID, seed: 0))
        await waitUntil(.seconds(60)) { runner.progressLog.contains(.loading) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runner.state, .running(.loading), "still waiting for `done`, not yet storing")
        let final = await runner.cancelAndWait()
        XCTAssertEqual(final, .cancelled)
        XCTAssertFalse(runner.progressLog.contains(.storing))
        let results = try await store.results()
        XCTAssertEqual(results, [], "a cancel before storing saves nothing")
        XCTAssertEqual(try pipelineLeftovers(), [])
    }

    func testCancelDuringLaunch_thenLaunchFails_reportsCancelled() async throws {
        let runner = try makeRunner(launch: try fakeLaunch("import sys, time; time.sleep(1.0); sys.exit(1)"))
        runner.evaluate(.init(recordingID: recordingID, seed: 0))
        await waitUntil { runner.state == .running(.starting) }
        XCTAssertEqual(runner.state, .running(.starting))
        let final = await runner.cancelAndWait()
        XCTAssertEqual(final, .cancelled, "the user asked to stop; the launch failure is not news")
    }

    func testCancelIgnoredByAHungWorker_watchdogStillReportsCancelled() async throws {
        // Reports one stage, then neither answers the cancel nor progresses.
        let launch = try fakeLaunch(Self.fakePrologue + """
        for line in sys.stdin:
            if line.strip() and json.loads(line)["method"] == "fit_evaluate_project":
                out({"v": 1, "event": "progress", "id": json.loads(line)["id"], "data": {"stage": "loading"}})
                time.sleep(3600)
        """)
        let runner = try makeRunner(launch: launch, silence: .seconds(1))
        runner.evaluate(.init(recordingID: recordingID, seed: 0))
        await waitUntil(.seconds(60)) { runner.progressLog.contains(.loading) }
        let final = await runner.cancelAndWait()
        XCTAssertEqual(final, .cancelled)
        let results = try await store.results()
        XCTAssertEqual(results, [])
        XCTAssertEqual(try pipelineLeftovers(), [])
    }

    func testProgressSilence_killsWorkerReportsUnavailableAndRetrySucceeds() async throws {
        // First launch: one progress event, then hangs. Second launch: the real worker.
        let launch = try fakeLaunch("""
        import os, sys, pathlib
        marker = pathlib.Path(sys.argv[0]).with_suffix(".hung")
        if marker.exists():
            os.execv(sys.executable, [sys.executable, "-I", "-u", "-B", "-X", "utf8", "-m", "bciworkspace_worker"])
        marker.write_text("1")
        """ + "\n" + Self.fakePrologue + """
        for line in sys.stdin:
            if line.strip() and json.loads(line)["method"] == "fit_evaluate_project":
                out({"v": 1, "event": "progress", "id": json.loads(line)["id"], "data": {"stage": "loading"}})
                time.sleep(3600)
        """)
        let runner = try makeRunner(launch: launch, silence: .seconds(1))
        let started = ContinuousClock.now
        let first = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .analysisUnavailable(let reason) = first else { return XCTFail("expected analysisUnavailable, got \(first)") }
        XCTAssertTrue(reason.contains("no progress"), reason)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(20))
        XCTAssertEqual(try pipelineLeftovers(), [])
        let second = await runner.retryAndWait()
        guard case .done = second else { return XCTFail("retry should succeed with a fresh worker, got \(second)") }
    }

    // MARK: Worker lifecycle (review round 1)

    func testShutdown_preventsAWorkerFromBeingStartedAgain() async throws {
        let runner = try makeRunner()
        // A defaults lookup is starting the worker when the window closes.
        let lookup = Task { try await runner.defaults() }
        try await Task.sleep(for: .milliseconds(50))
        await runner.shutdown()
        do { _ = try await lookup.value; XCTFail("a lookup racing shutdown must fail") } catch {}
        XCTAssertTrue(runner.isShutDown)
        XCTAssertFalse(runner.hasClient, "shutdown left no worker behind")
        do { _ = try await runner.defaults(); XCTFail("nothing starts after shutdown") } catch {}
        let state = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0))
        guard case .analysisUnavailable = state else { return XCTFail("\(state)") }
        XCTAssertFalse(runner.hasClient, "no worker was resurrected")
    }

    func testFailedStart_everyWaiterRethrows_thenAFreshStartSurvives() async throws {
        // First launch dies before announcing ready (slowly, so both callers wait on it);
        // later launches are the real worker.
        let launch = try fakeLaunch("""
        import os, sys, time, pathlib
        marker = pathlib.Path(sys.argv[0]).with_suffix(".failed")
        if marker.exists():
            os.execv(sys.executable, [sys.executable, "-I", "-u", "-B", "-X", "utf8", "-m", "bciworkspace_worker"])
        marker.write_text("1")
        time.sleep(0.5)
        sys.exit(1)
        """)
        let runner = try makeRunner(launch: launch)
        let a = Task { try await runner.defaults() }
        let b = Task { try await runner.defaults() }
        for t in [a, b] {
            do {
                _ = try await t.value
                XCTFail("a caller sharing a failed start must see its error")
            } catch let error as WorkerError {
                XCTAssertEqual(error.code, "worker_exited", error.message)
            }
        }
        XCTAssertFalse(runner.hasClient)
        // The next caller starts a fresh worker, and nothing left over kills it.
        let defaults = try await runner.defaults()
        XCTAssertEqual(defaults.recipes.count, 2)
        guard case .done = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0)) else { return XCTFail() }
        XCTAssertTrue(runner.hasClient)
    }

    func testStopWithin_cancelsAndWaitsForTheRun() async throws {
        let runner = try makeRunner()
        runner.evaluate(.init(recordingID: recordingID, seed: 0))
        await waitUntil(.seconds(60)) { runner.progressLog.contains(.loading) }
        XCTAssertTrue(runner.isBusy)
        await runner.stop(within: .seconds(10))
        XCTAssertFalse(runner.isBusy, "the run has ended")
        XCTAssertEqual(runner.state, .cancelled)
        let results = try await store.results()
        XCTAssertEqual(results, [])
        XCTAssertEqual(try pipelineLeftovers(), [])
    }

    // MARK: Export

    func testExport_layoutAndHashes() async throws {
        let runner = try makeRunner()
        guard case .done(let id) = await runner.evaluateAndWait(.init(recordingID: recordingID, seed: 0)) else { return XCTFail() }
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: id, to: out)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, (ProjectStore.exportFileNames + ["segment-S001R04.f64", "segment-S001R08.f64", "segment-S001R12.f64"]).sorted())

        let stored = try await store.result(id: id)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("evaluation.json")), stored.evaluationJSON, "byte-equal")
        let header = try ContractJSON.decoder().decode(ExportedRecording.self, from: Data(contentsOf: out.appendingPathComponent("recording.json")))
        XCTAssertEqual(header.samples.channelCount, 8)
        XCTAssertEqual(header.samples.files.map(\.runID), ["S001R04", "S001R08", "S001R12"])
        for file in header.samples.files {
            let data = try Data(contentsOf: out.appendingPathComponent(file.file))
            XCTAssertEqual(data.count, 8 * file.sampleCount * 8)
            XCTAssertEqual(AtomicFile.sha256Hex(data), file.sha256)
        }
        let channels = try ContractJSON.decoder().decode(ExportedChannels.self, from: Data(contentsOf: out.appendingPathComponent("channels.json")))
        XCTAssertEqual(channels.channels.map(\.label), ["FC3", "FC4", "C3", "C1", "Cz", "C2", "C4", "CPz"])
        let pipeline = try ContractJSON.decoder().decode(PipelineRecord.self, from: Data(contentsOf: out.appendingPathComponent("pipeline.json")))
        XCTAssertEqual(pipeline, stored.pipeline)
        let attribution = try String(contentsOf: out.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
        for needle in ["Schalk", "Goldberger", "ODC-BY", "10.13026/C28G6P"] { XCTAssertTrue(attribution.contains(needle), needle) }
        let eventLines = try String(contentsOf: out.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(eventLines.count, 33)

        // The one-liners in docs/export-format.md, extracted from the doc text itself and
        // run with `python -I` (no environment, numpy only) against this export.
        let doc = try String(contentsOf: Self.repoRoot.appendingPathComponent("docs/export-format.md"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^python -I -c "(.*)" /path/to/export$"#, options: [.anchorsMatchLines])
        let snippets = regex.matches(in: doc, range: NSRange(doc.startIndex..., in: doc)).map { String(doc[Range($0.range(at: 1), in: doc)!]) }
        XCTAssertEqual(snippets.count, 2, "both documented one-liners must be present")
        let launch = try realLaunch()
        var outputs: [String] = []
        for code in snippets {
            let proc = Process()
            proc.executableURL = launch.python
            proc.arguments = ["-I", "-c", code, out.path]
            proc.environment = launch.environment()
            let pipe = Pipe(), err = Pipe()
            proc.standardOutput = pipe
            proc.standardError = err
            try proc.run()
            proc.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(proc.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            outputs.append(text)
        }
        XCTAssertEqual(outputs[0].trimmingCharacters(in: .whitespacesAndNewlines),
                       "{'S001R04': (8, 6720), 'S001R08': (8, 6720), 'S001R12': (8, 6720)}")
        XCTAssertTrue(outputs[1].contains("'csp_filters': (4, 8)"), outputs[1])
        XCTAssertTrue(outputs[1].contains("'baseline__lda_coef'"), outputs[1])
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
