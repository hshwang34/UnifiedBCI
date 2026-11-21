import Foundation
import Synchronization

/// The monotonic clock a run is scheduled on: `HostMonotonicClock` in the app, a fake in tests.
public protocol ProtocolClock: Sendable {
    func nowNanos() -> Int64
    func sleep(untilNanos deadline: Int64) async
}

public struct HostProtocolClock: ProtocolClock {
    public init() {}
    public func nowNanos() -> Int64 { HostMonotonicClock.nowNanos() }
    /// Task.sleep runs on another clock, which may return a little early on this one.
    public func sleep(untilNanos deadline: Int64) async {
        while !Task.isCancelled {
            let wait = deadline - nowNanos()
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait))
        }
    }
}

/// What the participant window shows.
public enum CueFrame: Sendable, Equatable {
    case instructions(String)
    case fixation
    case cue(CueSymbol)
    /// Rest, pause and the end of a run: the background only.
    case blank
}

public struct PresentationToken: Hashable, Sendable {
    public let value: UInt64
}

/// The presentation-callback sink (brief 005, "Timing claims"). The participant window calls
/// it from its display-link callback for the first frame that drew a phase, with that
/// frame's target presentation timestamp converted to `HostMonotonicClock` (by an offset
/// sampled in the same callback). Any thread; returns at once.
public protocol PresentationSink: Sendable {
    func presented(_ token: PresentationToken, atMonotonicNanos: Int64)
}

/// The participant window as the runner sees it (built in brief 005 PR 5).
public protocol CueDisplay: Sendable {
    /// Show `frame` from the first display refresh at or after `atMonotonicNanos`, then report
    /// that refresh to `sink` with `token`. Returns at once. A call drops every frame not yet
    /// drawn whose time is at or after its own; each refresh draws the newest frame due, and
    /// a frame dropped or overtaken before any refresh drew it is never reported.
    func show(_ frame: CueFrame, atMonotonicNanos: Int64, token: PresentationToken, sink: any PresentationSink)
}

/// Where a run's segment and events go: `AcquisitionRunHost` in the app, a fake in tests.
public protocol ProtocolRunHost: Sendable {
    /// Opens the run's segment; returns the recording id.
    func beginRun(runID: String, sessionID: String) async throws -> UUID
    /// Closes the run's segment `stopped`; the stream keeps going.
    func endRun() async
    /// See `AcquisitionSession.recordProtocolEvents`. False when nothing records any more
    /// (the writer stopped: disk full, write error, recording ended).
    func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool
    /// Samples are flowing into the run's recording. False while interrupted or failed, or
    /// once the recording ended (decision #35).
    var isStreaming: Bool { get }
}

