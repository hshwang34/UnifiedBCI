import Foundation

// Brief 007: the guided setup. Four goals (decision #43), each a list of steps shown in the
// sidebar Guide card (decision #44). Steps tick off from the project's real state or from what
// the user has actually done in the app (decision #45): never shown done unless it is true,
// and a skipped step stays "skipped", never "done". Guide state is per-user app state, kept in
// UserDefaults by the project's stable id, so it never touches the `.bciproj` format.

// MARK: Goals and steps

enum GuideGoal: String, CaseIterable, Identifiable, Codable, Sendable {
    case example, record, train, live

    var id: String { rawValue }

    /// The picker's wording (brief 007).
    var title: String {
        switch self {
        case .example: return "See how it works on the example"
        case .record: return "Record EEG from a headset"
        case .train: return "Train and check a decoder"
        case .live: return "Run live feedback with a participant"
        }
    }

    /// The card's heading: the goal in a few words.
    var shortTitle: String {
        switch self {
        case .example: return "Explore the example"
        case .record: return "Record EEG"
        case .train: return "Train a decoder"
        case .live: return "Live feedback"
        }
    }

    var summary: String {
        switch self {
        case .example: return "Inspect a public motor-imagery recording, evaluate it, and read the result."
        case .record: return "Connect a board, confirm its channels, and save a recording with a quality check."
        case .train: return "Record cued left/right runs, then train and test a decoder on runs it never saw."
        case .live: return "Train a decoder, freeze it, check it offline, then run it live with feedback."
        }
    }

    var symbol: String {
        switch self {
        case .example: return "sparkles.rectangle.stack"
        case .record: return "waveform.badge.plus"
        case .train: return "brain.head.profile"
        case .live: return "bolt.horizontal.circle"
        }
    }

    var steps: [GuideStep.ID] {
        switch self {
        case .example: return [.openRecording, .checkSignal, .viewMontage, .evaluate, .readResult]
        case .record: return [.connect, .confirmMap, .checkLiveSignal, .record, .reviewQuality]
        case .train: return Self.trainSteps
        case .live: return Self.trainSteps + [.freeze, .checkReplay, .runLive, .readLiveRun]
        }
    }

    private static let trainSteps: [GuideStep.ID] = [.connectForRuns, .chooseProtocol, .recordRuns, .evaluateCued, .readCuedResult]
}

/// Where "Show me" goes. `anchor` names the control PR 4 rings; this PR only navigates.
struct GuideTarget: Equatable, Sendable {
    var section: SidebarSection
    /// The recording detail's tab to switch to, if any.
    var recordingTab: RecordingTab? = nil
    /// The Recordings list's Live row (the acquisition screen) rather than a stored recording.
    var showsLive = false
    var anchor: GuideAnchor
}

/// Stable ids for the controls "Show me" highlights (brief 007 PR 4 attaches them in views).
enum GuideAnchor: String, CaseIterable, Sendable {
    case recordingList, qualityTab, montage, evaluateButton, resultDetail, newRecording, channelMap,
         livePreview, recordButton, protocolList, startRun, freezeButton, replayButton, liveStart, liveRunCard
}

