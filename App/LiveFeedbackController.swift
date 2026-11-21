import Foundation
import Observation

/// One live run (brief 006): a frozen model's `LiveInferenceRunner` on the connected
/// stream, the participant window's feedback feed, and what the Live Test operator view
/// reads. Starts before the first protocol run (so the worker is ready and the run's
/// recording id is known), and ends with Finish. All I/O is in the runner and store actors.
@MainActor
@Observable
final class LiveFeedbackController {
    enum Phase: Equatable { case running, stopping, checking, ended }

    /// Replays a recording through a model and returns the replay's predictions, or why not
    /// (`ProjectSession` uses `ReplayRunner`; tests their own).
    typealias Replay = @MainActor (ModelRecord, UUID, Double, Double) async -> Result<[PredictionRecord], ReplayFailure>
    struct ReplayFailure: Error, Equatable { let reason: String }

    let model: ModelRecord
    let protocolRecord: ProtocolRecord
    let policy: FeedbackPolicy
    let liveRunID: UUID
    /// The id the session's recording gets when its first run starts.
    let recordingID: UUID
    let feed: FeedbackFeed
    private(set) var phase: Phase = .running
    /// The runner's status, refreshed ten times a second (only when it changed).
    private(set) var status = LiveInferenceRunner.Status()
    /// Each cued trial's class (from the cue events) and the trials that were aborted.
    private(set) var truth: [String: String] = [:]
    private(set) var aborted: Set<String> = []
    fileprivate(set) var runIDs: [String] = []
    private(set) var summary: LiveRunRecord.Summary?
    private(set) var latency: LiveRunRecord.LatencySummary?
    private(set) var replayCheck: LiveRunRecord.ReplayCheck?
    /// Why the live-vs-replay check didn't run, if it didn't.
    private(set) var checkProblem: String?

    @ObservationIgnored private let runner: LiveInferenceRunner
    @ObservationIgnored private let writer: LiveRunWriter
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var stopping: Task<Void, Never>?

    private init(model: ModelRecord, protocolRecord: ProtocolRecord, policy: FeedbackPolicy, liveRunID: UUID, recordingID: UUID,
                 runner: LiveInferenceRunner, writer: LiveRunWriter, store: ProjectStore, directions: [String: Double]) {
        self.model = model; self.protocolRecord = protocolRecord; self.policy = policy
        self.liveRunID = liveRunID; self.recordingID = recordingID; self.runner = runner; self.writer = writer; self.store = store
        feed = FeedbackFeed(directions: directions, staleLimitNanos: policy.staleLimitNanos)
    }

    /// Creates the live run (`live/<uuid>/`), starts the inference worker and subscribes it
    /// to `session`'s stream. A model the worker refuses (`channel_mismatch`, `invalid_model`)
    /// throws before anything runs, with the refusal logged as the run's one record.
    static func start(model: ModelRecord, protocolRecord: ProtocolRecord, policy: FeedbackPolicy, store: ProjectStore, launch: WorkerLaunch?,
                      session: AcquisitionSession, board: BoardDescription, request: AcquisitionSession.RecordingRequest) async throws -> LiveFeedbackController {
        // The bar's sides must match the cues: refused before anything is created.
        guard let directions = FeedbackFeed.directions(classes: protocolRecord.classes, modelLabels: model.classLabels) else {
            throw WorkerError(code: "invalid_protocol", message: LiveTestCopy.directionProblem)
        }
        let recordingID = request.recordingID ?? UUID()
        let record = LiveRunRecord(kind: .live, modelID: model.modelID, recordingID: recordingID, runIDs: [], hopSamples: WorkerClient.hopSamples,
                                   abstainThreshold: policy.threshold, staleLimitMillis: policy.staleLimitMillis, startedAt: Date())
        let writer = try await store.createLiveRun(record)
        let rows = request.channels.map(\.sourceRow)
        var config = LiveInferenceRunner.Configuration(model: model, arraysPath: await store.arraysURL(for: model).path, channelRows: rows,
                                                       channelIDs: request.channels.map(\.id), sampleRateHz: Double(board.samplingRate),
                                                       timestampRow: board.timestampRow, markerRow: board.markerRow, policy: policy)
        config.recordedOnly = true
        let runner = LiveInferenceRunner(configuration: config, launch: launch, writer: writer, sourceState: { session.snapshot.state })
        do {
            try await runner.start(source: session)
        } catch {
            let code = (error as? WorkerError)?.code ?? "worker_unavailable"
            let validity: Validity = code == "channel_mismatch" ? .channelMismatch : code == "invalid_model" ? .invalidInput : .workerUnavailable
            _ = try? await writer.append(PredictionRecord(pipelineID: model.sourcePipelineID, inputSegment: 0, inputSampleRange: nil, score: nil,
                                                          validity: validity, emittedAtMonotonicNanos: HostMonotonicClock.nowNanos(), action: .abstain,
                                                          feedbackPresentedAtMonotonicNanos: nil, validityDetail: "start_refused: \(code)"))
            try? await writer.finish(endedAt: Date(), summary: .init(predictions: 1, byValidity: [validity.rawValue: 1], abstained: 0),
                                     latency: nil, replayCheck: nil)
            throw error
        }
        let c = LiveFeedbackController(model: model, protocolRecord: protocolRecord, policy: policy, liveRunID: record.liveRunID,
                                       recordingID: recordingID, runner: runner, writer: writer, store: store, directions: directions)
        c.wire()
        return c
    }

