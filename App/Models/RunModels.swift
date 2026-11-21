import Foundation

// Brief 005 PR 6: Start run…, the operator panel and the timing summary. Every string those
// screens show is built here (locale-independent Fmt), so tests check copy without rendering.

/// What the Start run… sheet picks (decisions #36, #37).
struct StartRunForm: Equatable {
    var protocols: [ProtocolRecord]
    var protocolID: UUID?
    var seedText: String
    var runsPerSession: Int
    var displays: [CueDisplayInfo]
    var displayID: UInt32?

    /// Newest version of each lineage first; the default protocol is picked when nothing is.
    init(protocols: [ProtocolRecord], displays: [CueDisplayInfo], remembered: CueDisplayPicker.Remembered?,
         seed: UInt64 = StartRunForm.newSeed()) {
        self.protocols = protocols.sorted { ($0.name, -$0.version) < ($1.name, -$1.version) }
        let first = self.protocols.first
        protocolID = first?.protocolID
        seedText = String(seed)
        runsPerSession = first?.runsPerSession ?? ProtocolDraft.grazDefault.runsPerSession
        self.displays = displays
        displayID = CueDisplayPicker.choose(from: displays, remembered: remembered)?.display.id
    }

    /// Readable six-digit seeds; any UInt64 typed in is accepted.
    static func newSeed() -> UInt64 { UInt64.random(in: 100_000...999_999) }

    var selected: ProtocolRecord? { protocols.first { $0.protocolID == protocolID } }
    var display: CueDisplayInfo? { displays.first { $0.id == displayID } }
    var seed: UInt64? {
        let t = seedText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 20, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) else { return nil }
        return UInt64(t)
    }

    /// Picking a protocol takes its runs per session as the new default.
    mutating func pick(_ id: UUID) {
        protocolID = id
        if let p = selected { runsPerSession = p.runsPerSession }
    }

    /// Why Start is disabled; nil when it can be pressed.
    func disabledReason(streamReason: String?) -> String? {
        if let streamReason { return streamReason }
        if selected == nil { return StartRunCopy.noProtocol }
        if seed == nil { return StartRunCopy.badSeed }
        if !(1...ProtocolRecord.maxRunsPerSession).contains(runsPerSession) { return StartRunCopy.badRuns }
        if display == nil { return StartRunCopy.noDisplay }
        return nil
    }
}

enum StartRunCopy {
    static let button = "Start Run…"
    static let buttonHelp = "Run a cued protocol: the participant window shows the cues, and every run is recorded with its events."
    static let title = "Start Run"
    static let protocolLabel = "Protocol"
    static let seedLabel = "Session seed"
    static let seedHelp = "Sets every run's trial order and rests (run seed = session seed + run index). Stored with each run, so the order can be reproduced."
    static let newSeed = "New Seed"
    static let runsLabel = "Runs per session"
    static let displayLabel = "Participant display"
    static let start = "Start"
    static let cancel = "Cancel"
    static let noProtocol = "Choose a protocol."
    static let badSeed = "The seed must be a whole number from 0 to 18446744073709551615."
    static let badRuns = "Runs per session must be 1–\(ProtocolRecord.maxRunsPerSession)."
    static let noDisplay = "No display is available for the participant window."
    static let alreadyRecording = "Stop the current recording first."
    static let nextRunNote = "The next run starts on the same recording, as a new segment."
    static let displayGone = "The chosen display is no longer connected. Pick another display."

    static func protocolTitle(_ p: ProtocolRecord) -> String { "\(p.name) · v\(p.version)" }

    static func protocolSummary(_ p: ProtocolRecord) -> String {
        let t = p.timing
        let trials = 2 * p.trialsPerClass
        let mean = t.fixationMs + t.cueMs + (t.restMinMs + t.restMaxMs) / 2
        return "\(trials) trials per run · about \(Fmt.duration(ms: trials * mean)) per run · " +
            p.classes.map { "\($0.displayName) (\($0.cue.title.lowercased()))" }.joined(separator: " vs ")
    }

    static func runsNote(_ runs: Int) -> String {
        runs >= RunCountModel.minimumRuns ? "Evaluation holds one run out and cross-validates on the rest."
            : "Evaluation needs at least \(RunCountModel.minimumRuns) runs."
    }
}

/// What the operator sees during a run (brief 005 "Operator panel").
struct OperatorPanelModel: Equatable {
    let title: String
    let progress: String
    let phase: String
    let time: String?
    let notice: (danger: Bool, text: String)?
    /// The keys as they act in this state.
    let shortcuts: String
    let canBegin, canAbortTrial, canPause, canResume, canAbortRun: Bool