struct GuideStep: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Codable, Sendable {
        // Example
        case openRecording, checkSignal, viewMontage, evaluate, readResult
        // Record
        case connect, confirmMap, checkLiveSignal, record, reviewQuality
        // Train (and the first half of Live feedback)
        case connectForRuns, chooseProtocol, recordRuns, evaluateCued, readCuedResult
        // Live feedback
        case freeze, checkReplay, runLive, readLiveRun
    }

    let id: ID
    let title: String
    /// One sentence: what to do.
    let instruction: String
    let target: GuideTarget

    /// The recommended number of cued runs (decision #37); the rule needs one.
    static let recommendedRuns = 4
    /// How long the live preview must stream before "Check the live signal" is done.
    static let previewSeconds: Double = 10

    static func step(_ id: ID) -> GuideStep {
        switch id {
        case .openRecording:
            return .init(id: id, title: "Open a recording", instruction: "Select a recording in the Recordings list to see its channels and events.",
                         target: .init(section: .recordings, anchor: .recordingList))
        case .checkSignal:
            return .init(id: id, title: "Check its signal", instruction: "Open the Quality tab to see which channels are flat, noisy or clipped.",
                         target: .init(section: .recordings, recordingTab: .quality, anchor: .qualityTab))
        case .viewMontage:
            return .init(id: id, title: "Look at the head montage", instruction: "On the Channels tab, click a sensor on the head to see where that channel sits.",
                         target: .init(section: .recordings, recordingTab: .channels, anchor: .montage))
        case .evaluate:
            return .init(id: id, title: "Evaluate", instruction: "Choose Evaluate (⌘R) to train on some runs and test on runs the model never saw.",
                         target: .init(section: .recordings, anchor: .evaluateButton))
        case .readResult:
            return .init(id: id, title: "Read the result", instruction: "Open the result in Results and compare held-out accuracy with chance and the baseline.",
                         target: .init(section: .results, anchor: .resultDetail))
        case .connect:
            return .init(id: id, title: "Connect a source", instruction: "Choose New Recording… and connect your board, or the Demo source to practise.",
                         target: .init(section: .recordings, anchor: .newRecording))
        case .confirmMap:
            return .init(id: id, title: "Confirm the channel map", instruction: "Name each channel and its position, then Confirm map, or choose Record without positions.",
                         target: .init(section: .recordings, showsLive: true, anchor: .channelMap))
        case .checkLiveSignal:
            return .init(id: id, title: "Check the live signal", instruction: "Watch the live preview for at least 10 seconds and look for flat or noisy channels.",
                         target: .init(section: .recordings, showsLive: true, anchor: .livePreview))
        case .record:
            return .init(id: id, title: "Record", instruction: "Choose Record, then Stop when you have enough; the recording is saved to the project.",
                         target: .init(section: .recordings, showsLive: true, anchor: .recordButton))
        case .reviewQuality:
            return .init(id: id, title: "Review its quality", instruction: "Open the new recording's Quality tab and check it before you analyse it.",
                         target: .init(section: .recordings, recordingTab: .quality, anchor: .qualityTab))
        case .connectForRuns:
            return .init(id: id, title: "Connect", instruction: "Choose New Recording…, connect a source and confirm its channel map.",
                         target: .init(section: .recordings, anchor: .newRecording))
        case .chooseProtocol:
            return .init(id: id, title: "Choose a protocol", instruction: "Open Protocols to see the cued task; a default left/right protocol is added for you.",
                         target: .init(section: .protocols, anchor: .protocolList))
        case .recordRuns:
            return .init(id: id, title: "Record cued runs",
                         instruction: "Choose Start run… and record cued runs; \(recommendedRuns) are recommended so some can be held out.",
                         target: .init(section: .recordings, showsLive: true, anchor: .startRun))
        case .evaluateCued:
            return .init(id: id, title: "Evaluate", instruction: "Select a cued recording and choose Evaluate (⌘R).",
                         target: .init(section: .recordings, anchor: .evaluateButton))
        case .readCuedResult:
            return .init(id: id, title: "Read the result", instruction: "Open its result and check whether held-out accuracy clears chance and the baseline.",
                         target: .init(section: .results, anchor: .resultDetail))
        case .freeze:
            return .init(id: id, title: "Freeze a model", instruction: "In the result, choose Freeze for live use… to save the fitted model unchanged.",
                         target: .init(section: .results, anchor: .freezeButton))
        case .checkReplay:
            return .init(id: id, title: "Check replay", instruction: "In Pipelines, choose Replay… on a recording and check that the parity check passes.",
                         target: .init(section: .pipelines, anchor: .replayButton))
        case .runLive:
            return .init(id: id, title: "Run a live test", instruction: "In Live Test, pick the frozen model and start a live run with feedback.",
                         target: .init(section: .liveTest, anchor: .liveStart))
        case .readLiveRun:
            return .init(id: id, title: "Read the live results", instruction: "Open the live run's card to see its accuracy, interval and abstentions.",
                         target: .init(section: .liveTest, anchor: .liveRunCard))
        }
    }
}

// MARK: What the user has done

/// Things the project's files can't tell: what the user has opened in the app.
enum GuideMark: Hashable, Sendable {
    /// A recording's detail was shown.
    case recordingOpened
    /// A sensor on the montage head was clicked (Channels tab).
    case montageViewed
    /// The live preview streamed for `GuideStep.previewSeconds`.
    case previewWatched
    /// The Protocols section was opened (a project always holds the default protocol, so
    /// "one exists" would be true from the start).
    case protocolsVisited
    /// A recording's Quality tab was opened.
    case quality(UUID)
    /// A result was opened in Results.
    case result(UUID)
    /// A live run's card was opened in Live Test.
    case liveRunCard(UUID)