    private func wire() {
        let (runner, feed) = (runner, feed)
        tasks = [
            Task.detached { for await u in runner.updates { feed.submit(u) } },
            // One consumer, so feedback lines are logged in the order the frames showed them.
            Task.detached {
                for await r in feed.reports {
                    await runner.presented(sequence: r.sequence, display: r.display, at: r.presentedAt, reason: r.reason, measured: r.measured)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let s = runner.status
                    if s != self.status { self.status = s }
                    // 4 Hz is plenty for the operator and keeps view updates off a busy main thread.
                    try? await Task.sleep(for: .milliseconds(250))
                }
            },
        ]
    }

    /// The protocol's host with the cues routed to the runner: each cue reaches the runner
    /// before its marker is inserted, so the runner can find the marked sample.
    func host(wrapping inner: any ProtocolRunHost) -> any ProtocolRunHost {
        let labels = Set(protocolRecord.classes.map(\.label))
        return LiveCueHost(inner: inner, runner: runner, classLabels: labels, cueSeconds: Double(protocolRecord.timing.cueMs) / 1000) { [weak self] events in
            Task { @MainActor in self?.note(events, classLabels: labels) }
        }
    }

    private func note(_ events: [EventRecord], classLabels: Set<String>) {
        for e in events {
            if !e.runID.isEmpty, !runIDs.contains(e.runID) { runIDs.append(e.runID) }
            guard let trial = e.trialID else { continue }
            if classLabels.contains(e.label) { truth[trial] = e.label }
            if e.label == "trial_abort" { aborted.insert(trial) }
        }
    }

    /// Ends the live run: the runner closes its worker session; then (with `replay`, once the
    /// recording has ended) the recording is replayed through the model and compared with
    /// what was logged live; `run.json` is written once, with the summaries and the check.
    /// Any phase: a second call (closing the window during the check) waits for the first,
    /// so `run.json` is always written before it returns.
    func stop(replay: Replay? = nil) async {
        if let stopping { return await stopping.value }
        guard phase == .running else { return }
        let t = Task { await self.performStop(replay: replay) }
        stopping = t
        await t.value
    }

    private func performStop(replay: Replay?) async {
        phase = .stopping
        let (summary, latency) = await runner.stop(runIDs: runIDs, finishing: false)
        feed.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        status = runner.status
        self.summary = summary
        self.latency = latency
        if let replay, !runIDs.isEmpty {
            phase = .checking
            let cue = Double(protocolRecord.timing.cueMs) / 1000
            switch await replay(model, recordingID, policy.threshold, cue) {
            case .success(let replayed):
                let (store, id) = (store, liveRunID)
                let live = await Task.detached { try? await store.predictions(liveRun: id).records }.value ?? []
                replayCheck = LiveReplayCheck.compare(live: live, replay: replayed)
                if Task.isCancelled { checkProblem = LiveRunCopy.checkCancelled }
            case .failure(let f):
                checkProblem = f.reason
            }
        } else if runIDs.isEmpty {
            checkProblem = LiveRunCopy.noRunsChecked
        }
        try? await writer.finish(endedAt: Date(), summary: summary, latency: latency, replayCheck: replayCheck, runIDs: runIDs)
        phase = .ended
    }

    /// Test seam: a controller over a runner that was never started (no worker, no stream).
    static func forTesting(model: ModelRecord, protocolRecord: ProtocolRecord, store: ProjectStore, writer: LiveRunWriter, recordingID: UUID) async -> LiveFeedbackController {
        let liveRunID = await writer.record.liveRunID
        let runner = LiveInferenceRunner(configuration: .init(model: model, arraysPath: "/nonexistent", channelRows: [], channelIDs: [], sampleRateHz: 125,
                                                              timestampRow: nil, markerRow: nil), launch: nil, writer: writer, sourceState: { .streaming })
        let c = LiveFeedbackController(model: model, protocolRecord: protocolRecord, policy: FeedbackPolicy(), liveRunID: liveRunID, recordingID: recordingID,
                                       runner: runner, writer: writer, store: store, directions: [:])
        c.runIDs = ["run01"]
        return c
    }

    /// Window closing or quit: stop without the check.
    func tearDown() { if phase == .running { Task { await stop() } } }
}

/// A protocol run host that also tells the live runner about every cue (brief 006).
struct LiveCueHost: ProtocolRunHost {
    let inner: any ProtocolRunHost
    let runner: LiveInferenceRunner
    let classLabels: Set<String>
    let cueSeconds: Double
    let onEvents: @Sendable ([EventRecord]) -> Void

    func beginRun(runID: String, sessionID: String) async throws -> UUID { try await inner.beginRun(runID: runID, sessionID: sessionID) }
    func endRun() async { await inner.endRun() }
    var isStreaming: Bool { inner.isStreaming }

    func record(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool {
        onEvents(events)
        for e in events where classLabels.contains(e.label) {
            guard let trial = e.trialID else { continue }
            // No presentation callback: nil, never a guess (the runner flags the trial).
            await runner.addCue(trialID: trial, marker: marker, presentedAt: e.presentedAtMonotonicNanos, lengthSeconds: cueSeconds)
        }
        return await inner.record(events, marker: marker, associateAt: associateAt)
    }
}