    static let header = "Protocol run"
    static let begin = "Begin", abortTrial = "Abort Trial", pause = "Pause", resume = "Resume", abortRun = "Abort Run"
    static let beginHelp = "Start the first trial (Space)."
    static let abortTrialHelp = "Abort the trial in progress (Esc). It is excluded, not repeated."
    static let abortRunHelp = "End this run now (⌘.). Completed trials stay evaluable."
    static let displayGone = "The participant display is gone. Reconnect it, or abort the run."

    static let lastRunDone = "That was the session's last run. Finish Session stops the recording."

    /// `moreRuns`: the session still has a run to start (after the last one only Finish is offered).
    static func shortcuts(_ state: ProtocolRunner.RunState, moreRuns: Bool = true) -> String {
        let space: String
        switch state {
        case .instructions: space = "Space begins"
        case .running: space = "Space pauses"
        case .paused: space = "Space resumes"
        case .ended, .failed: return moreRuns ? "Start the next run or finish the session." : lastRunDone
        }
        return "\(space) · Esc aborts the trial · ⌘. aborts the run. The keys work while the participant window is in front."
    }

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.progress == b.progress && a.phase == b.phase && a.time == b.time
            && a.notice?.danger == b.notice?.danger && a.notice?.text == b.notice?.text && a.shortcuts == b.shortcuts
            && [a.canBegin, a.canAbortTrial, a.canPause, a.canResume, a.canAbortRun] == [b.canBegin, b.canAbortTrial, b.canPause, b.canResume, b.canAbortRun]
    }

    /// `streaming`: the board is delivering samples into the run (Resume needs it, decision #35).
    init(_ s: ProtocolRunner.Status, protocol p: ProtocolRecord, runsPerSession: Int, streaming: Bool, nowNanos: Int64) {
        title = "\(p.name) · v\(p.version)"
        let trial = s.trial.map { "Trial \($0 + 1) of \(s.trialCount)" } ?? "\(s.trialCount) trials"
        progress = "Run \(s.runIndex + 1) of \(runsPerSession) · \(trial)"
        let className = s.label.flatMap { l in p.classes.first { $0.label == l }?.displayName }
        switch s.state {
        case .instructions: phase = "Instructions on screen. Press Space when the participant is ready."
        case .running:
            switch s.phase {
            case .fixation: phase = "Fixation"
            case .cue: phase = "Cue · " + (className ?? "?")
            case .rest: phase = "Rest"
            case .none: phase = "Between trials"
            }
        case .paused(.operator): phase = "Paused"
        case .paused(.disconnect): phase = streaming ? "Paused after a disconnect. The board is back: Resume continues in a new segment."
                                                     : "Paused: the board disconnected. Resume once it reconnects."
        case .paused(.display): phase = "Participant display changed. Resume fits the window to it again; the trial in progress was aborted."
        case .ended(let aborted): phase = aborted ? "Run ended early" : "Run complete"
        case .failed: phase = "The run couldn't start"
        }
        if let start = s.startedAt {
            let end = s.plannedEnd.map { Fmt.duration(ms: Int(max(0, $0 - nowNanos) / 1_000_000)) }
            let running: Bool = { if case .running = s.state { true } else { false } }()
            time = "Elapsed \(Fmt.duration(ms: Int(max(0, nowNanos - start) / 1_000_000)))" + (running ? end.map { " · about \($0) left" } ?? "" : "")
        } else {
            time = nil
        }
        switch s.state {
        case .failed(let why): notice = (true, "The run couldn't start: \(why)")
        case .ended where s.endReason == "recording_stopped":
            notice = (true, "The run stopped because the recording stopped" +
                      (s.unrecordedEvents.isEmpty ? "." : "; \(s.unrecordedEvents.count) event\(s.unrecordedEvents.count == 1 ? " was" : "s were") not recorded."))
        default:
            notice = s.abortedTrials.isEmpty ? nil
                : (false, "\(s.abortedTrials.count) trial\(s.abortedTrials.count == 1 ? "" : "s") aborted and excluded: \(s.abortedTrials.joined(separator: ", "))")
        }
        shortcuts = Self.shortcuts(s.state)
        let live: Bool = { switch s.state { case .instructions, .running, .paused: true; default: false } }()
        canBegin = s.state == .instructions
        canAbortTrial = s.state == .running && s.trial != nil && s.phase != .rest
        canPause = s.state == .running
        canResume = { if case .paused = s.state { streaming } else { false } }()
        canAbortRun = live
    }
}