    var rawValue: String {
        switch self {
        case .recordingOpened: return "recording"
        case .montageViewed: return "montage"
        case .previewWatched: return "preview"
        case .protocolsVisited: return "protocols"
        case .quality(let id): return "quality:\(id.uuidString)"
        case .result(let id): return "result:\(id.uuidString)"
        case .liveRunCard(let id): return "liveRun:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "recording": self = .recordingOpened; return
        case "montage": self = .montageViewed; return
        case "preview": self = .previewWatched; return
        case "protocols": self = .protocolsVisited; return
        default: break
        }
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "quality": self = .quality(id)
        case "result": self = .result(id)
        case "liveRun": self = .liveRunCard(id)
        default: return nil
        }
    }
}

// MARK: The snapshot the rules read

/// The project and live state the rules need, built from `ProjectSession` (and its live
/// board) each time the card renders. Plain values only, so the rules are a pure function.
struct GuideSnapshot: Equatable, Sendable {
    struct Recording: Equatable, Sendable {
        var id: UUID
        /// Made in this app from a board, the synthetic source or the Demo (not imported data).
        var isLive: Bool
        /// Its run plans name a protocol: a cued protocol run (brief 005).
        var isCued: Bool
    }

    var recordings: [Recording] = []
    /// Each stored result's recording.
    var resultRecordings: [UUID: UUID] = [:]
    var frozenModelCount = 0
    /// Some stored replay's parity check passed.
    var replayParityPassed = false
    var liveRunIDs: [UUID] = []
    /// A board is streaming now.
    var streaming = false
    /// The connected board's channel map is confirmed, or "Record without positions" chosen.
    var mapDeclared = false

    var liveRecordings: [Recording] { recordings.filter(\.isLive) }
    var cuedRecordings: [Recording] { recordings.filter(\.isCued) }
}

// MARK: The rules

enum GuideRules {
    /// Whether `step` is done. True only when the snapshot or the marks show it happened.
    static func isDone(_ step: GuideStep.ID, _ s: GuideSnapshot, marks: Set<GuideMark>) -> Bool {
        let cued = Set(s.cuedRecordings.map(\.id))
        let cuedResults = Set(s.resultRecordings.filter { cued.contains($0.value) }.keys)
        switch step {
        case .openRecording:
            return marks.contains(.recordingOpened) && !s.recordings.isEmpty
        case .checkSignal:
            return s.recordings.contains { marks.contains(.quality($0.id)) }
        case .viewMontage:
            return marks.contains(.montageViewed)
        case .evaluate:
            return !s.resultRecordings.isEmpty
        case .readResult:
            return s.resultRecordings.keys.contains { marks.contains(.result($0)) }
        case .connect, .connectForRuns:
            // Streaming now, or a recording this app made: it was connected to make it.
            return s.streaming || !s.liveRecordings.isEmpty
        case .confirmMap:
            // Record needs a declared map, so a saved live recording had one.
            return (s.streaming && s.mapDeclared) || !s.liveRecordings.isEmpty
        case .checkLiveSignal:
            // Set once a stream has run `GuideStep.previewSeconds` (ProjectSession).
            return marks.contains(.previewWatched)
        case .record:
            return !s.liveRecordings.isEmpty
        case .reviewQuality:
            return s.liveRecordings.contains { marks.contains(.quality($0.id)) }
        case .chooseProtocol:
            return marks.contains(.protocolsVisited) || !cued.isEmpty
        case .recordRuns:
            return !cued.isEmpty
        case .evaluateCued:
            return !cuedResults.isEmpty
        case .readCuedResult:
            return cuedResults.contains { marks.contains(.result($0)) }
        case .freeze:
            return s.frozenModelCount > 0
        case .checkReplay:
            return s.replayParityPassed
        case .runLive:
            return !s.liveRunIDs.isEmpty
        case .readLiveRun:
            return s.liveRunIDs.contains { marks.contains(.liveRunCard($0)) }
        }
    }
}

// MARK: Progress (what the card shows)

struct GuideProgress: Equatable {
    enum StepState: String, Equatable {
        case done, current, skipped, todo

        /// What VoiceOver reads after the step's title.
        var spoken: String {
            switch self {
            case .done: return "done"
            case .current: return "current"
            case .skipped: return "skipped"
            case .todo: return "to do"
            }
        }

        var symbol: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .current: return "circle.inset.filled"
            case .skipped: return "arrow.uturn.forward.circle"
            case .todo: return "circle"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let step: GuideStep
        let state: StepState
        var id: GuideStep.ID { step.id }
        var accessibilityLabel: String { "\(step.title), \(state.spoken)" }
    }

    let goal: GuideGoal
    let rows: [Row]

