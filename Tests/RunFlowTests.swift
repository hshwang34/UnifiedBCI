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

    // MARK: Brief 010

    func testTrialAnatomy_toScale() {
        let m = TrialAnatomyModel(graz)
        XCTAssertEqual(m.segments.map(\.title), ["Fixation", "Cue", "Rest"])
        XCTAssertEqual(m.segments.map(\.duration), ["2 s", "4 s", "1.5–2.5 s"])
        XCTAssertEqual(m.segments.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(m.segments[1].fraction, 0.5, accuracy: 1e-9, "the 4 s cue is half of an 8 s mean trial")
        XCTAssertEqual(m.accessibilityLabel, "One trial: Fixation 2 s, then Cue 4 s, then Rest 1.5–2.5 s")
        XCTAssertEqual(StartRunCopy.sessionEstimate(graz, runs: 4), "4 runs · about 21 min 20 s of cues, plus breaks between runs")
    }

    func testOperatorPanel_glanceableParts() {
        let p = graz
        var s = ProtocolRunner.Status(runID: "run02", runIndex: 1, runsPerSession: 4, trialCount: 40)
        var m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0)
        XCTAssertEqual(m.badge.text, "Ready")
        XCTAssertNil(m.step, "no phase strip on the instructions")
        XCTAssertNil(m.trialFraction)
        XCTAssertEqual(m.runDots, [.done, .current, .pending, .pending])
        s.state = .running; s.trial = 10; s.phase = .cue; s.label = "cue_right_hand"; s.startedAt = 0; s.plannedEnd = 100
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 50)
        XCTAssertEqual(m.badge.tone, .live)
        XCTAssertEqual(m.step, .cue)
        XCTAssertEqual(m.cue?.name, "Right hand")
        XCTAssertEqual(m.cue?.symbol, .rightArrow)
        XCTAssertEqual(m.trialFraction, 0.25)
        s.phase = .rest
        XCTAssertNil(OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 50).cue, "the class shows only during its cue")
        s.trial = nil; s.phase = .none
        XCTAssertEqual(OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 50).trialFraction, 0.5, "between trials: planned time")
        s.state = .paused(.operator)
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 50)
        XCTAssertEqual(m.badge.tone, .paused)
        XCTAssertNil(m.step)
        s.state = .paused(.disconnect)
        XCTAssertEqual(OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: false, nowNanos: 50).badge.tone, .problem)
        s.state = .ended(aborted: false)
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 50)
        XCTAssertEqual(m.badge.text, "Complete")
        XCTAssertEqual(m.trialFraction, 1)
        XCTAssertEqual(m.runDots, [.done, .done, .pending, .pending])
        XCTAssertTrue(m.accessibilitySummary.hasPrefix("Complete. Run 2 of 4"))
    }

    func testRunKeys() {
        XCTAssertEqual(RunKey(keyCode: 49, characters: " ", modifiers: []), .space)
        XCTAssertEqual(RunKey(keyCode: 53, characters: "\u{1b}", modifiers: [.capsLock]), .escape, "Caps Lock doesn't count")
        XCTAssertEqual(RunKey(keyCode: 47, characters: ".", modifiers: [.command]), .abortRun)
        XCTAssertNil(RunKey(keyCode: 47, characters: ".", modifiers: []))
        XCTAssertNil(RunKey(keyCode: 49, characters: " ", modifiers: [.command]))
        XCTAssertNil(RunKey(keyCode: 0, characters: "a", modifiers: []))
        for extra: NSEvent.ModifierFlags in [.control, .option, .shift] {
            XCTAssertNil(RunKey(keyCode: 47, characters: ".", modifiers: [.command, extra]), "⌘ plus another modifier is not ⌘.")
            XCTAssertNil(RunKey(keyCode: 53, characters: "\u{1b}", modifiers: extra))
            XCTAssertNil(RunKey(keyCode: 49, characters: " ", modifiers: extra))
        }
    }

    // MARK: Operator panel

    func testOperatorPanel_everyState() {
        let p = graz
        var s = ProtocolRunner.Status(runID: "run02", runIndex: 1, runsPerSession: 4, trialCount: 40)
        var m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0)
        XCTAssertEqual(m.progress, "Run 2 of 4 · 40 trials")
        XCTAssertEqual(m.phase, "Instructions on screen. Press Space when the participant is ready.")
        XCTAssertTrue(m.canBegin && m.canAbortRun)
        XCTAssertTrue(m.shortcuts.hasPrefix("Space begins · "))
        XCTAssertFalse(m.canAbortTrial || m.canPause || m.canResume)
        // Ended: the next run is offered only while one is left; after the last, only Finish.
        XCTAssertEqual(OperatorPanelModel.shortcuts(.ended(aborted: false), moreRuns: true), "Start the next run or finish the session.")
        XCTAssertEqual(OperatorPanelModel.shortcuts(.ended(aborted: false), moreRuns: false), OperatorPanelModel.lastRunDone)
        XCTAssertFalse(OperatorPanelModel.lastRunDone.contains("next run"))

        s.state = .running; s.trial = 16; s.phase = .cue; s.label = "cue_left_hand"
        s.startedAt = 1_000_000_000; s.plannedEnd = 241_000_000_000
        m = OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 84_000_000_000)
        XCTAssertEqual(m.progress, "Run 2 of 4 · Trial 17 of 40")
        XCTAssertEqual(m.phase, "Cue · Left hand")
        XCTAssertEqual(m.time, "Elapsed 1 min 23 s · about 2 min 37 s left")
        XCTAssertTrue(m.canAbortTrial && m.canPause && m.canAbortRun)
        XCTAssertTrue(m.shortcuts.hasPrefix("Space pauses · "), "never \"Space begins\" during a trial")
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
        XCTAssertTrue(m.shortcuts.hasPrefix("Space resumes · "))
        s.state = .paused(.display)
        XCTAssertEqual(OperatorPanelModel(s, protocol: p, runsPerSession: 4, streaming: true, nowNanos: 0).phase,
                       "Participant display changed. Resume fits the window to it again; the trial in progress was aborted.")

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
        // A stall's lateness is named, and the maximum without it given.
        let stalled = TimingSummaryModel(latenessNanos: [2 * ms, 3 * ms, 80 * ms], afterStall: [false, false, true], missing: 0,
                                         framePeriodNanos: 16_666_667, placements: (12, 0))
        XCTAssertEqual(stalled.rows.first { $0.0 == "After a display stall" }?.1, "1 screen change; maximum without them 3.0 ms")
        XCTAssertNil(m.rows.first { $0.0 == "After a display stall" })
        let empty = TimingSummaryModel(latenessNanos: [], missing: 0, framePeriodNanos: 0, placements: nil)
        XCTAssertEqual(empty.rows.map(\.1), ["no presentation callbacks", "counting…"])
    }

    func testRunCountMessage() {
        XCTAssertEqual(RunCountModel.message(runs: 2), "Needs at least 3 runs with cues (1 held out, 2 for cross-validation); this recording has 2.")
        XCTAssertEqual(RunCountModel.message(runs: 4), "4 runs with cues: enough to hold one out and cross-validate on the rest.")
        func e(_ label: String, run: String, trial: String?) -> EventRecord {
            EventRecord(eventID: UUID(), sessionID: "S", runID: run, trialID: trial, label: label, origin: "protocol",
                        intendedAtMonotonicNanos: nil, presentedAtMonotonicNanos: nil, sourceTimeNanos: nil, wallTime: Date(),
                        sampleAssociation: nil, timingUncertaintyNanos: nil, reason: nil, aborted: nil, plannedLabel: nil)
        }
        let events = [
            e("run_start", run: "run01", trial: nil), e("fixation", run: "run01", trial: "run01-t01"), e("cue_left_hand", run: "run01", trial: "run01-t01"),
            e("fixation", run: "run02", trial: "run02-t01"), e("cue_right_hand", run: "run02", trial: "run02-t01"), e("trial_abort", run: "run02", trial: "run02-t01"),
            e("fixation", run: "run03", trial: "run03-t01"), e("trial_abort", run: "run03", trial: "run03-t01"),
            e("run_start", run: "run04", trial: nil), e("cue_right_hand", run: "run04", trial: "run04-t02"),
        ]
        XCTAssertEqual(RunCountModel.evaluableRuns(events), 2, "a run whose only cue was aborted, or that never showed one, can't be split on")
        XCTAssertEqual(RunCountModel.labels(graz), "Classes from Left vs right hand (Graz-style) v1: Left hand (“cue_left_hand”) vs Right hand (“cue_right_hand”).")
    }

    // MARK: A session of runs on the synthetic board

    private final class FakeSurface: CueSurface {
        let timed = TimedDisplay()
        var display: any CueDisplay { timed }
        var onDisplayChange: (() -> Void)?
        var framePeriodNanos: Int64 = 16_666_667
        var displayPresent = true
        var shown = 0, hidden = 0, closed = 0, reframed = 0
        func show() { shown += 1 }
        func hide() { hidden += 1 }
        func close() { closed += 1 }
        func reframe() -> Bool { reframed += 1; return displayPresent }
        /// Brief 010: every participant card asked for, in order.
        var cards: [ParticipantScreen?] = []
        var context: ParticipantRunContext?
        func showParticipant(_ screen: ParticipantScreen?, context: ParticipantRunContext?) {
            cards.append(screen)
            if let context { self.context = context }
        }
    }

    /// Key repeats and second presses never abort another trial; a display change pauses the
    /// run, and Resume re-frames (and refuses while the display is gone).
    func testRepeatsAreSwallowed_abortIsOncePerTrial_displayChangePausesAndReframes() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("keys.bciproj"), name: "keys")
        var draft = ProtocolDraft.grazDefault
        draft.timing = .init(fixationMs: 200, cueMs: 1500, restMinMs: 100, restMaxMs: 100)
        draft.trialsPerClass = 2
        let p = try await store.createProtocolVersion(draft, basedOn: nil)
        let surface = FakeSurface()
        let runs = RunController(setup: .init(protocolRecord: p, sessionSeed: 1, runsPerSession: 1, display: external, framePeriodNanos: 16_666_667),
                                 host: FakeHost(store: store), store: store, surface: surface, onRecording: { _ in }, stopRecording: {})
        runs.startNextRun()
        XCTAssertEqual(surface.cards, [.instructions], "brief 010: the instructions card first")
        XCTAssertEqual(surface.context, ParticipantRunContext(runIndex: 0, runsPerSession: 1, protocolRecord: p))
        XCTAssertTrue(runs.press(.space, isRepeat: true), "a repeat is consumed")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runs.status?.state, .instructions, "…without acting")
        runs.press(.space, isRepeat: false)
        XCTAssertEqual(surface.cards.last, .some(nil), "Space dismisses the card at once, during the start lead")
        try await waitFor { runs.status?.phase == .cue && runs.status?.trial == 0 }
        runs.press(.escape, isRepeat: false)
        for _ in 0..<5 { runs.press(.escape, isRepeat: true) }
        runs.press(.escape, isRepeat: false)                   // a second press for the same trial
        try await waitFor { runs.status?.trial == 1 && runs.status?.phase == .cue }
        XCTAssertEqual(runs.status?.abortedTrials.count, 1, "one abort for trial 1; trial 2 untouched")

        surface.onDisplayChange?()
        try await waitFor { runs.status?.state == .paused(.display) }
        XCTAssertEqual(runs.status?.abortedTrials.count, 2, "the trial on screen is aborted, as on a disconnect")
        try await waitFor { surface.cards.last == .paused }
        surface.displayPresent = false
        runs.resume()
        XCTAssertEqual(runs.resumeProblem, OperatorPanelModel.displayGone)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runs.status?.state, .paused(.display), "no resume onto a missing display")
        surface.displayPresent = true
        surface.framePeriodNanos = 8_333_333
        runs.resume()
        XCTAssertNil(runs.resumeProblem)
        XCTAssertEqual(runs.setup.framePeriodNanos, 8_333_333, "the frame period is read again")
        try await waitFor { runs.status?.state == .running }
        XCTAssertEqual(surface.cards.last, .some(nil), "running: no card")
        runs.press(.abortRun, isRepeat: false)
        await runs.awaitRun()
        XCTAssertEqual(runs.status?.state, .ended(aborted: true))
        XCTAssertEqual(surface.reframed, 2)
        XCTAssertEqual(surface.cards.last, .sessionDone, "the session's only run ended")
        XCTAssertEqual(surface.cards.filter { $0 == .instructions }.count, 1, "instructions only before the first trial")
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
        // A loaded runner may miss a marker; the nearest-timestamp fallback is legitimate,
        // flagged behaviour, so only the total and the copy's shape are fixed.
        let association = try XCTUnwrap(runs.summaries[0].timing.rows.last?.1)
        let counts = association.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(counts.count, 2, association)
        XCTAssertEqual(association, "\(counts.first ?? -1) events by BrainFlow marker · \(counts.last ?? -1) by nearest timestamp")
        XCTAssertEqual(counts.reduce(0, +), 16, association)

        await session.finishRuns()
        XCTAssertTrue(runs.isFinished)
        XCTAssertEqual(surface.closed, 1)
        XCTAssertFalse(live.isRecording)
        XCTAssertEqual(live.state, .streaming, "the stream keeps going after the session")
        let id = try XCTUnwrap(live.lastRecordingID)
        XCTAssertEqual(session.recordings.map(\.id), [id])
        let fallbacks = (session.eventsByRecording[id] ?? []).filter { $0.sampleAssociation?.method != "brainflow_marker" && $0.sampleAssociation != nil }
        for e in fallbacks {
            XCTAssertEqual(e.sampleAssociation?.method, "nearest_receipt_timestamp", e.label)
            XCTAssertNotNil(e.timingUncertaintyNanos, "a fallback carries its software spread (\(e.label))")
        }
        XCTAssertEqual(session.recordingProtocols[id]?.protocolID, p.protocolID)
        let request = session.makeRequest(recordingID: id)
        XCTAssertEqual([request.leftLabel, request.rightLabel], ["cue_left_hand", "cue_right_hand"])
        session.showRecording(id)
        XCTAssertFalse(session.canEvaluate, "2 runs can't be evaluated")
        let handle = try XCTUnwrap(session.selectedRecording)
        let model = EvaluateInspectorModel(manifest: handle.manifest, events: session.eventsByRecording[id] ?? [], latest: nil, defaults: nil,
                                           modelName: { $0 }, protocol: session.recordingProtocols[id], windowEndMs: 4000)
        XCTAssertEqual(model.runs, "Needs at least 3 runs with cues (1 held out, 2 for cross-validation); this recording has 2.")
        XCTAssertFalse(model.hasEnoughRuns)
        XCTAssertNotNil(model.classes)
        XCTAssertTrue(model.misleading.contains { $0.text.hasPrefix("The cue (0.6 s) ends before") }, "the protocol's cue is checked against the window")
        session.dismissRuns()
        XCTAssertNil(session.runs)

        // ⌘Q mid-run: closeAll → shutdown tears the run down, closes the participant window
        // and ends the recording `stopped`.
        let quitSurface = FakeSurface()
        session.startRuns(.init(protocolRecord: p, sessionSeed: 8, runsPerSession: 2, display: external, framePeriodNanos: 16_666_667),
                          host: try XCTUnwrap(live.runHost()), surface: quitSurface, options: options)
        let quitting = try XCTUnwrap(session.runs)
        quitting.begin()
        try await waitFor { quitting.status?.phase == .cue }
        await workspace.closeAll()
        XCTAssertEqual(quitSurface.closed, 1)
        XCTAssertTrue(session.isShutDown)
        XCTAssertEqual(live.session?.snapshot.state, .disconnected)
        XCTAssertNil(live.session?.snapshot.recordingID, "the recording ended")
    }

    private func waitFor(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