enum RunSessionCopy {
    static let finish = "Finish Session"
    static let finishHelp = "Stop the recording. Its runs can be evaluated from Recordings."
    static let close = "Close"
    static func nextRun(_ n: Int, of total: Int) -> String { "Start Run \(n) of \(total)" }
}

/// "Cue timing (software)" after each run (brief 005 "Events and timing").
struct TimingSummaryModel: Equatable {
    let title = "Cue timing (software)"
    let rows: [(String, String)]
    let caveat = "Measured from the app's own callbacks. The delay to the screen and to the EEG sample is not measured."

    func heading(runIndex: Int) -> String { "Run \(runIndex + 1) · \(title)" }

    static func == (a: Self, b: Self) -> Bool { a.rows.map { "\($0.0)=\($0.1)" } == b.rows.map { "\($0.0)=\($0.1)" } }

    /// `latenessNanos`: presented − intended per phase with a callback. `placements`: the run's
    /// phase events by association method, once written (nil while still being written).
    /// `afterStall` (parallel to `latenessNanos`): the callback followed a display stall.
    init(latenessNanos: [Int64], afterStall: [Bool] = [], missing: Int, framePeriodNanos: Int64, placements: (marker: Int, fallback: Int)?) {
        let sorted = latenessNanos.sorted()
        let stalled = latenessNanos.indices.filter { $0 < afterStall.count && afterStall[$0] }
        let steady = latenessNanos.indices.filter { !stalled.contains($0) }.map { latenessNanos[$0] }
        func ms(_ n: Int64) -> String { "\(Fmt.fixed(Double(n) / 1e6, 1)) ms" }
        func pct(_ p: Double) -> Int64 { sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
        var r: [(String, String)] = []
        if sorted.isEmpty {
            r.append(("Presented − intended", "no presentation callbacks"))
        } else {
            r.append(("Median lateness", ms(pct(0.5))))
            r.append(("95th percentile", ms(pct(0.95))))
            r.append(("Maximum", ms(sorted.last!)))
            let period = max(1, framePeriodNanos)
            let late = sorted.filter { $0 >= period }.count
            r.append(("A frame or more late", "\(late) of \(sorted.count) screen changes (1 frame = \(ms(period)))"))
            if !stalled.isEmpty {
                // The maximum above can come from the app or the system stalling, not the schedule.
                r.append(("After a display stall", "\(stalled.count) screen change\(stalled.count == 1 ? "" : "s")"
                          + (steady.max().map { "; maximum without them \(ms($0))" } ?? "")))
            }
        }
        if missing > 0 { r.append(("No callback", "\(missing) phase\(missing == 1 ? "" : "s"); presented time left empty")) }
        if let p = placements {
            r.append(("Placed on the EEG", "\(p.marker) events by BrainFlow marker · \(p.fallback) by nearest timestamp"))
        } else {
            r.append(("Placed on the EEG", "counting…"))
        }
        rows = r
    }
}

/// Whether a recording has enough runs to evaluate (brief 005 "Evaluable result").
enum RunCountModel {
    static let minimumRuns = 3

    /// Runs are distinct run ids; a run with a reconnect has several segments.
    static func runs(_ m: RecordingManifest) -> Int {
        Set(m.segments.map(\.runID)).count
    }

    /// Runs the worker can split on: those with at least one cue event (a trial event that
    /// isn't one of the protocol's own) whose trial wasn't aborted.
    static func evaluableRuns(_ events: [EventRecord]) -> Int {
        let aborted = Set(events.filter { $0.label == "trial_abort" }.compactMap(\.trialID))
        return Set(events.filter { e in
            guard let t = e.trialID else { return false }
            return !ProtocolRecord.reservedLabels.contains(e.label) && !aborted.contains(t)
        }.map(\.runID)).count
    }

    static func message(runs n: Int) -> String {
        n < minimumRuns ? "Needs at least 3 runs with cues (1 held out, 2 for cross-validation); this recording has \(n)."
            : "\(n) runs with cues: enough to hold one out and cross-validate on the rest."
    }

    static func labels(_ p: ProtocolRecord) -> String {
        "Classes from \(p.name) v\(p.version): " + p.classes.map { "\($0.displayName) (“\($0.label)”)" }.joined(separator: " vs ") + "."
    }
}