    /// Done beats skipped: a skipped step that later happens shows as done.
    init(goal: GuideGoal, snapshot: GuideSnapshot, marks: Set<GuideMark>, skipped: Set<GuideStep.ID>) {
        self.goal = goal
        var foundCurrent = false
        rows = goal.steps.map { id in
            let step = GuideStep.step(id)
            if GuideRules.isDone(id, snapshot, marks: marks) { return Row(step: step, state: .done) }
            if skipped.contains(id) { return Row(step: step, state: .skipped) }
            if !foundCurrent { foundCurrent = true; return Row(step: step, state: .current) }
            return Row(step: step, state: .todo)
        }
    }

    var current: Row? { rows.first { $0.state == .current } }
    /// No step left to do (every one done or skipped).
    var isFinished: Bool { current == nil }
    var doneCount: Int { rows.filter { $0.state == .done }.count }
    var skippedCount: Int { rows.filter { $0.state == .skipped }.count }

    /// "Step k of n": the current step's position; n of n once finished.
    var stepLine: String {
        let n = rows.count
        guard let current, let k = rows.firstIndex(of: current) else { return GuideCopy.finishedLine(done: doneCount, of: n) }
        return "Step \(k + 1) of \(n)"
    }

    /// The steps done now (for "Step done" announcements).
    var doneIDs: Set<GuideStep.ID> { Set(rows.filter { $0.state == .done }.map(\.id)) }

    /// Steps that became done since `before`, in step order.
    func newlyDone(since before: Set<GuideStep.ID>) -> [GuideStep] {
        rows.filter { $0.state == .done && !before.contains($0.id) }.map(\.step)
    }

    /// What the card lists when not showing every step: the steps before the current one
    /// (all done or skipped) folded into one line, then the current step and the next two.
    struct Window: Equatable {
        var foldedDone = 0
        var foldedSkipped: [GuideStep.ID] = []
        var rows: [Row] = []
        /// Steps after the window.
        var more = 0
        var hasFold: Bool { foldedDone + foldedSkipped.count > 0 }
    }

    static let windowAfterCurrent = 2

    func window(showsAll: Bool) -> Window {
        if showsAll { return Window(rows: rows) }
        let start = current.flatMap { rows.firstIndex(of: $0) } ?? rows.count
        let folded = rows[..<start]
        let end = min(rows.count, start + 1 + Self.windowAfterCurrent)
        return Window(foldedDone: folded.filter { $0.state == .done }.count,
                      foldedSkipped: folded.filter { $0.state == .skipped }.map(\.id),
                      rows: Array(rows[start..<end]), more: rows.count - end)
    }

    var finishedMessage: String {
        skippedCount == 0 ? GuideCopy.allDone : GuideCopy.finishedWithSkips(skippedCount)
    }
}

// MARK: Copy

enum GuideCopy {
    static let cardTitle = "Guide"
    static let pickerTitle = "What do you want to do?"
    static let pickerMessage = "The guide shows your next step in the sidebar. You can change it or hide it at any time."
    static let notNow = "Not now"
    static let showMe = "Show me"
    static let skipStep = "Skip step"
    static let changeGoal = "Change goal…"
    static let chooseAnother = "Choose another goal"
    static let hideGuide = "Hide guide"
    static let collapse = "Collapse guide"
    static let expand = "Expand guide"
    static let allDone = "All steps done. Nice work."
    static let menuGuide = "Guide…"
    static let menuShowGuide = "Show Guide"
    static let showMeHelp = "Go to the screen for this step"
    static let skipHelp = "Mark this step skipped and move on; it is not counted as done"
    static let hideHelp = "Hide the guide for this project (Help ▸ Show Guide brings it back)"

    static let undoSkip = "Undo skip"
    static func undoSkipOf(_ step: GuideStep) -> String { "Undo skip: \(step.title)" }
    static let showAllSteps = "Show all steps"
    static let showFewerSteps = "Show fewer steps"
    static let expandedValue = "expanded"
    static let collapsedValue = "collapsed"

    /// VoiceOver, when a step ticks off.
    static func stepDone(_ step: GuideStep) -> String { "Step done: \(step.title)" }

    /// The folded line for the steps before the current one.
    static func folded(done: Int, skipped: Int) -> String {
        switch (done, skipped) {
        case (_, 0): return "\(done) done"
        case (0, _): return "\(skipped) skipped"
        default: return "\(done) done · \(skipped) skipped"
        }
    }

    static func more(_ n: Int) -> String { "\(n) more" }

    static func finishedWithSkips(_ n: Int) -> String {
        "Guide finished, \(n) step\(n == 1 ? "" : "s") skipped."
    }

    static func finishedLine(done: Int, of n: Int) -> String { "\(done) of \(n) done" }

