import Darwin
import XCTest
@testable import BCIWorkspace

/// Brief 002 PR 4: the Quality tab's view-model state. Model helpers on the captured
/// fixtures; the session flow (first show starts inspection, progress, cache on revisit,
/// cancel, failure, shutdown with the window) over the real store and worker.
@MainActor
final class QualityTabTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!
    private var workspace: Workspace?

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("tiny.bciproj")
        _ = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: project)
    }

    override func tearDown() async throws {
        if let workspace { for url in Array(workspace.sessions.keys) { await workspace.close(url) } }
        try? FileManager.default.removeItem(at: scratch)
    }

    private func session(_ launch: WorkerLaunch? = nil) async throws -> ProjectSession {
        let ws = Workspace(recents: InMemoryRecentDocuments(), launch: try launch ?? XCTUnwrap(WorkerLaunch.locate(), "run scripts/bootstrap.sh"))
        workspace = ws
        return try await ws.session(for: project)
    }

    /// A worker that answers `inspect_recording` with one progress event and then waits for
    /// cancel; it writes its pid to `pidFile` and refuses everything else.
    private func hangingLaunch(pidFile: URL) throws -> WorkerLaunch {
        let real = try XCTUnwrap(WorkerLaunch.locate())
        let dir = scratch.appendingPathComponent("fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake_worker.py")
        try """
        import os, sys, json
        def out(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        out({"v": 1, "event": "ready", "id": None, "data": {"protocol": 1, "pid": os.getpid(), "versions": {}, "methods": ["inspect_recording"]}})
        for line in sys.stdin:
            if not line.strip():
                continue
            req = json.loads(line)
            if req["method"] == "inspect_recording":
                open(\(String(reflecting: pidFile.path)), "w").write(str(os.getpid()))
                out({"v": 1, "event": "progress", "id": req["id"], "data": {"stage": "inspect", "segment": 2, "of": 3}})
            elif req["method"] == "cancel":
                out({"v": 1, "id": req["id"], "ok": True, "result": {"cancelled": True}})
                out({"v": 1, "id": req["params"]["id"], "ok": False, "error": {"code": "cancelled", "message": "request was cancelled"}})
            elif req["method"] == "shutdown":
                out({"v": 1, "id": req["id"], "ok": True, "result": {}})
                break
            else:
                out({"v": 1, "id": req["id"], "ok": False, "error": {"code": "unknown_method", "message": "no"}})
        """.write(to: url, atomically: true, encoding: .utf8)
        return WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: dir, entry: .script(url))
    }

    private func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Model

    func testQualityIsTheFourthRecordingTab_decision21() {
        XCTAssertEqual(RecordingTab.allCases.map(\.rawValue), ["Channels", "Segments", "Events", "Quality"])
        XCTAssertEqual(QualityModel.tabTitle, RecordingTab.quality.rawValue)
    }

    func testSelectingAChannelPicksItsSpectrum_rawOrBandPassed() throws {
        let m = QualityModel(report: try QualityModelTests.fixture("inspect_recording_tiny"))
        let seg = m.sections[1]
        XCTAssertEqual(m.spectrum(section: 1, channel: seg.spectra[3].id)?.label, seg.spectra[3].label)
        XCTAssertEqual(m.spectrum(section: 1, channel: nil)?.id, seg.spectra[0].id, "nothing selected: the first channel")
        XCTAssertEqual(m.spectrum(section: 1, channel: "no-such-channel")?.id, seg.spectra[0].id)
        XCTAssertNil(m.spectrum(section: 9, channel: nil))
        let s = try XCTUnwrap(m.spectrum(section: 0, channel: "ch00"))
        XCTAssertEqual(s.series(processed: false), s.raw)
        XCTAssertEqual(s.series(processed: true), s.processed)
        XCTAssertNotEqual(s.raw, s.processed)
        XCTAssertNil(s.unavailableText(processed: true))
        XCTAssertEqual(seg.nyquistHz, 80, "160 Hz recording: the chart runs to 80 Hz")
    }

    func testMissingSpectrumSaysWhy() throws {
        let m = QualityModel(report: try QualityModelTests.fixture("inspect_recording_faults"))
        let nan = try XCTUnwrap(m.sections[0].spectra.first { $0.label == "NAN" })
        XCTAssertEqual(nan.unavailableText(processed: false), "Raw (mean removed) not available · channel contains non-finite samples")
        XCTAssertNotNil(nan.unavailableText(processed: true))
    }

    func testFlaggedChannelsAreTheRowsWithFlags() throws {
        let m = QualityModel(report: try QualityModelTests.fixture("inspect_recording_faults"))
        let flagged = m.flaggedChannels(section: 0)
        XCTAssertEqual(flagged, Set(m.sections[0].rows.filter { !$0.flags.isEmpty }.map(\.id)))
        let labels = Set(m.sections[0].rows.filter { flagged.contains($0.id) }.map(\.label))
        XCTAssertTrue(labels.isSuperset(of: ["FLAT", "PIN", "MAINS", "BIG", "HF"]), "\(labels)")
        XCTAssertFalse(labels.contains("C3"))
        XCTAssertEqual(m.flaggedChannels(section: 99), [])
    }

    func testProgressCopyNamesTheSegment() {
        XCTAssertEqual(QualityModel.progressText(.segment(2, of: 3)), "Checking segment 2 of 3…")
        XCTAssertEqual(QualityModel.progressText(.starting), "Starting the analysis worker…")
        XCTAssertEqual(QualityModel.progressText(.loading), "Reading the recording…")
    }

    // MARK: Session

    func testFirstShowInspects_showsProgress_thenCachesOnRevisit() async throws {
        let session = try await session()
        XCTAssertEqual(session.qualityState, .notStarted)
        XCTAssertFalse(session.inspector.isBusy, "other tabs never start an inspection")
        var sawRunning = false
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if case .running = session.qualityState { sawRunning = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        session.recordingTab = .quality
        await session.awaitInspection()
        sampler.cancel()
        XCTAssertTrue(sawRunning)
        guard case .ready(let model) = session.qualityState else { return XCTFail("\(session.qualityState)") }
        XCTAssertEqual(model.sections.count, 3)
        XCTAssertTrue(session.inspector.progressLog.contains(.segment(3, of: 3)), "\(session.inspector.progressLog)")

        let log = session.inspector.progressLog
        session.recordingTab = .channels
        session.recordingTab = .quality
        await session.awaitInspection()
        XCTAssertEqual(session.qualityState, .ready(model))
        XCTAssertEqual(session.inspector.progressLog, log, "revisit used the cached report")
    }

    func testCancel_staysCancelledOnRevisit_untilInspectAgain() async throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let session = try await session(try hangingLaunch(pidFile: pidFile))
        session.recordingTab = .quality
        await waitUntil { session.qualityState == .running(.segment(2, of: 3)) }
        XCTAssertEqual(session.qualityState, .running(.segment(2, of: 3)))
        session.cancelInspection()
        await session.awaitInspection()
        XCTAssertEqual(session.qualityState, .cancelled)
        session.recordingTab = .events
        session.recordingTab = .quality
        XCTAssertEqual(session.qualityState, .cancelled, "switching tabs does not restart a cancelled inspection")
        session.inspect()
        await waitUntil { session.qualityState == .running(.segment(2, of: 3)) }
        XCTAssertEqual(session.qualityState, .running(.segment(2, of: 3)))
    }

    func testWorkerFailure_isTheAnalysisUnavailableState() async throws {
        let real = try XCTUnwrap(WorkerLaunch.locate())
        let script = scratch.appendingPathComponent("dies.py")
        try "import sys\nsys.stderr.write('fake worker: exits before ready\\n')\nsys.exit(3)\n".write(to: script, atomically: true, encoding: .utf8)
        let session = try await session(WorkerLaunch(origin: real.origin, python: real.python, pythonPath: nil, workingDirectory: scratch, entry: .script(script)))
        session.recordingTab = .quality
        await session.awaitInspection()
        guard case .unavailable(let details) = session.qualityState else { return XCTFail("\(session.qualityState)") }
        XCTAssertFalse(details.isEmpty)
        XCTAssertEqual(QualityModel.unavailableTitle, "Analysis unavailable")
    }

    func testClosingTheProject_stopsTheInspectionWorker() async throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let session = try await session(try hangingLaunch(pidFile: pidFile))
        session.recordingTab = .quality
        await waitUntil { session.qualityState == .running(.segment(2, of: 3)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0, "the inspection worker is running")
        await workspace?.close(project)
        XCTAssertTrue(session.isShutDown)
        XCTAssertFalse(session.inspector.isBusy)
        await waitUntil(.seconds(10)) { kill(pid, 0) != 0 }
        XCTAssertNotEqual(kill(pid, 0), 0, "the inspection worker exited with its project")
        session.inspect()
        XCTAssertFalse(session.inspector.isBusy, "nothing starts after shutdown")
    }
}
