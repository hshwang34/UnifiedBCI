import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 6: Start run…, the operator panel, the timing summary and the run-count
/// message as screen models; the run keys; display memory; and a session of runs through the
/// project window's own path on BrainFlow's synthetic board (decision #26: no hardware).
@MainActor
final class RunFlowTests: XCTestCase {
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-runflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private let laptop = CueDisplayInfo(id: 1, name: "Built-in Retina Display", width: 3024, height: 1964, isOperator: true)
    private let external = CueDisplayInfo(id: 4, name: "DELL U2723QE", width: 3840, height: 2160, isOperator: false)
    private var graz: ProtocolRecord { ProtocolRecord(draft: .grazDefault, parent: nil) }

    // MARK: Start run…

    func testStartRunForm_defaults_seed_runs_and_display() {
        let v1 = graz
        var draft = ProtocolDraft.grazDefault
        draft.runsPerSession = 6
        let v2 = ProtocolRecord(draft: draft, parent: v1)
        var form = StartRunForm(protocols: [v1, v2], displays: [laptop, external], remembered: nil, seed: 424_242)
        XCTAssertEqual(form.selected?.version, 2, "the newest version first")
        XCTAssertEqual(form.seedText, "424242", "the session seed is shown")
        XCTAssertEqual(form.runsPerSession, 6)
        XCTAssertEqual(form.display, external, "decision #36: a second display when connected")
        form.pick(v1.protocolID)
        XCTAssertEqual(form.runsPerSession, 4, "decision #37: the protocol's runs per session, 4 by default")
        XCTAssertNil(form.disabledReason(streamReason: nil))
        XCTAssertEqual(form.disabledReason(streamReason: RecordGate.notStreaming), RecordGate.notStreaming)
        for bad in ["", "12a", "-1", "18446744073709551616", "١٢"] {
            form.seedText = bad
            XCTAssertNil(form.seed, bad)
            XCTAssertEqual(form.disabledReason(streamReason: nil), StartRunCopy.badSeed)
        }
        form.seedText = " 18446744073709551615 "
        XCTAssertEqual(form.seed, .max)
        form.runsPerSession = 0
        XCTAssertEqual(form.disabledReason(streamReason: nil), StartRunCopy.badRuns)
        XCTAssertEqual(StartRunForm(protocols: [], displays: [laptop], remembered: nil).disabledReason(streamReason: nil), StartRunCopy.noProtocol)
        XCTAssertEqual(StartRunCopy.protocolSummary(v1), "40 trials per run · about 5 min 20 s per run · Left hand (left arrow) vs Right hand (right arrow)")
    }