/// Drives one run of a protocol version (brief 005): instructions, then fixation → cue →
/// rest per planned trial on an injected monotonic clock, with pause/resume, trial and run
/// aborts, and the disconnect pause.
///
/// Intended times come from the run plan: the first fixation is at `origin`, every phase at
/// `origin` + its planned offset, and a resume moves `origin` so the next trial starts
/// `startLead` after it (pauses shift what happens, not the plan). Presentation times come
/// only from the display's callbacks; the two are stored separately and never copied from
/// each other. At a callback the runner queues the phase's events and inserts the phase's
/// BrainFlow marker; a phase whose callback doesn't come within `presentationTimeout` is
/// stored with `presentedAt` null and associated by the fallback around its intended time.
///
/// Operator commands are non-isolated and take effect at the runner's next step (at most
/// `poll` later).
public actor ProtocolRunner: PresentationSink {
    public struct Options: Sendable {
        public var poll: Int64 = 10_000_000
        /// How long before a phase the display is told about it, so it can draw the first
        /// refresh at or after the phase's time.
        public var lookahead: Int64 = 40_000_000
        public var presentationTimeout: Int64 = 250_000_000
        /// From Space (or Resume) to the next fixation.
        public var startLead: Int64 = 250_000_000
        public init() {}
    }

    public enum PauseReason: String, Sendable { case `operator`, disconnect }

    public enum RunState: Sendable, Equatable {
        case instructions, running
        case paused(PauseReason)
        case ended(aborted: Bool)
        /// The run could not start (no recording, or its plan could not be stored).
        case failed(String)
    }

    public enum Phase: Sendable, Equatable { case none, fixation, cue, rest }

    /// What the operator panel shows. Times are on the runner's clock.
    public struct Status: Sendable, Equatable {
        public var state: RunState = .instructions
        public var runID: String
        public var runIndex: Int
        public var runsPerSession: Int
        public var recordingID: UUID?
        public var trialCount: Int
        /// 0-based trial in progress, or nil before the first and between trials.
        public var trial: Int?
        public var phase: Phase = .none
        public var label: String?
        public var startedAt: Int64?
        /// When the last trial ends if nothing else pauses the run.
        public var plannedEnd: Int64?
        public var abortedTrials: [String] = []
        /// presented − intended, per phase with a callback, in order.
        public var latenessNanos: [Int64] = []
        public var missingPresentations = 0
        /// Why the run ended early: `operator` (Abort run) or `recording_stopped` (an event
        /// could not be recorded, so the run stopped rather than go on unrecorded).
        public var endReason: String?
        /// Labels of events the recording refused; never dropped silently.
        public var unrecordedEvents: [String] = []
    }

    /// BrainFlow marker per event type (brief 005): 1 fixation, 4 cue end (the rest that
    /// starts with it shares its sample), 5 a rest shown after an abort, and the cues from
    /// `cueMarkerBase` + class index. The cue range is disjoint from the phase values for any
    /// class count, so a cue can never be read as another phase; the writer matches by value.
    public static let cueMarkerBase = 10
    public static func marker(for label: String, in p: ProtocolRecord) -> Double {
        switch label {
        case "fixation": return 1
        case "cue_end": return 4
        case "rest": return 5
        default: return Double(cueMarkerBase + (p.classes.firstIndex { $0.label == label } ?? 0))
        }
    }

    private enum Command { case begin, abortTrial, pause, resume, abortRun }

    private struct Step {
        let trial: Int
        let at: Int64
        let frame: CueFrame
        let labels: [String]
        var token: PresentationToken?
    }

    private struct Outstanding {
        let trial: Int
        let intended: Int64
        let deadline: Int64
        let labels: [String]
        let marker: Double
    }

    public let protocolRecord: ProtocolRecord
    public let runID: String
    public let sessionID: String
    public let runIndex: Int
    public let sessionSeed: UInt64
    private let host: any ProtocolRunHost
    private let display: any CueDisplay
    private let clock: any ProtocolClock
    private let store: ProjectStore
    private let options: Options

    private nonisolated let inbox = Mutex<(commands: [Command], presented: [(PresentationToken, Int64)])>(([], []))
    private nonisolated let published: Mutex<Status>
    public nonisolated var status: Status { published.withLock { $0 } }

    private var plan: RunPlan?
    private var origin: Int64 = 0
    private var nextTrial = 0
    private var active: Int?
    private var lastScheduled: Int?
    private var steps: [Step] = []
    private var outstanding: [PresentationToken: Outstanding] = [:]
    private var aborted = Set<Int>()
    private var tokens: UInt64 = 0
    private var ending: (aborted: Bool, at: Int64)?
    /// Set when the host refused an event: the run ends with `recording_stopped`.
    private var recordingLost = false

    public init(protocol p: ProtocolRecord, runID: String, sessionID: String, runIndex: Int, sessionSeed: UInt64,
                host: any ProtocolRunHost, display: any CueDisplay, store: ProjectStore,
                clock: any ProtocolClock = HostProtocolClock(), options: Options = .init()) {
        protocolRecord = p; self.runID = runID; self.sessionID = sessionID; self.runIndex = runIndex; self.sessionSeed = sessionSeed
        self.host = host; self.display = display; self.store = store; self.clock = clock; self.options = options
        published = Mutex(Status(runID: runID, runIndex: runIndex, runsPerSession: p.runsPerSession, trialCount: 2 * p.trialsPerClass))
    }

    // MARK: Commands (operator; any thread)

    /// Space on the instructions screen.
    public nonisolated func begin() { send(.begin) }
    /// Esc: the trial in progress is aborted and excluded, never re-queued (decision #34).
    public nonisolated func abortTrial() { send(.abortTrial) }
    public nonisolated func pause() { send(.pause) }
    /// Ignored while the stream is down (decision #35).
    public nonisolated func resume() { send(.resume) }
    /// ⌘.: ends the run; completed trials stay evaluable.
    public nonisolated func abortRun() { send(.abortRun) }

    private nonisolated func send(_ c: Command) { inbox.withLock { $0.commands.append(c) } }

    public nonisolated func presented(_ token: PresentationToken, atMonotonicNanos: Int64) {
        inbox.withLock { $0.presented.append((token, atMonotonicNanos)) }
        Task { await self.drainPresentations() }
    }

    // MARK: Running

    /// Runs to the end: shows the instructions, waits for `begin`, then the trials. Returns
    /// the final status.
    @discardableResult
    public func run() async -> Status {
        display.show(.instructions(protocolRecord.instructions), atMonotonicNanos: clock.nowNanos(), token: nextToken(), sink: self)
        while true {
            let commands = inbox.withLock { box in defer { box.commands = [] }; return box.commands }
            if commands.contains(where: { if case .abortRun = $0 { true } else { false } }) {
                update { $0.state = .ended(aborted: true) }
                return status
            }
            if commands.contains(where: { if case .begin = $0 { true } else { false } }) { break }
            await clock.sleep(untilNanos: clock.nowNanos() + options.poll)
        }
        do {
            let recordingID = try await host.beginRun(runID: runID, sessionID: sessionID)
            update { $0.recordingID = recordingID }
            do {
                let p = try ProtocolSchedule.plan(protocolRecord, recordingID: recordingID, sessionID: sessionID, runID: runID,
                                                  runIndex: runIndex, sessionSeed: sessionSeed)
                try await store.writeRunPlan(p)
                plan = p
            } catch {
                await host.endRun()
                throw error
            }
        } catch {
            update { $0.state = .failed("\(error)") }
            return status
        }
        let now = clock.nowNanos()
        origin = now + options.startLead
        await record(["run_start"], trial: nil, origin: "protocol", intended: now)
        update { $0.state = .running; $0.startedAt = now }
        while await step() {}
        return status
    }

    /// One pass: callbacks, timeouts, commands, the stream, then due phases. False once ended.
    private func step() async -> Bool {
        guard let plan else { return false }
        await drainPresentations()
        var now = clock.nowNanos()
        for (token, o) in outstanding where o.deadline <= now {
            // A callback handled during an earlier await of this loop already recorded it.
            guard outstanding.removeValue(forKey: token) != nil else { continue }
            update { $0.missingPresentations += 1 }
            await recordPhase(o, presented: nil)
        }
        for c in inbox.withLock({ box in defer { box.commands = [] }; return box.commands }) { await handle(c, now: now) }
        if ending == nil, !host.isStreaming {
            switch status.state {
            case .running: await pauseRun(.disconnect, now: now)
            case .paused(.operator): update { $0.state = .paused(.disconnect) }
            default: break
            }
        }
        now = clock.nowNanos()
        if case .running = status.state, ending == nil {
            if nextTrial < plan.trials.count, fixation(nextTrial) - options.lookahead <= now { schedule(nextTrial) }
            for i in steps.indices where steps[i].token == nil && steps[i].at - options.lookahead <= now { hand(i) }
            steps.removeAll { $0.token != nil && $0.at <= now }
        }
        if let a = active, now >= end(a) { active = nil }
        if let k = lastScheduled, now >= fixation(k), now < end(k) { active = k }
        if case .running = status.state, ending == nil, nextTrial >= plan.trials.count, steps.isEmpty, active == nil {
            ending = (false, now)
        }
        publishPhase(now)
        if recordingLost {
            // Nothing records any more: stop at once, showing blank, and say why.
            steps.removeAll()
            outstanding.removeAll()
            showNow(.blank, now: now, trial: nil, labels: [])
            await host.endRun()
            update { $0.state = .ended(aborted: true); $0.endReason = "recording_stopped"; $0.trial = nil; $0.phase = .none; $0.label = nil }
            return false
        }
        if let ending, outstanding.isEmpty {
            await record(["run_end"], trial: nil, origin: ending.aborted ? "operator" : "protocol", intended: ending.at, abortedRun: ending.aborted ? true : nil)
            await host.endRun()
            let reason: String? = recordingLost ? "recording_stopped" : (ending.aborted ? "operator" : nil)
            update { $0.state = .ended(aborted: ending.aborted || recordingLost); $0.endReason = reason; $0.trial = nil; $0.phase = .none; $0.label = nil }
            return false
        }
        var wake = now + options.poll
        for s in steps { wake = min(wake, s.token == nil ? s.at - options.lookahead : s.at) }
        if case .running = status.state, nextTrial < plan.trials.count { wake = min(wake, fixation(nextTrial) - options.lookahead) }
        if let a = active { wake = min(wake, end(a)) }
        for o in outstanding.values { wake = min(wake, o.deadline) }
        await clock.sleep(untilNanos: max(wake, now + 1))
        return true
    }

    private func handle(_ c: Command, now: Int64) async {
        switch (c, status.state) {
        case (.abortTrial, .running):
            guard let a = active, !aborted.contains(a), ending == nil else { return }
            let phase = phase(of: a, at: now)
            abort(a, origin: "operator", reason: "operator")
            await record(["trial_abort"], trial: a, origin: "operator", intended: now, reason: "operator")
            if phase != .rest {
                steps.removeAll { $0.trial == a }
                // The participant sees rest until the trial's planned end; the next trial
                // keeps its planned time.
                showNow(.blank, now: now, trial: a, labels: ["rest"])
            }
        case (.pause, .running):
            guard ending == nil else { return }
            await record(["pause"], trial: nil, origin: "operator", intended: now, reason: "operator")
            await pauseRun(.operator, now: now)
        case (.resume, .paused):
            guard host.isStreaming else { return }
            await record(["resume"], trial: nil, origin: "operator", intended: now)
            if let plan, nextTrial < plan.trials.count {
                origin = now + options.startLead - Int64(plan.trials[nextTrial].fixationOffsetMs) * 1_000_000
            }
            update { $0.state = .running }
        case (.abortRun, .running), (.abortRun, .paused):
            guard ending == nil else { return }
            ending = (true, now)
            if let a = active, !aborted.contains(a), phase(of: a, at: now) != .rest {
                abort(a, origin: "operator", reason: "run_aborted")
                await record(["trial_abort"], trial: a, origin: "operator", intended: now, reason: "run_aborted")
            }
            steps.removeAll()
            lastScheduled = nil
            active = nil
            showNow(.blank, now: now, trial: nil, labels: [])
        default:
            return
        }
    }

    /// Pause, by the operator (the trial in progress is aborted unless its cue is over) or on
    /// a disconnect (the trial in progress is aborted, decision #35). The next trial follows
    /// the aborted one on Resume.
    private func pauseRun(_ reason: PauseReason, now: Int64) async {
        if reason == .disconnect { await record(["pause"], trial: nil, origin: "protocol", intended: now, reason: "disconnect") }
        if let a = active, !aborted.contains(a), reason == .disconnect || phase(of: a, at: now) != .rest {
            let origin = reason == .operator ? "operator" : "protocol"
            abort(a, origin: origin, reason: reason == .operator ? "pause" : "disconnect")
            await record(["trial_abort"], trial: a, origin: origin, intended: now, reason: reason == .operator ? "pause" : "disconnect")
        }
        // A trial scheduled but not yet started stays next; it was never shown.
        if let k = lastScheduled, k != active { nextTrial = k }
        steps.removeAll()
        lastScheduled = nil
        active = nil
        showNow(.blank, now: now, trial: nil, labels: [])
        update { $0.state = .paused(reason) }
    }

    private func abort(_ trial: Int, origin: String, reason: String) {
        aborted.insert(trial)
        if let id = plan?.trials[trial].trialID { update { $0.abortedTrials.append(id) } }
    }

    /// Steps of trial `k`: fixation, cue (its class label), and the blank that is both
    /// `cue_end` and `rest`.
    private func schedule(_ k: Int) {
        guard let plan else { return }
        let t = plan.trials[k]
        let cue = protocolRecord.classes.first { $0.label == t.label }?.cue ?? .leftArrow
        steps += [Step(trial: k, at: at(t.fixationOffsetMs), frame: .fixation, labels: ["fixation"]),
                  Step(trial: k, at: at(t.cueOffsetMs), frame: .cue(cue), labels: [t.label]),
                  Step(trial: k, at: at(t.cueEndOffsetMs), frame: .blank, labels: ["cue_end", "rest"])]
        nextTrial = k + 1
        lastScheduled = k
    }

    private func hand(_ i: Int) {
        let token = nextToken()
        steps[i].token = token
        let s = steps[i]
        outstanding[token] = .init(trial: s.trial, intended: s.at, deadline: s.at + options.presentationTimeout,
                                   labels: s.labels, marker: Self.marker(for: s.labels[0], in: protocolRecord))
        display.show(s.frame, atMonotonicNanos: s.at, token: token, sink: self)
    }

    /// Shows `frame` now, replacing everything not yet drawn; steps already handed to the
    /// display for later are handed again.
    private func showNow(_ frame: CueFrame, now: Int64, trial: Int?, labels: [String]) {
        for (t, o) in outstanding where o.intended > now { outstanding[t] = nil }
        for i in steps.indices { steps[i].token = nil }
        let token = nextToken()
        if let trial, let first = labels.first {
            outstanding[token] = .init(trial: trial, intended: now, deadline: now + options.presentationTimeout,
                                       labels: labels, marker: Self.marker(for: first, in: protocolRecord))
        }
        display.show(frame, atMonotonicNanos: now, token: token, sink: self)
    }

    private func drainPresentations() async {
        let items = inbox.withLock { box in defer { box.presented = [] }; return box.presented }
        for (token, at) in items {
            guard let o = outstanding.removeValue(forKey: token) else { continue }     // replaced, or timed out
            update { $0.latenessNanos.append(at - o.intended) }
            await recordPhase(o, presented: at)
        }
    }

    private func recordPhase(_ o: Outstanding, presented: Int64?) async {
        let events = o.labels.map { event($0, trial: o.trial, origin: "protocol", intended: o.intended, presented: presented) }
        // No callback: no marker (nothing was seen to present), association by the fallback.
        submit(events, ok: await host.record(events, marker: presented == nil ? nil : o.marker, associateAt: presented ?? o.intended))
    }

    private func record(_ labels: [String], trial: Int?, origin: String, intended: Int64, reason: String? = nil, abortedRun: Bool? = nil) async {
        let events = labels.map { label in
            event(label, trial: trial, origin: origin, intended: intended, presented: nil, reason: reason, abortedRun: abortedRun,
                  plannedLabel: label == "trial_abort" ? trial.flatMap { plan?.trials[$0].label } : nil)
        }
        submit(events, ok: await host.record(events, marker: nil, associateAt: nil))
    }

    /// A refused event is named in the status and ends the run (`recording_stopped`).
    private func submit(_ events: [EventRecord], ok: Bool) {
        guard !ok else { return }
        recordingLost = true
        update { $0.unrecordedEvents += events.map(\.label) }
    }

    private func event(_ label: String, trial: Int?, origin: String, intended: Int64?, presented: Int64?,
                       reason: String? = nil, abortedRun: Bool? = nil, plannedLabel: String? = nil) -> EventRecord {
        EventRecord(eventID: UUID(), sessionID: sessionID, runID: runID, trialID: trial.flatMap { plan?.trials[$0].trialID },
                    label: label, origin: origin, intendedAtMonotonicNanos: intended, presentedAtMonotonicNanos: presented,
                    sourceTimeNanos: nil, wallTime: Date(), sampleAssociation: nil, timingUncertaintyNanos: nil,
                    reason: reason, aborted: abortedRun, plannedLabel: plannedLabel)
    }

    // MARK: Helpers

    private func at(_ offsetMs: Int) -> Int64 { origin + Int64(offsetMs) * 1_000_000 }
    private func fixation(_ k: Int) -> Int64 { at(plan!.trials[k].fixationOffsetMs) }
    private func end(_ k: Int) -> Int64 { at(plan!.trials[k].endOffsetMs) }

    private func phase(of k: Int, at now: Int64) -> Phase {
        guard let t = plan?.trials[k], now >= at(t.fixationOffsetMs) else { return .none }
        if aborted.contains(k) || now >= at(t.cueEndOffsetMs) { return .rest }
        return now >= at(t.cueOffsetMs) ? .cue : .fixation
    }

    private func publishPhase(_ now: Int64) {
        let a = active
        let current: Phase = a.map { self.phase(of: $0, at: now) } ?? .none
        let label = a.flatMap { plan?.trials[$0].label }
        let plannedEnd = plan.flatMap { $0.trials.last.map { at($0.endOffsetMs) } }
        update { $0.trial = a; $0.phase = current; $0.label = label; $0.plannedEnd = plannedEnd }
    }

    private func nextToken() -> PresentationToken {
        tokens += 1
        return PresentationToken(value: tokens)
    }

    private func update(_ change: (inout Status) -> Void) { published.withLock { change(&$0) } }
}

/// The acquisition session as a run's host (brief 004 session, brief 005 runs).
public struct AcquisitionRunHost: ProtocolRunHost {
    public let session: AcquisitionSession
    public let request: AcquisitionSession.RecordingRequest
    public let store: ProjectStore

    public init(session: AcquisitionSession, request: AcquisitionSession.RecordingRequest, store: ProjectStore) {
        self.session = session; self.request = request; self.store = store
    }

    public func beginRun(runID: String, sessionID: String) async throws -> UUID {
        try await session.beginRunSegment(runID: runID, sessionID: sessionID, request: request, in: store)
    }

    public func endRun() async { await session.endRunSegment() }

    public func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool {
        await session.recordProtocolEvents(events, marker: marker, associateAt: associateAt)
    }

    public var isStreaming: Bool {
        let s = session.snapshot
        return s.state == .streaming && s.runSegmentOpen
    }
}
