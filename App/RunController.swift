import AppKit
import Observation

/// The participant window as the run controller uses it: `CueWindowController` in the app,
/// a fake in tests.
@MainActor
protocol CueSurface: AnyObject {
    var display: any CueDisplay { get }
    /// Set by the controller: the participant display changed or went away.
    var onDisplayChange: (() -> Void)? { get set }
    var framePeriodNanos: Int64 { get }
    func show()
    func hide()
    func close()
    /// Fits the window to its display again; false when the display is gone.
    func reframe() -> Bool
}

extension CueWindowController: CueSurface {
    var display: any CueDisplay { scheduler }
}

/// One session of protocol runs on the live stream (brief 005 PR 6): the runs of one
/// recording, each a new run id and segment, with the participant window, the operator's
/// commands and keys, and a timing summary after each run. Between runs the stream and
/// preview keep going; Finish stops the recording.
@MainActor @Observable
final class RunController {
    struct Setup: Equatable {
        var protocolRecord: ProtocolRecord
        var sessionSeed: UInt64
        var runsPerSession: Int
        var display: CueDisplayInfo
        var framePeriodNanos: Int64
        var sessionID = UUID().uuidString
    }

    struct RunSummary: Identifiable {
        let runID: String
        let runIndex: Int
        var timing: TimingSummaryModel
        var id: String { runID }
    }

    private(set) var setup: Setup
    private(set) var status: ProtocolRunner.Status?
    private(set) var summaries: [RunSummary] = []
    private(set) var runsStarted = 0
    private(set) var isFinished = false
    /// Set while Finish is stopping the recording.
    private(set) var isFinishing = false
    /// Why Resume didn't resume (the participant display is gone).
    private(set) var resumeProblem: String?

    @ObservationIgnored private let host: any ProtocolRunHost
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let surface: any CueSurface
    @ObservationIgnored private let options: ProtocolRunner.Options
    @ObservationIgnored private let onRecording: (UUID) -> Void
    @ObservationIgnored private let stopRecording: () async -> Void
    @ObservationIgnored private var runner: ProtocolRunner?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var keys: Any?
    @ObservationIgnored private var tornDown = false
    /// Trials (by id) an abort was already sent for: a second press never aborts the next one.
    @ObservationIgnored private var abortSent: Set<String> = []
    /// The project window that owns the run; keys are taken only from it and the participant window.
    @ObservationIgnored weak var operatorWindow: NSWindow?

    init(setup: Setup, host: any ProtocolRunHost, store: ProjectStore, surface: any CueSurface,
         options: ProtocolRunner.Options = .init(), onRecording: @escaping (UUID) -> Void, stopRecording: @escaping () async -> Void) {
        self.setup = setup; self.host = host; self.store = store; self.surface = surface; self.options = options
        self.onRecording = onRecording; self.stopRecording = stopRecording
        surface.onDisplayChange = { [weak self] in self?.runner?.displayChanged() }
    }

    var isRunActive: Bool {
        switch status?.state {
        case .instructions?, .running?, .paused?: return true
        default: return task != nil && status == nil
        }
    }

    var canStartNextRun: Bool { !isRunActive && !isFinished && !isFinishing && runsStarted < setup.runsPerSession }

    // MARK: Runs