    static func cardAccessibility(_ p: GuideProgress) -> String {
        "Guide: \(p.goal.shortTitle). \(p.isFinished ? p.finishedMessage : p.stepLine)"
    }
}

// MARK: Persistence

/// Guide state for one project, as the user left it.
struct GuideState: Equatable, Codable, Sendable {
    static let currentVersion = 1
    var version = GuideState.currentVersion
    var goal: GuideGoal?
    var skipped: Set<GuideStep.ID> = []
    var hidden = false
    var collapsed = false
    /// The goal picker has been shown (or answered) for this project; it never asks again.
    var askedOnce = false
    var marks: Set<GuideMark> = []
    /// What another build of the app stored that this one doesn't know: kept and written
    /// back, so an older build never wipes a newer build's guide state.
    var unknownGoal: String?
    var unknownSkipped: [String] = []
    var unknownMarks: [String] = []

    init(goal: GuideGoal? = nil, skipped: Set<GuideStep.ID> = [], hidden: Bool = false, collapsed: Bool = false,
         askedOnce: Bool = false, marks: Set<GuideMark> = []) {
        self.goal = goal; self.skipped = skipped; self.hidden = hidden; self.collapsed = collapsed
        self.askedOnce = askedOnce; self.marks = marks
    }

    private enum CodingKeys: String, CodingKey { case version, goal, skipped, hidden, collapsed, askedOnce, marks }

    // Unknown goals, steps or marks (a newer or older app) are kept aside, never fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let rawGoal = try? c.decodeIfPresent(String.self, forKey: .goal)
        goal = rawGoal.flatMap(GuideGoal.init(rawValue:))
        unknownGoal = goal == nil ? rawGoal : nil
        let rawSkipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? []
        skipped = Set(rawSkipped.compactMap(GuideStep.ID.init(rawValue:)))
        unknownSkipped = rawSkipped.filter { GuideStep.ID(rawValue: $0) == nil }
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        askedOnce = (try? c.decodeIfPresent(Bool.self, forKey: .askedOnce)) ?? false
        let rawMarks = (try? c.decodeIfPresent([String].self, forKey: .marks)) ?? []
        marks = Set(rawMarks.compactMap(GuideMark.init(rawValue:)))
        unknownMarks = rawMarks.filter { GuideMark(rawValue: $0) == nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max(version, Self.currentVersion), forKey: .version)
        try c.encodeIfPresent(goal?.rawValue ?? unknownGoal, forKey: .goal)
        try c.encode((skipped.map(\.rawValue) + unknownSkipped).sorted(), forKey: .skipped)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(askedOnce, forKey: .askedOnce)
        try c.encode((marks.map(\.rawValue) + unknownMarks).sorted(), forKey: .marks)
    }

    /// Whether the picker should open now: no goal, never asked.
    var shouldAsk: Bool { goal == nil && !askedOnce }

    /// A new goal starts with no skipped steps; choosing the same goal again keeps them.
    mutating func choose(_ g: GuideGoal) {
        if goal != g { skipped = []; unknownSkipped = [] }
        goal = g
        unknownGoal = nil
        askedOnce = true
        hidden = false
        collapsed = false
    }

    mutating func unskip(_ id: GuideStep.ID) { skipped.remove(id) }
}

/// Reads and writes `GuideState` in UserDefaults under the project's stable id. With no
/// defaults (Debug-driven runs) the state lives only in memory.
struct GuideStore {
    static let keyPrefix = "BCIGuide."
    let defaults: UserDefaults?

    /// The project's stable id: its name and creation instant from `project.json`. Both are
    /// fixed when the project is made (the example import stamps its own), so the id survives
    /// moving or renaming the package; a Finder duplicate shares it (accepted). The instant is
    /// written exactly as `project.json` stores it (ContractJSON, millisecond ISO-8601): a
    /// just-created store still holds the unrounded `Date()`, and a reopen reads the rounded one.
    static func projectKey(name: String, created: Date) -> String {
        let stamp = (try? ContractJSON.encoder().encode(created)).map { String(decoding: $0, as: UTF8.self) }
            ?? "\(created.timeIntervalSinceReferenceDate)"
        return "\(name)|\(stamp.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))"
    }

    func load(_ projectKey: String) -> GuideState {
        guard let data = defaults?.data(forKey: Self.keyPrefix + projectKey),
              let state = try? JSONDecoder().decode(GuideState.self, from: data) else { return GuideState() }
        return state
    }

    func save(_ state: GuideState, for projectKey: String) {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.keyPrefix + projectKey)
    }
}
