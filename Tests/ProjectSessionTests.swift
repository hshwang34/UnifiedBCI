import AppKit
import XCTest
@testable import BCIWorkspace

/// The project window's model over the real store, runner and worker (criteria 5, 6 and 9
/// from the UI side), and the one-session-per-project rule the store's sweep relies on.
@MainActor
final class ProjectSessionTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!
    private var workspace: Workspace!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("tiny.bciproj")
        _ = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
        workspace = Workspace(recents: InMemoryRecentDocuments(), launch: try realLaunch())
    }

    override func tearDown() async throws {
        for url in Array(workspace.sessions.keys) { await workspace.close(url) }
        try? FileManager.default.removeItem(at: scratch)
    }

    private func realLaunch() throws -> WorkerLaunch {
        try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
    }

    // MARK: Evaluate flow

    func testEvaluateFlow_progressResultThenReproductionChild() async throws {
        let session = try await workspace.session(for: project)
        XCTAssertEqual(session.recordings.count, 1)
        XCTAssertNotNil(session.selectedRecordingID, "the only recording is selected, so Evaluate is ready")
        XCTAssertTrue(session.canEvaluate)

        // Progress is observable while it runs: sample the session's display, not just the log.
        var stages: [String] = []
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let p = session.progress, stages.last != p.stage { stages.append(p.stage) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let first = await session.evaluateAndWait()
        sampler.cancel()
        guard case .done(let id) = first else { return XCTFail("\(first)") }
        let labels = session.runner.progressLog.map { ProgressDisplay($0, modelName: session.modelName).stage }
        for stage in ProgressDisplay.stages { XCTAssertTrue(labels.contains(stage), "\(stage) missing from \(labels)") }
        XCTAssertFalse(stages.isEmpty, "the progress display was visible during the run")
        XCTAssertNil(session.progress, "no progress once finished")

        // The result is listed and selected, and the screen can be built from it.
        XCTAssertEqual(session.section, .results)
        XCTAssertEqual(session.selectedResultID, id)
        XCTAssertEqual(session.notice, .saved)
        XCTAssertEqual(session.noticeText(.saved), "Result saved to project")
        XCTAssertEqual(session.resultTree.map(\.id), [id])
        await session.awaitSelectedResult()
        let stored = try XCTUnwrap(session.selectedResult)
        let model = try ResultDetailModel(stored: stored, allResults: session.results, modelName: session.modelName)
        XCTAssertTrue(model.headline.balancedAccuracy.hasPrefix("Balanced accuracy "))
        XCTAssertTrue(model.headline.accuracy.contains("trial-level"))
        XCTAssertNil(model.reproduction)
        XCTAssertEqual(model.referenceName, "CSP + shrinkage LDA", "model names come from the worker's recipe descriptions")

        // Same seed again: a reproduction, listed as a child of the original.
        let second = await session.evaluateAndWait()
        guard case .done(let repro) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(session.resultTree.map(\.id), [id])
        XCTAssertEqual(session.resultTree.first?.children?.map(\.id), [repro])
        XCTAssertEqual(session.selectedResultID, repro)
        guard case .reproduced(let original) = session.notice else { return XCTFail("\(String(describing: session.notice))") }
        XCTAssertEqual(original, session.results.first { $0.resultID == id }?.createdAt)
        await session.awaitSelectedResult()
        let reproModel = try ResultDetailModel(stored: try XCTUnwrap(session.selectedResult), allResults: session.results)
        XCTAssertEqual(reproModel.reproduction?.kind, .identical)
        XCTAssertEqual(reproModel.reproduction?.originalID, id)

        // A new seed is a new top-level row.
        session.parameters.seed = 9
        guard case .done(let other) = await session.evaluateAndWait() else { return XCTFail() }
        XCTAssertEqual(session.resultTree.map(\.id), [id, other])
    }

    func testRequestDefaults_comeFromTheWorker() async throws {
        let session = try await workspace.session(for: project)
        await session.awaitDefaults()
        let d = try XCTUnwrap(session.workerDefaults, "\(session.defaults)").params
        let recording = try XCTUnwrap(session.selectedRecordingID)
        let request = session.makeRequest(recordingID: recording)
        XCTAssertEqual(request.seed, d.seed)
        XCTAssertEqual(request.windowOffsetSeconds, d.window.offset_s)
        XCTAssertEqual(request.windowLengthSeconds, d.window.length_s)
        XCTAssertEqual(request.cspComponents, d.csp_components)
        XCTAssertEqual([request.leftLabel, request.rightLabel], [d.labels.left, d.labels.right])
        // The runner's fallback (used only while the worker has not answered) agrees too.
        let fallback = EvaluationRunner.Request(recordingID: recording, seed: d.seed)
        XCTAssertEqual(fallback, request)
        // Overrides win; Reset (empty parameters) returns to the worker's values.
        session.parameters.cspComponents = 2
        XCTAssertEqual(session.makeRequest(recordingID: recording).cspComponents, 2)
        session.parameters = .init()
        XCTAssertEqual(session.makeRequest(recordingID: recording), request)
        XCTAssertEqual(session.workerDefaults?.recipes.map(\.role), ["reference", "baseline"])
    }

    // MARK: Worker death

    func testUnavailable_thenRetrySucceeds() async throws {
        // First launch: answers nothing but dies on the evaluation. Next launch: the real worker.
        let real = try realLaunch()
        let dir = scratch.appendingPathComponent("fake", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake_worker.py")
        try """
        import os, sys, json, pathlib
        marker = pathlib.Path(sys.argv[0]).with_suffix(".died")
        if marker.exists():
            os.execv(sys.executable, [sys.executable, "-I", "-u", "-B", "-X", "utf8", "-m", "bciworkspace_worker"])
        print(json.dumps({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": []}}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            req = json.loads(line)
            if req["method"] == "fit_evaluate_project":
                sys.stderr.write("fake worker: simulated crash\\n"); sys.stderr.flush()
                marker.write_text("1")
                os._exit(3)
            print(json.dumps({"v": 1, "id": req["id"], "ok": False, "error": {"code": "unknown_method", "message": "no such method"}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let fake = WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(script))
        workspace = Workspace(recents: InMemoryRecentDocuments(), launch: fake)

        let session = try await workspace.session(for: project)
        let first = await session.evaluateAndWait()
        guard case .analysisUnavailable = first else { return XCTFail("\(first)") }
        guard case .analysisUnavailable(let details) = session.banner else { return XCTFail("\(String(describing: session.banner))") }
        XCTAssertTrue(details.contains("exited"), details)
        XCTAssertTrue(details.contains("simulated crash"), "the stderr tail is in the details disclosure: \(details)")
        XCTAssertEqual(session.results, [])
        XCTAssertEqual(session.recordings.count, 1, "the recording stays browsable")
        XCTAssertNil(session.notice)

        let second = await session.retryAndWait()
        guard case .done(let id) = second else { return XCTFail("\(second)") }
        XCTAssertNil(session.banner)
        XCTAssertEqual(session.results.map(\.resultID), [id])
        XCTAssertEqual(session.notice, .saved)
    }

    func testFailedState_isADistinctBanner() async throws {
        let session = try await workspace.session(for: project)
        await session.awaitDefaults()
        session.parameters.cspComponents = 99   // more components than channels: the worker refuses
        let state = await session.evaluateAndWait()
        guard case .failed = state else { return XCTFail("\(state)") }
        guard case .failed(let details) = session.banner else { return XCTFail("\(String(describing: session.banner))") }
        XCTAssertFalse(details.isEmpty)
        XCTAssertEqual(session.results, [])
    }

    // MARK: One session per project

    func testOpeningSameProjectTwice_endsWithOneSession() async throws {
        // Three spellings of one directory: plain, trailing slash with `..`, and a symlink.
        let link = scratch.appendingPathComponent("alias.bciproj")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let dotted = URL(fileURLWithPath: scratch.appendingPathComponent("sub/../tiny.bciproj/").path)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("sub"), withIntermediateDirectories: true)

        // Two opens in flight at once share one open.
        let ws = workspace!, plain = project!
        let ta = Task { try await ws.session(for: plain) }
        let tb = Task { try await ws.session(for: dotted) }
        let sa = try await ta.value, sb = try await tb.value
        let sc = try await workspace.session(for: link)
        XCTAssertTrue(sa === sb && sb === sc, "every spelling resolves to the same session")
        XCTAssertEqual(workspace.sessions.count, 1)
        XCTAssertEqual(Workspace.canonical(project), Workspace.canonical(link))
        XCTAssertEqual(Workspace.canonical(project), Workspace.canonical(dotted))

        // A second window for the same project is closed in favour of the first.
        func window() -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.orderFront(nil)
            return w
        }
        let first = window(), second = window()
        defer { first.close(); second.close() }
        workspace.attach(first, to: project)
        workspace.attach(second, to: link)
        XCTAssertFalse(second.isVisible, "the duplicate window is closed")
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(workspace.sessions.count, 1, "closing the duplicate does not end the session")

        // Closing the real window ends the session; reopening makes a fresh one.
        first.close()
        for _ in 0..<200 where !workspace.sessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(workspace.sessions.isEmpty)
        let reopened = try await workspace.session(for: project)
        XCTAssertFalse(reopened === sa)
    }

    // MARK: Review round 1: lifecycle

    private func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testCloseMidRun_asksFirst_thenStopsTheRunAndSavesNothing() async throws {
        // A worker that reports one stage, then waits for the app's cancel (as the real one
        // does at its checkpoints), so "mid-run" is deterministic.
        let real = try realLaunch()
        let dir = scratch.appendingPathComponent("fake-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake_worker.py")
        try """
        import os, sys, json
        def out(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        out({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": []}})
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
            else:
                out({"v": 1, "id": req["id"], "ok": False, "error": {"code": "unknown_method", "message": "no"}})
        """.write(to: script, atomically: true, encoding: .utf8)
        workspace = Workspace(recents: InMemoryRecentDocuments(),
                              launch: WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(script)))
        let session = try await workspace.session(for: project)
        XCTAssertFalse(Workspace.closeNeedsConfirmation(session), "idle: closes without asking")
        session.evaluate()
        await waitUntil { session.runner.state == .running(.loading) }
        XCTAssertTrue(Workspace.closeNeedsConfirmation(session), "a cancellable run asks before closing")
        await workspace.close(project)
        XCTAssertTrue(session.isShutDown)
        XCTAssertFalse(session.runner.isBusy, "close waited for the run to end")
        XCTAssertTrue(session.runner.isShutDown)
        XCTAssertEqual(session.runner.state, .cancelled)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("pipelines").path)
        XCTAssertEqual(leftovers, [], "nothing saved, no staging left")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("results").path), [])
    }

    func testWindowClosedWhileOpening_closesTheSession() async throws {
        let session = try await workspace.session(forWindow: project, stillWanted: { false })
        XCTAssertNil(session)
        XCTAssertTrue(workspace.sessions.isEmpty, "no session (and no worker) is left without a window")
        let kept = try await workspace.session(forWindow: project, stillWanted: { true })
        XCTAssertNotNil(kept)
        XCTAssertEqual(workspace.sessions.count, 1)
    }

    func testCaseInsensitiveSpelling_isTheSameProject() async throws {
        let upper = URL(fileURLWithPath: project.deletingLastPathComponent().path + "/TINY.BCIPROJ")
        guard FileManager.default.fileExists(atPath: upper.path) else {
            throw XCTSkip("scratch volume is case-sensitive")
        }
        let a = try await workspace.session(for: project)
        let b = try await workspace.session(for: upper)
        XCTAssertTrue(a === b)
        XCTAssertEqual(workspace.sessions.count, 1)
        XCTAssertEqual(Workspace.canonical(upper), Workspace.canonical(project))
        XCTAssertEqual(Workspace.canonical(upper).lastPathComponent, "tiny.bciproj", "the on-disk case")
    }

    func testReopenDuringTeardown_waitsForTheOldSession() async throws {
        let first = try await workspace.session(for: project)
        let ws = workspace!, url = project!
        let closing = Task { await ws.close(url) }
        await Task.yield()
        let second = try await workspace.session(for: project)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isShutDown, "the new session opened only after the old one stopped")
        await closing.value
        XCTAssertTrue(workspace.sessions[Workspace.canonical(project)] === second)
    }

    func testConcurrentAdopt_givesOneSession() async throws {
        let store = try ProjectStore.open(at: project)
        let ws = workspace!
        let a = Task { await ws.adopt(store) }
        let b = Task { await ws.adopt(store) }
        let sa = await a.value, sb = await b.value
        XCTAssertTrue(sa === sb)
        XCTAssertEqual(workspace.sessions.count, 1)
    }

    func testFinderOpen_routesThroughWorkspaceOpen() async throws {
        let delegate = AppDelegate(workspace: workspace)
        delegate.application(NSApplication.shared, open: [project])
        await waitUntil(.seconds(30)) { !workspace.sessions.isEmpty }
        XCTAssertEqual(Array(workspace.sessions.keys), [Workspace.canonical(project)])
        XCTAssertEqual(workspace.recents.map(\.url), [Workspace.canonical(project)], "noted in recents like Open…")
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testCloseGuard_forwardsToTheOriginalDelegate() {
        final class Original: NSObject, NSWindowDelegate {
            var asked = false
            func windowShouldClose(_ sender: NSWindow) -> Bool { asked = true; return false }
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let original = Original()
        window.delegate = original
        let guardian = CloseGuard(window: window) { nil }
        XCTAssertTrue(window.delegate === guardian)
        XCTAssertFalse(guardian.windowShouldClose(window), "no run: the original delegate decides")
        XCTAssertTrue(original.asked)
        XCTAssertTrue(guardian.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))))
    }

    func testRecipes_followTheCSPOverride() async throws {
        let session = try await workspace.session(for: project)
        await session.awaitDefaults()
        XCTAssertTrue(session.recipes.first?.steps.joined().contains("4 components") ?? false, "\(session.recipes)")
        session.parameters.cspComponents = 2
        await session.awaitRecipes()
        XCTAssertTrue(session.recipes.first?.steps.joined().contains("2 components") ?? false, "\(session.recipes)")
    }

    func testNotices_toastsClearOnSectionChangeAndExpire_warningsStay() async throws {
        let session = try await workspace.session(for: project)
        let other = scratch.appendingPathComponent("x")
        // A toast clears when the user moves to another section.
        await session.export(resultID: UUID(), to: other)       // no such result: a persistent warning
        guard case .exportFailed = session.notice else { return XCTFail("\(String(describing: session.notice))") }
        session.section = .pipelines
        XCTAssertNotNil(session.notice, "a warning chip stays until dismissed")
        session.dismissNotice()
        // A toast expires on its own.
        session.noticeLifetime = .milliseconds(50)
        session.section = .results
        session.showNoticeForTesting(.saved)
        session.section = .pipelines
        XCTAssertNil(session.notice, "a section change clears a toast")
        session.showNoticeForTesting(.saved)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(session.notice, "a toast dismisses itself")
    }

    func testRecents_noteCanonicalAndDedupe() async throws {
        workspace.noteRecent(project)
        workspace.noteRecent(URL(fileURLWithPath: project.path + "/"))
        XCTAssertEqual(workspace.recents.map(\.url), [Workspace.canonical(project)])
        XCTAssertTrue(workspace.recents[0].exists)
        XCTAssertEqual(workspace.recents[0].name, "tiny")
        workspace.removeRecent(workspace.recents[0].url)
        XCTAssertTrue(workspace.recents.isEmpty)
    }

    func testOpenFailure_messageForNonProject() {
        XCTAssertEqual(Workspace.openFailureMessage(ProjectStoreError.notAProject(scratch)), "Not a BCI Workspace project.")
    }
}