    /// Starts the next run: the participant sees the instructions until Space.
    func startNextRun() {
        guard canStartNextRun, task == nil, !tornDown else { return }
        let index = runsStarted
        let runner = ProtocolRunner(protocol: setup.protocolRecord, runID: String(format: "run%02d", index + 1), sessionID: setup.sessionID,
                                    runIndex: index, sessionSeed: setup.sessionSeed, host: host, display: surface.display,
                                    store: store, options: options)
        self.runner = runner
        status = runner.status
        surface.show()
        installKeys()
        task = Task { [weak self] in
            let run = Task { await runner.run() }
            var adopted = false
            while !Task.isCancelled {
                let s = runner.status
                guard let self else { return }
                self.status = s
                if !adopted, let id = s.recordingID { adopted = true; self.onRecording(id) }
                if s.startedAt != nil, self.runsStarted == index { self.runsStarted = index + 1 }
                if case .ended = s.state { break }
                if case .failed = s.state { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let final = await run.value
            self?.ended(final)
        }
    }

    private func ended(_ s: ProtocolRunner.Status) {
        guard !tornDown else { return }
        status = s
        task = nil
        runner = nil
        // One display: the participant window steps aside so the operator sees the summary.
        if setup.display.isOperator { surface.hide() }
        guard s.startedAt != nil else { return }
        let summary = RunSummary(runID: s.runID, runIndex: s.runIndex,
                                 timing: TimingSummaryModel(latenessNanos: s.latenessNanos, afterStall: s.afterStall, missing: s.missingPresentations,
                                                            framePeriodNanos: setup.framePeriodNanos, placements: nil))
        summaries.append(summary)
        if let id = s.recordingID { countPlacements(recording: id, run: s) }
    }

    /// Reads the run's phase events once its `run_end` is written (events are written in
    /// queue order, so every earlier event is too) and counts how each found its sample.
    private func countPlacements(recording id: UUID, run s: ProtocolRunner.Status) {
        let store = store, runID = s.runID, labels = Set(["fixation", "cue_end", "rest"] + setup.protocolRecord.classes.map(\.label))
        Task { [weak self] in
            for _ in 0..<40 {
                if let events = try? await store.events(for: id), events.contains(where: { $0.runID == runID && $0.label == "run_end" }) {
                    let phase = events.filter { $0.runID == runID && labels.contains($0.label) }
                    let marker = phase.filter { $0.sampleAssociation?.method == "brainflow_marker" }.count
                    guard let self, !self.tornDown, let i = self.summaries.firstIndex(where: { $0.runID == runID }) else { return }
                    self.summaries[i].timing = TimingSummaryModel(latenessNanos: s.latenessNanos, afterStall: s.afterStall, missing: s.missingPresentations,
                                                                  framePeriodNanos: self.setup.framePeriodNanos,
                                                                  placements: (marker, phase.count - marker))
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func begin() { runner?.begin() }
    func pause() { runner?.pause() }
    func abortRun() { runner?.abortRun() }

    /// Aborts the trial on screen once; repeats and late presses for it do nothing.
    func abortTrial() {
        guard let runner, let s = status, let trial = s.trial, case .running = s.state else { return }
        let id = "\(s.runID)-\(trial)"
        guard abortSent.insert(id).inserted else { return }
        runner.abortTrial(trial)
    }

    /// After a display change the window is fitted to the display again (and its frame
    /// period re-read) before the run resumes; a display that is gone keeps the run paused.
    func resume() {
        guard let runner else { return }
        if case .paused(.display)? = status?.state {
            guard surface.reframe() else { resumeProblem = OperatorPanelModel.displayGone; return }
            setup.framePeriodNanos = surface.framePeriodNanos
        }
        resumeProblem = nil
        runner.resume()
    }

    /// Ends the session: an active run is aborted first, then the recording stops.
    func finish() async {
        guard !isFinished, !isFinishing else { return }
        isFinishing = true
        if let task {
            runner?.abortRun()
            await task.value
        }
        tearDown()
        await stopRecording()
        isFinishing = false
        isFinished = true
    }

    /// Closes the participant window and stops listening for keys (window closing, quit).
    func tearDown() {
        tornDown = true
        task?.cancel()
        runner?.abortRun()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        surface.close()
    }

    func awaitRun() async { await task?.value }

    // MARK: Keys

    /// Space, Esc and ⌘. work from the project window and the participant window (which
    /// never takes focus), before any menu sees ⌘. Repeats are swallowed without acting.
    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isRunActive, let window = event.window else { return false }
        let ours = window === operatorWindow || window.identifier == CueWindowController.identifier
        // A sheet, an alert or a text field being edited keeps its keys.
        let busy = NSApp.modalWindow != nil || operatorWindow?.attachedSheet != nil || window.firstResponder is NSText
        guard ours, !busy else { return false }
        guard let key = RunKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                               modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) else { return false }
        return press(key, isRepeat: event.isARepeat)
    }

    /// One run key; true when it was ours (a repeat is ours and does nothing).
    @discardableResult
    func press(_ key: RunKey, isRepeat: Bool) -> Bool {
        guard isRunActive else { return false }
        if isRepeat { return true }
        switch (key, status?.state) {
        case (.space, .instructions?): begin()
        case (.space, .running?): pause()
        case (.space, .paused?): resume()
        case (.escape, _): abortTrial()
        case (.abortRun, _): abortRun()
        default: break
        }
        return true
    }
}

/// The operator's run keys (brief 005): Space begins, Esc aborts the trial, ⌘. the run.
enum RunKey: Equatable {
    case space, escape, abortRun

    /// Exactly the intended modifiers: none for Space and Esc, only ⌘ for ⌘. (Caps Lock and
    /// the function/keypad flags are ignored).
    init?(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if held == .command, characters == "." { self = .abortRun }
        else if !held.isEmpty { return nil }
        else if keyCode == 53 { self = .escape }
        else if keyCode == 49 { self = .space }
        else { return nil }
    }
}
