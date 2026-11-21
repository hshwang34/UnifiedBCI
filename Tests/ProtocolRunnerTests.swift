import Synchronization
import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 3: `ProtocolRunner` on a fake clock, display and host; the acquisition
/// session's run segments and event association on the fake board; and an end-to-end run on
/// BrainFlow's synthetic board through the worker. No hardware (decision #26).
final class ProtocolRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func store() throws -> ProjectStore {
        try ProjectStore.create(at: scratch.appendingPathComponent("p.bciproj"), name: "p")
    }

    private struct Fixture {
        let store: ProjectStore
        let proto: ProtocolRecord
        let clock: FakeClock
        let display: FakeDisplay
        let host: FakeHost
        let runner: ProtocolRunner
    }

    private func fixture(_ draft: ProtocolDraft = .grazDefault) async throws -> Fixture {
        let store = try store()
        _ = try await store.ensureDefaultProtocol()
        let proto = try await store.protocols().protocols[0]
        let p = draft == .grazDefault ? proto : try await store.createProtocolVersion(draft, basedOn: nil)
        let host = FakeHost(store: store)
        let clock = FakeClock(), display = FakeDisplay()
        var o = ProtocolRunner.Options()
        o.poll = 1_000_000_000
        let runner = ProtocolRunner(protocol: p, runID: "run01", sessionID: "S1", runIndex: 0, sessionSeed: 42, host: host,
                                    display: display, store: store, clock: clock, options: o)
        display.runner.withLock { $0 = runner }
        return Fixture(store: store, proto: p, clock: clock, display: display, host: host, runner: runner)
    }

    private func plan(_ f: Fixture) async throws -> RunPlan {
        try await f.store.runPlans(recording: XCTUnwrap(f.host.recordingID)).plans[0]
    }

    // MARK: Fake clock

    func testFullDefaultRun_40TrialsTimesFourPhaseEvents_onSchedule_presentedSeparately() async throws {
        let f = try await fixture()
        f.display.lateness = 3_000_000
        f.runner.begin()
        let final = await f.runner.run()
        XCTAssertEqual(final.state, .ended(aborted: false))
        let plan = try await plan(f)
        let records = f.host.records
        let events = records.flatMap(\.events)
        XCTAssertEqual(events.count, 40 * 4 + 2)
        XCTAssertEqual(events.first?.label, "run_start")
        XCTAssertEqual(events.last?.label, "run_end")
        XCTAssertNil(events.last?.aborted)
        let origin = try XCTUnwrap(events.first?.intendedAtMonotonicNanos) + ProtocolRunner.Options().startLead
        for t in plan.trials {
            let mine = events.filter { $0.trialID == t.trialID }
            XCTAssertEqual(mine.map(\.label), ["fixation", t.label, "cue_end", "rest"])
            let ms = { (off: Int) in origin + Int64(off) * 1_000_000 }
            XCTAssertEqual(mine.map(\.intendedAtMonotonicNanos), [ms(t.fixationOffsetMs), ms(t.cueOffsetMs), ms(t.cueEndOffsetMs), ms(t.cueEndOffsetMs)])
            XCTAssertEqual(mine.map(\.presentedAtMonotonicNanos), mine.map { $0.intendedAtMonotonicNanos! + 3_000_000 })
            XCTAssertTrue(mine.allSatisfy { $0.origin == "protocol" && $0.sessionID == "S1" && $0.runID == "run01" && $0.timingUncertaintyNanos == nil })
        }
        let phaseRecords = records.filter { $0.marker != nil }
        XCTAssertEqual(phaseRecords.count, 40 * 3, "cue end and rest share one presentation and one marker")
        XCTAssertTrue(phaseRecords.allSatisfy { $0.associateAt == $0.events[0].presentedAtMonotonicNanos })
        XCTAssertEqual(Set(phaseRecords.map { $0.marker! }), [1, 2, 3, 4])
        XCTAssertEqual(final.latenessNanos, Array(repeating: 3_000_000, count: 120))
        XCTAssertEqual(f.host.begins, 1)
        XCTAssertEqual(f.host.ends, 1)
        XCTAssertEqual(f.display.frames.first, .instructions(f.proto.instructions))
        XCTAssertEqual(f.display.frames.filter { if case .cue = $0 { true } else { false } }.count, 40)
    }

    func testAbortTrial_markedAborted_restShown_neverRequeued_nextTrialOnPlan() async throws {
        let f = try await fixture()
        f.display.onShow = { frame, n, runner in if case .cue = frame, n.cues == 3 { runner.abortTrial() } }
        f.runner.begin()
        let final = await f.runner.run()
        let plan = try await plan(f)
        let events = f.host.records.flatMap(\.events)
        let third = plan.trials[2]
        XCTAssertEqual(events.filter { $0.trialID == third.trialID }.map(\.label), ["fixation", third.label, "trial_abort", "rest"])
        let abort = try XCTUnwrap(events.first { $0.label == "trial_abort" })
        XCTAssertEqual(abort.origin, "operator")
        XCTAssertEqual(abort.reason, "operator")
        XCTAssertEqual(final.abortedTrials, [third.trialID])
        XCTAssertEqual(f.host.records.first { $0.events[0].label == "rest" && $0.events.count == 1 }?.marker, 5)
        XCTAssertEqual(events.filter { $0.label == "fixation" }.count, 40, "the aborted trial is not run again (decision #34)")
        let origin = events[0].intendedAtMonotonicNanos! + ProtocolRunner.Options().startLead
        XCTAssertEqual(events.first { $0.trialID == plan.trials[3].trialID }?.intendedAtMonotonicNanos,
                       origin + Int64(plan.trials[3].fixationOffsetMs) * 1_000_000)
    }

    func testPauseDuringFixation_abortsThatTrial_resumeStartsTheNextAfterTheLead() async throws {
        let f = try await fixture()
        f.display.onShow = { [clock = f.clock] frame, n, runner in
            if frame == .fixation, n.fixations == 5 {
                let t = clock.nowNanos() + ProtocolRunner.Options().lookahead      // the fixation's time
                clock.at(t + 500_000_000) { runner.pause() }
                clock.at(t + 10_000_000_000) { runner.resume() }
            }
        }
        f.runner.begin()
        _ = await f.runner.run()
        let plan = try await plan(f)
        let events = f.host.records.flatMap(\.events)
        let pause = try XCTUnwrap(events.first { $0.label == "pause" })
        XCTAssertEqual([pause.origin, pause.reason] as [String?], ["operator", "operator"])
        let abort = try XCTUnwrap(events.first { $0.label == "trial_abort" })
        XCTAssertEqual([abort.trialID, abort.reason] as [String?], [plan.trials[4].trialID, "pause"])
        let resume = try XCTUnwrap(events.first { $0.label == "resume" })
        XCTAssertGreaterThanOrEqual(resume.intendedAtMonotonicNanos! - pause.intendedAtMonotonicNanos!, 9_000_000_000)
        XCTAssertEqual(events.first { $0.trialID == plan.trials[5].trialID }?.intendedAtMonotonicNanos,
                       resume.intendedAtMonotonicNanos! + ProtocolRunner.Options().startLead)
        XCTAssertEqual(events.filter { $0.label == "fixation" }.count, 40)
        XCTAssertEqual(events.filter { $0.trialID == plan.trials[4].trialID }.map(\.label), ["fixation", "trial_abort"])
    }

    func testDisconnect_abortsAndPauses_resumeOnlyAfterReconnect_continuesInTheNewSegment() async throws {
        let f = try await fixture()
        f.display.onShow = { [clock = f.clock, host = f.host] frame, n, runner in
            guard case .cue = frame, n.cues == 7 else { return }
            host.streaming.withLock { $0 = false }
            let t = clock.nowNanos()
            clock.at(t + 2_000_000_000) { runner.resume() }               // refused: still down
            clock.at(t + 5_000_000_000) { host.reconnect() }
            clock.at(t + 6_000_000_000) { runner.resume() }
        }
        f.runner.begin()
        let final = await f.runner.run()
        XCTAssertEqual(final.state, .ended(aborted: false))
        let plan = try await plan(f)
        let records = f.host.records
        let events = records.flatMap(\.events)
        let pause = try XCTUnwrap(events.first { $0.label == "pause" })
        XCTAssertEqual([pause.origin, pause.reason] as [String?], ["protocol", "disconnect"])
        let abort = try XCTUnwrap(events.first { $0.label == "trial_abort" })
        XCTAssertEqual([abort.trialID, abort.origin, abort.reason] as [String?], [plan.trials[6].trialID, "protocol", "disconnect"])
        XCTAssertEqual(events.filter { $0.label == "resume" }.count, 1)
        let resume = try XCTUnwrap(events.first { $0.label == "resume" })
        XCTAssertGreaterThanOrEqual(resume.intendedAtMonotonicNanos! - pause.intendedAtMonotonicNanos!, 6_000_000_000)
        let next = try XCTUnwrap(records.first { $0.events[0].trialID == plan.trials[7].trialID })
        XCTAssertEqual(next.segment, 1, "the next planned trial continues in the new segment (decision #35)")
        XCTAssertEqual(events.filter { $0.label == "fixation" }.count, 40)
    }

    func testAbortRun_endsWithRunEndAborted_closesTheSegment_keepsCompletedTrials() async throws {
        let f = try await fixture()
        f.display.onShow = { frame, n, runner in if case .cue = frame, n.cues == 2 { runner.abortRun() } }
        f.runner.begin()
        let final = await f.runner.run()
        XCTAssertEqual(final.state, .ended(aborted: true))
        let plan = try await plan(f)
        let events = f.host.records.flatMap(\.events)
        XCTAssertEqual(events.last?.label, "run_end")
        XCTAssertEqual(events.last?.aborted, true)
        XCTAssertEqual(events.last?.origin, "operator")
        XCTAssertEqual(events.first { $0.label == "trial_abort" }.map { [$0.trialID, $0.reason] }, [plan.trials[1].trialID, "run_aborted"])
        XCTAssertEqual(events.filter { $0.trialID == plan.trials[0].trialID }.map(\.label), ["fixation", plan.trials[0].label, "cue_end", "rest"])
        XCTAssertEqual(events.filter { $0.label == "fixation" }.count, 2)
        XCTAssertEqual(f.host.ends, 1)
    }

    func testMissingCallback_presentedAtNull_noMarker_fallbackAtTheIntendedTime() async throws {
        let f = try await fixture()
        f.display.drop = { frame, n in if case .cue = frame { n.cues == 1 } else { false } }
        f.runner.begin()
        let final = await f.runner.run()
        let plan = try await plan(f)
        let cue = try XCTUnwrap(f.host.records.first { $0.events[0].label == plan.trials[0].label && $0.events[0].trialID == plan.trials[0].trialID })
        XCTAssertNil(cue.events[0].presentedAtMonotonicNanos)
        XCTAssertNil(cue.marker)
        XCTAssertEqual(cue.associateAt, cue.events[0].intendedAtMonotonicNanos)
        XCTAssertEqual(final.missingPresentations, 1)
        XCTAssertEqual(final.latenessNanos.count, 119)
    }

    func testAbortBeforeSpace_recordsNothing() async throws {
        let f = try await fixture()
        f.runner.abortRun()
        let final = await f.runner.run()
        XCTAssertEqual(final.state, .ended(aborted: true))
        XCTAssertEqual(f.host.begins, 0)
        XCTAssertTrue(f.host.records.isEmpty)
    }

    // MARK: Session run segments and association (fake board)

    func testSessionRuns_segmentPerRun_markersAssociate_failedMarkerFallsBack_nothingCountedLostBetweenRuns() async throws {
        let store = try store()
        let link = FakeLink()
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let d = link.description
        let channels = d.eegChannelRows.enumerated().map { ChannelSpec(id: String(format: "ch%02d", $0 + 1), label: "undeclared", kind: "eeg", unit: "uV", sourceRow: $1) }
        let host = AcquisitionRunHost(session: session, request: .init(channels: channels, reference: "SRB2", montage: "undeclared"), store: store)
        func ev(_ label: String, _ run: String) -> EventRecord {
            EventRecord(eventID: UUID(), sessionID: "S", runID: run, trialID: "\(run)-t01", label: label, origin: "protocol",
                        intendedAtMonotonicNanos: 1, presentedAtMonotonicNanos: 2, sourceTimeNanos: nil, wallTime: Date(),
                        sampleAssociation: nil, timingUncertaintyNanos: nil)
        }
        let id = try await host.beginRun(runID: "run01", sessionID: "S")
        XCTAssertTrue(host.isStreaming)
        try await waitFor { link.delivered > 60 }
        await host.record([ev("cue_left_hand", "run01")], marker: 2, associateAt: HostMonotonicClock.nowNanos())
        try await waitFor { link.delivered > 160 }
        link.set { $0.markerFails = true }
        await host.record([ev("fixation", "run01")], marker: 1, associateAt: HostMonotonicClock.nowNanos())
        link.set { $0.markerFails = false }
        try await waitFor { link.delivered > 260 }
        await host.record([ev("run_end", "run01")], marker: nil, associateAt: nil)
        await host.endRun()
        XCTAssertFalse(host.isStreaming)
        try await waitFor { link.delivered > 360 }                   // between runs: not recorded
        let again = try await host.beginRun(runID: "run02", sessionID: "S")
        XCTAssertEqual(again, id)
        await host.record([ev("cue_end", "run02"), ev("rest", "run02")], marker: 4, associateAt: HostMonotonicClock.nowNanos())
        try await waitFor { link.delivered > 460 }
        await host.endRun()
        _ = await session.stopRecording()
        await session.disconnect()

        let rec = try await store.recording(id: id)
        let m = rec.manifest
        XCTAssertEqual(m.segments.map(\.runID), ["run01", "run02"])
        XCTAssertEqual(m.segments.map(\.endReason), [.stopped, .stopped])
        XCTAssertEqual(m.segments.map(\.uncommittedSampleCount), [nil, nil], "samples between runs are not losses")
        XCTAssertEqual(m.segments.map(\.detectedGaps), [[], []])
        XCTAssertEqual(m.timing.markerRow, d.markerRow)
        let events = try rec.events()
        XCTAssertEqual(events.map(\.label), ["cue_left_hand", "fixation", "run_end", "cue_end", "rest"])
        let cue = try XCTUnwrap(events[0].sampleAssociation)
        XCTAssertEqual(cue.segment, 0)
        XCTAssertEqual(cue.method, "brainflow_marker")
        let entry = try XCTUnwrap(rec.chunks(inSegment: 0).first { ($0.firstSampleIndex..<($0.firstSampleIndex + $0.sampleCount)).contains(cue.sampleIndex) })
        XCTAssertEqual(try rec.chunk(entry)[d.markerRow * entry.sampleCount + cue.sampleIndex - entry.firstSampleIndex], 2,
                       "the association names the sample BrainFlow marked")
        XCTAssertEqual(events[1].sampleAssociation?.method, "nearest_receipt_timestamp")
        XCTAssertNil(events[2].sampleAssociation)
        XCTAssertEqual(events[3].sampleAssociation, events[4].sampleAssociation)
        XCTAssertEqual(events[3].sampleAssociation?.segment, 1)
        XCTAssertEqual(events[3].sampleAssociation?.method, "brainflow_marker")
    }

    // MARK: Synthetic board end to end, through the worker

    @MainActor
    func testSyntheticBoard_fourShortRuns_evaluateWithProtocolLabels_onlyTheAbortedTrialExcluded() async throws {
        let store = try store()
        let draft = ProtocolDraft(name: "Short", classes: ProtocolDraft.grazDefault.classes,
                                  timing: .init(fixationMs: 250, cueMs: 800, restMinMs: 100, restMaxMs: 150),
                                  trialsPerClass: 2, runsPerSession: 4, instructions: "Short test run.")
        let p = try await store.createProtocolVersion(draft, basedOn: nil)
        let session = AcquisitionSession(source: .synthetic, projectDirectory: store.directory)
        await session.connect()
        await session.startStreaming()
        let d = try BrainFlowBoard.describe(boardID: KnownBoard.synthetic)
        let channels = d.eegChannelRows.enumerated().map { ChannelSpec(id: String(format: "ch%02d", $0 + 1), label: "undeclared", kind: "eeg", unit: "uV", sourceRow: $1) }
        let host = AcquisitionRunHost(session: session, request: .init(channels: channels, reference: "SRB2", montage: "undeclared"), store: store)
        var o = ProtocolRunner.Options()
        o.startLead = 600_000_000            // first window starts after the 0.55 s filter warm-up
        var aborted: String?
        for i in 0..<4 {
            let display = TimedDisplay()
            let runner = ProtocolRunner(protocol: p, runID: "run0\(i + 1)", sessionID: "S-e2e", runIndex: i, sessionSeed: 1000,
                                        host: host, display: display, store: store, options: o)
            if i == 1 {
                // Mid-cue, so the trial has a cue event to exclude (an abort during fixation
                // has none: the cue was never shown).
                display.onShow = { frame, n, at in
                    guard case .cue = frame, n == 2 else { return }
                    Task.detached { await HostProtocolClock().sleep(untilNanos: at + 300_000_000); runner.abortTrial() }
                }
            }
            runner.begin()
            let final = await runner.run()
            XCTAssertEqual(final.state, .ended(aborted: false))
            XCTAssertEqual(final.missingPresentations, 0)
            if i == 1 { aborted = final.abortedTrials.first }
        }
        let id = try XCTUnwrap(session.snapshot.recordingID)
        _ = await session.stopRecording()
        await session.disconnect()

        let rec = try await store.recording(id: id)
        let events = try rec.events()
        let phase = events.filter { ["fixation", "cue_end", "rest", "cue_left_hand", "cue_right_hand"].contains($0.label) }
        XCTAssertTrue(phase.allSatisfy { $0.sampleAssociation?.method == "brainflow_marker" && $0.presentedAtMonotonicNanos != nil },
                      "\(phase.filter { $0.sampleAssociation?.method != "brainflow_marker" }.map(\.label))")
        XCTAssertEqual(rec.manifest.segments.map(\.runID), ["run01", "run02", "run03", "run04"])
        let plans = try await store.runPlans(recording: id).plans
        let usage = try await store.protocolUsage()
        XCTAssertEqual(plans.count, 4)
        XCTAssertEqual(usage[p.protocolID], 4)

        let launch = try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
        let evaluation = EvaluationRunner(store: store, launch: launch)
        var request = EvaluationRunner.Request(recordingID: id, seed: 0)
        request.leftLabel = "cue_left_hand"; request.rightLabel = "cue_right_hand"
        request.windowOffsetSeconds = 0.1; request.windowLengthSeconds = 0.6
        let state = await evaluation.evaluateAndWait(request)
        await evaluation.shutdown()
        guard case .done(let resultID) = state else { return XCTFail("\(state)") }
        let json = try JSONSerialization.jsonObject(with: try await store.result(id: resultID).evaluationJSON) as? [String: Any]
        let exclusions = try XCTUnwrap(json?["exclusions"] as? [[String: Any]])
        XCTAssertEqual(exclusions.map { $0["reason"] as? String }, ["trial_aborted"])
        XCTAssertEqual(exclusions.first?["trial_id"] as? String, aborted)
        let source = try XCTUnwrap(json?["data_source"] as? [String: Any])
        XCTAssertEqual(source["n_runs"] as? Int, 4)
        XCTAssertEqual(source["n_trials"] as? Int, 16)
    }

    private func waitFor(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Jumps to every deadline at once and runs the actions scheduled up to it.
final class FakeClock: ProtocolClock {
    private let state = Mutex<(now: Int64, actions: [(at: Int64, run: @Sendable () -> Void)])>((1_000_000_000_000, []))

    func nowNanos() -> Int64 { state.withLock { $0.now } }

    func at(_ t: Int64, _ action: @escaping @Sendable () -> Void) { state.withLock { $0.actions.append((t, action)) } }

    func sleep(untilNanos deadline: Int64) async {
        let due = state.withLock { s -> [@Sendable () -> Void] in
            s.now = max(s.now, deadline)
            let now = s.now
            defer { s.actions.removeAll { $0.at <= now } }
            return s.actions.filter { $0.at <= now }.map(\.run)
        }
        due.forEach { $0() }
        for _ in 0..<3 { await Task.yield() }
    }
}

/// Reports every frame at once, `lateness` after its time, unless `drop` says otherwise.
final class FakeDisplay: CueDisplay, @unchecked Sendable {
    struct Counts { var fixations = 0, cues = 0 }
    private let lock = NSLock()
    private var _frames: [CueFrame] = []
    private var counts = Counts()
    var lateness: Int64 = 0
    var onShow: ((CueFrame, Counts, ProtocolRunner) -> Void)?
    var drop: ((CueFrame, Counts) -> Bool)?
    let runner = Mutex<ProtocolRunner?>(nil)
    var frames: [CueFrame] { lock.withLock { _frames } }

    func show(_ frame: CueFrame, atMonotonicNanos at: Int64, token: PresentationToken, sink: any PresentationSink) {
        let n = lock.withLock { () -> Counts in
            _frames.append(frame)
            if frame == .fixation { counts.fixations += 1 }
            if case .cue = frame { counts.cues += 1 }
            return counts
        }
        if !(drop?(frame, n) ?? false) { sink.presented(token, atMonotonicNanos: at + lateness) }
        if let r = runner.withLock({ $0 }) { onShow?(frame, n, r) }
    }
}

/// Draws each frame at its time on the host clock, unless a later call dropped it.
final class TimedDisplay: CueDisplay, @unchecked Sendable {
    private final class Box: Sendable { let pending = Mutex<[PresentationToken: Int64]>([:]) }
    private let box = Box()
    private let cues = Mutex(0)
    var onShow: ((CueFrame, Int, Int64) -> Void)?

    func show(_ frame: CueFrame, atMonotonicNanos at: Int64, token: PresentationToken, sink: any PresentationSink) {
        box.pending.withLock { p in p = p.filter { $0.value < at }; p[token] = at }
        let n = cues.withLock { c in if case .cue = frame { c += 1 }; return c }
        Task.detached { [box] in
            await HostProtocolClock().sleep(untilNanos: at)
            if box.pending.withLock({ $0.removeValue(forKey: token) }) != nil { sink.presented(token, atMonotonicNanos: HostMonotonicClock.nowNanos()) }
        }
        onShow?(frame, n, at)
    }
}

/// Records what a run hands its host; one recording in a real store, so plans validate.
final class FakeHost: ProtocolRunHost, @unchecked Sendable {
    struct Record { var events: [EventRecord]; var marker: Double?; var associateAt: Int64?; var segment: Int }
    let store: ProjectStore
    let streaming = Mutex(true)
    private let state = Mutex<(records: [Record], begins: Int, ends: Int, segment: Int, recordingID: UUID?)>(([], 0, 0, 0, nil))

    init(store: ProjectStore) { self.store = store }

    var records: [Record] { state.withLock { $0.records } }
    var begins: Int { state.withLock { $0.begins } }
    var ends: Int { state.withLock { $0.ends } }
    var recordingID: UUID? { state.withLock { $0.recordingID } }
    var isStreaming: Bool { streaming.withLock { $0 } }

    func reconnect() {
        state.withLock { $0.segment += 1 }
        streaming.withLock { $0 = true }
    }

    func beginRun(runID: String, sessionID: String) async throws -> UUID {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let m = RecordingManifest(
            recordingID: UUID(), sessionID: sessionID, runID: runID, createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0)], reference: "SRB2", montage: "undeclared",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0), boardConfiguration: .init(requested: [:], readback: [:]), chunks: [], segments: [])
        _ = try await store.createRecording(m)
        state.withLock { $0.begins += 1; $0.recordingID = m.recordingID }
        return m.recordingID
    }

    func endRun() async { state.withLock { $0.ends += 1 } }

    func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async {
        state.withLock { $0.records.append(.init(events: events, marker: marker, associateAt: associateAt, segment: $0.segment)) }
    }
}