    func testDisplayPicker_remembersTheLastChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bci-runflow-\(UUID().uuidString)"))
        XCTAssertEqual(StartRunForm(protocols: [graz], displays: [laptop, external], remembered: CueDisplayPicker.remembered(in: defaults)).display, external)
        CueDisplayPicker.remember(laptop, in: defaults)
        let form = StartRunForm(protocols: [graz], displays: [laptop, external], remembered: CueDisplayPicker.remembered(in: defaults))
        XCTAssertEqual(form.display, laptop, "the operator chose their own display last time")
        XCTAssertEqual(StartRunForm(protocols: [graz], displays: [], remembered: nil).disabledReason(streamReason: nil), StartRunCopy.noDisplay)
    }

    func testRunKeys() {
        XCTAssertEqual(RunKey(keyCode: 49, characters: " ", command: false), .space)
        XCTAssertEqual(RunKey(keyCode: 53, characters: "\u{1b}", command: false), .escape)
        XCTAssertEqual(RunKey(keyCode: 47, characters: ".", command: true), .abortRun)
        XCTAssertNil(RunKey(keyCode: 47, characters: ".", command: false))
        XCTAssertNil(RunKey(keyCode: 49, characters: " ", command: true))
        XCTAssertNil(RunKey(keyCode: 0, characters: "a", command: false))
    }

    // MARK: Operator panel

    func testOperatorPanel_everyState() {
        let p = graz
        var s = ProtocolRunner.Status(runID: "run02", runIndex: 1, runsPerSession: 4, trialCount: 40)
        var m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0)
        XCTAssertEqual(m.progress, "Run 2 of 4 · 40 trials")
        XCTAssertEqual(m.phase, "Instructions on screen. Press Space when the participant is ready.")
        XCTAssertTrue(m.canBegin && m.canAbortRun)
        XCTAssertFalse(m.canAbortTrial || m.canPause || m.canResume)

        s.state = .running; s.trial = 16; s.phase = .cue; s.label = "cue_left_hand"
        s.startedAt = 1_000_000_000; s.plannedEnd = 241_000_000_000
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 84_000_000_000)
        XCTAssertEqual(m.progress, "Run 2 of 4 · Trial 17 of 40")
        XCTAssertEqual(m.phase, "Cue · Left hand")
        XCTAssertEqual(m.time, "Elapsed 1 min 23 s · about 2 min 37 s left")
        XCTAssertTrue(m.canAbortTrial && m.canPause && m.canAbortRun)
        s.phase = .rest
        XCTAssertFalse(OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0).canAbortTrial, "rest has nothing to abort")

        s.state = .paused(.disconnect); s.abortedTrials = ["run02-t17"]
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: false, nowNanos: 84_000_000_000)
        XCTAssertEqual(m.phase, "Paused: the board disconnected. Resume once it reconnects.")
        XCTAssertFalse(m.canResume, "decision #35: Resume waits for the reconnect")
        XCTAssertEqual(m.time, "Elapsed 1 min 23 s")
        XCTAssertEqual(m.notice?.text, "1 trial aborted and excluded: run02-t17")
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0)
        XCTAssertTrue(m.canResume)
        XCTAssertTrue(m.phase.contains("new segment"))

        s.state = .ended(aborted: true); s.endReason = "recording_stopped"; s.unrecordedEvents = ["rest", "run_end"]
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0)
        XCTAssertEqual(m.phase, "Run ended early")
        XCTAssertEqual(m.notice?.danger, true)
        XCTAssertEqual(m.notice?.text, "The run stopped because the recording stopped; 2 events were not recorded.")
        XCTAssertFalse(m.canAbortRun || m.canBegin || m.canResume)
    }

    // MARK: Timing summary

    func testTimingSummary_percentilesFramesAndPlacements() {
        let ms: Int64 = 1_000_000
        let lateness = (1...20).map { Int64($0) * ms }          // 1…20 ms
        let m = TimingSummaryModel(latenessNanos: lateness.shuffled(), missing: 1, framePeriodNanos: 16_666_667, placements: (158, 2))
        XCTAssertEqual(m.title, "Cue timing (software)")
        XCTAssertEqual(m.rows.map(\.0), ["Median lateness", "95th percentile", "Maximum", "A frame or more late", "No callback", "Placed on the EEG"])
        XCTAssertEqual(m.rows.map(\.1), ["10.0 ms", "19.0 ms", "20.0 ms", "4 of 20 screen changes (1 frame = 16.7 ms)",
                                         "1 phase; presented time left empty", "158 events by BrainFlow marker · 2 by nearest timestamp"])
        XCTAssertEqual(m.caveat, "Measured from the app's own callbacks. The delay to the screen and to the EEG sample is not measured.")
        let empty = TimingSummaryModel(latenessNanos: [], missing: 0, framePeriodNanos: 0, placements: nil)
        XCTAssertEqual(empty.rows.map(\.1), ["no presentation callbacks", "counting…"])
    }

    func testRunCountMessage() {
        XCTAssertEqual(RunCountModel.message(runs: 2), "Needs at least 3 runs (1 held out, 2 for cross-validation); this recording has 2.")
        XCTAssertEqual(RunCountModel.message(runs: 4), "4 runs: enough to hold one out and cross-validate on the rest.")
        XCTAssertEqual(RunCountModel.labels(graz), "Classes from Left vs right hand (Graz-style) v1: Left hand (“cue_left_hand”) vs Right hand (“cue_right_hand”).")
    }

    // MARK: A session of runs on the synthetic board

    private final class FakeSurface: CueSurface {
        let timed = TimedDisplay()
        var display: any CueDisplay { timed }
        var shown = 0, hidden = 0, closed = 0
        func show() { shown += 1 }
        func hide() { hidden += 1 }
        func close() { closed += 1 }
    }

    func testTwoRunsOnTheSyntheticBoard_summaries_protocolLabels_andTheRunCountMessage() async throws {
        let url = scratch.appendingPathComponent("runs.bciproj")
        let store = try ProjectStore.create(at: url, name: "runs")
        let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
        let session = await workspace.adopt(store)
        let live = session.wire(ConnectController(store: store, projectDirectory: url, demoFile: nil, scan: { [] }))
        XCTAssertEqual(session.startRunDisabledReason, RecordGate.notStreaming)
        live.selectedID = ConnectSource.synthetic.id
        await live.perform(.connect)
        await live.perform(.startPreview)
        XCTAssertEqual(session.startRunDisabledReason, ChannelMapModel.undecided, "an explicit map choice first, as for Record")
        live.recordWithoutPositions()
        XCTAssertNil(session.startRunDisabledReason)

        var draft = ProtocolDraft.grazDefault
        draft.timing = .init(fixationMs: 200, cueMs: 600, restMinMs: 100, restMaxMs: 150)
        draft.trialsPerClass = 2
        draft.runsPerSession = 2
        let p = try await store.createProtocolVersion(draft, basedOn: nil)
        let surface = FakeSurface()
        var options = ProtocolRunner.Options()
        options.startLead = 600_000_000
        let host = try XCTUnwrap(live.runHost())
        session.startRuns(.init(protocolRecord: p, sessionSeed: 7, runsPerSession: 2, display: laptop, framePeriodNanos: 16_666_667),
                          host: host, surface: surface, options: options)
        let runs = try XCTUnwrap(session.runs)
        XCTAssertEqual(session.startRunDisabledReason, StartRunCopy.alreadyRecording)
        for i in 0..<2 {
            if i > 0 {
                XCTAssertTrue(runs.canStartNextRun)
                runs.startNextRun()
            }
            XCTAssertEqual(runs.status?.state, .instructions)
            runs.begin()
            await runs.awaitRun()
            XCTAssertEqual(runs.status?.state, .ended(aborted: false))
            XCTAssertTrue(live.isRecording, "the recording stays open between runs")
        }
        XCTAssertFalse(runs.canStartNextRun, "the session's runs are done")
        XCTAssertEqual(surface.shown, 2)
        XCTAssertEqual(surface.hidden, 2, "one display: the window steps aside after each run")
        try await waitFor { runs.summaries.allSatisfy { $0.timing.rows.last?.1 != "counting…" } }
        XCTAssertEqual(runs.summaries.map(\.runID), ["run01", "run02"])
        XCTAssertEqual(runs.summaries[0].timing.rows.last?.1, "16 events by BrainFlow marker · 0 by nearest timestamp")

        await session.finishRuns()
        XCTAssertTrue(runs.isFinished)
        XCTAssertEqual(surface.closed, 1)
        XCTAssertFalse(live.isRecording)
        XCTAssertEqual(live.state, .streaming, "the stream keeps going after the session")
        let id = try XCTUnwrap(live.lastRecordingID)
        XCTAssertEqual(session.recordings.map(\.id), [id])
        XCTAssertEqual(session.recordingProtocols[id]?.protocolID, p.protocolID)
        let request = session.makeRequest(recordingID: id)
        XCTAssertEqual([request.leftLabel, request.rightLabel], ["cue_left_hand", "cue_right_hand"])
        session.showRecording(id)
        XCTAssertFalse(session.canEvaluate, "2 runs can't be evaluated")
        let handle = try XCTUnwrap(session.selectedRecording)
        let model = EvaluateInspectorModel(manifest: handle.manifest, events: session.eventsByRecording[id] ?? [], latest: nil, defaults: nil,
                                           modelName: { $0 }, protocol: session.recordingProtocols[id], windowEndMs: 4000)
        XCTAssertEqual(model.runs, "Needs at least 3 runs (1 held out, 2 for cross-validation); this recording has 2.")
        XCTAssertFalse(model.hasEnoughRuns)
        XCTAssertNotNil(model.classes)
        XCTAssertTrue(model.misleading.contains { $0.text.hasPrefix("The cue (0.6 s) ends before") }, "the protocol's cue is checked against the window")
        session.dismissRuns()
        XCTAssertNil(session.runs)
        await workspace.close(url)
    }

    private func waitFor(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
