import Foundation
import Synchronization

/// Live inference for one live run (brief 006): its own `WorkerClient`, so a long fit never
/// blocks a prediction; fed from the `AcquisitionSession` fan-out (never a second board read)
/// with `live_push`, one drained chunk at a time. Decides validity in Swift: abstention,
/// `stale`, `insufficient_window`, `invalid_input`, `disconnected` and `worker_unavailable` are
/// explicit states that hide the bar (decision #27). Every due window is logged to
/// `predictions.jsonl`; every change of what the participant sees to `feedback.jsonl`.
///
/// Losing the worker never touches acquisition: the runner stops pushing, names the state
/// and keeps draining its own buffer, and the recording goes on.
public actor LiveInferenceRunner {
    public struct Configuration: Sendable {
        public var model: ModelRecord
        public var arraysPath: String
        /// Board rows of the model's channels, in the model's order, and the stream's ids for them.
        public var channelRows: [Int]
        public var channelIDs: [String]
        public var sampleRateHz: Double
        /// The board's wall-clock timestamp row, for BrainFlow buffer wait; nil to skip.
        public var timestampRow: Int?
        public var policy: FeedbackPolicy
        /// `live_push` answers within this or the worker counts as unavailable (brief: 1 s).
        public var workerTimeout: Duration = .seconds(1)
        public var tickInterval: Duration = .milliseconds(50)

        public init(model: ModelRecord, arraysPath: String, channelRows: [Int], channelIDs: [String], sampleRateHz: Double,
                    timestampRow: Int?, policy: FeedbackPolicy = .init()) {
            self.model = model; self.arraysPath = arraysPath; self.channelRows = channelRows; self.channelIDs = channelIDs
            self.sampleRateHz = sampleRateHz; self.timestampRow = timestampRow; self.policy = policy
        }
    }

    /// What the operator panel and the participant window read, without an actor hop.
    public struct Status: Sendable, Equatable {
        /// The current named state; nil until the first prediction.
        public var validity: Validity?
        public var detail: String?
        public var display: FeedbackPolicy.Display = .hidden(words: FeedbackPolicy.words(.insufficientWindow))
        /// The newest raw score and model confidence (operator panel only).
        public var score: Double?
        public var confidence: Double?
        public var predictions = 0
        public var lastSequence: Int?
        public var stopped = false
    }

    /// One change of the display, for the participant window: it calls `presented` when the
    /// frame showing it is on screen.
    public struct Update: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
    }

    public nonisolated let configuration: Configuration
    public nonisolated var status: Status { published.withLock { $0 } }
    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateSink: AsyncStream<Update>.Continuation
    private nonisolated let published = Mutex(Status())

    private let launch: WorkerLaunch?
    private let writer: LiveRunWriter?
    private let now: @Sendable () -> Int64
    private let sourceState: @Sendable () -> AcquisitionSession.State
    private var client: WorkerClient?
    private var session: String?
    private var loops: [Task<Void, Never>] = []
    private var sequence = 0
    private var shown: FeedbackPolicy.Display?
    /// Stream position: the segment and next sample the fan-out should deliver.
    private var streamSegment: Int?
    private var nextStreamSample = 0
    /// Worker position: its segment id (new on every discontinuity) and next sample.
    private var workerSegment = -1
    private var workerNext = 0
    private var lastDrain: Int64?
    private var lastFrameEnd: (sample: Int, drained: Int64)?
    private var pendingCues: [LiveCue] = []
    /// A condition that overrides predictions (stale stream, disconnected, worker gone).
    private var condition: Validity?
    private var records: [PredictionRecord] = []
    private var bufferWaitsMs: [Double] = []
    private var presentationMs: [Double] = []
    private var emitted: [Int: Int64] = [:]

    /// `writer` is nil only in tests that read the status alone. `now` is the latency
    /// clock (`HostMonotonicClock`; a fake in tests); `sourceState` the acquisition state.
    public init(configuration: Configuration, launch: WorkerLaunch?, writer: LiveRunWriter?,
                sourceState: @escaping @Sendable () -> AcquisitionSession.State,
                now: @escaping @Sendable () -> Int64 = { HostMonotonicClock.nowNanos() }) {
        self.configuration = configuration
        self.launch = launch
        self.writer = writer
        self.sourceState = sourceState
        self.now = now
        (updates, updateSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    // MARK: Lifecycle

    /// Starts the worker and opens the session (`channel_mismatch` / `invalid_model` throw
    /// before anything runs), then subscribes with `subscribe` (so no backlog builds up while
    /// the worker starts), consumes the frames and checks staleness every tick.
    public func start(subscribe: @Sendable () -> AsyncStream<AcquisitionSession.InferenceFrame>) async throws {
        guard let launch else { throw WorkerError(code: "launch_failed", message: "no analysis worker is available") }
        let c = WorkerClient(launch: launch)
        client = c
        do {
            _ = try await c.start()
            let m = configuration.model
            session = try await c.liveOpen(model: m, arraysPath: configuration.arraysPath, channelIDs: configuration.channelIDs,
                                           sampleRateHz: configuration.sampleRateHz).session
        } catch {
            await c.shutdown()
            client = nil
            throw error
        }
        let frames = subscribe()
        loops = [
            Task { [weak self] in for await frame in frames { await self?.handle(frame) } },
            Task { [weak self, interval = configuration.tickInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.tick()
                }
            },
        ]
    }

    /// Ends the run: closes the worker session (its unfinished cue-locked windows are logged),
    /// stops the worker and writes the summaries into `run.json`.
    @discardableResult
    public func stop() async -> (summary: LiveRunRecord.Summary, latency: LiveRunRecord.LatencySummary) {
        loops.forEach { $0.cancel() }
        loops = []
        if let c = client, let s = session, condition != .workerUnavailable,
           let pending = try? await c.liveClose(session: s, timeout: configuration.workerTimeout) {
            await log(pending, receipt: nil, compute: nil)
        }
        if let c = client { await c.shutdown() }
        client = nil
        updateSink.finish()
        published.withLock { $0.stopped = true }
        let summary = LiveRunRecord.Summary(predictions: records.count,
                                            byValidity: Dictionary(grouping: records, by: \.validity.rawValue).mapValues(\.count),
                                            abstained: records.filter { $0.validity == .valid && $0.action.kind == .abstain }.count)
        let receipt = records.compactMap { p in p.acquisitionReceiptMonotonicNanos.flatMap { r in p.emittedAtMonotonicNanos.map { Double($0 - r) / 1e6 } } }
        let latency = LiveRunRecord.LatencySummary(receiptToEmission: Self.percentiles(receipt), bufferWait: Self.percentiles(bufferWaitsMs),
                                                   emissionToPresentation: Self.percentiles(presentationMs))
        try? await writer?.finish(endedAt: Date(), summary: summary, latency: latency, replayCheck: nil)
        return (summary, latency)
    }

    /// A cue presented at `presentedAt` (host monotonic) whose imagery lasts `lengthSeconds`,
    /// placed on the stream by the newest drained chunk at the nominal rate; it travels with
    /// the next push of the same worker segment (the worker announces its windows).
    public func addCue(trialID: String, presentedAt: Int64, lengthSeconds: Double) {
        guard let end = lastFrameEnd, workerSegment >= 0 else { return }
        let rate = configuration.sampleRateHz
        let sample = max(0, end.sample + Int((Double(presentedAt - end.drained) / 1e9 * rate).rounded()))
        pendingCues.append(LiveCue(sample: sample, trialID: trialID, endSample: sample + Int((lengthSeconds * rate).rounded())))
    }

    /// The participant window showed `sequence`'s display on the frame presented at `at`.
    public func presented(sequence: Int, display: FeedbackPolicy.Display, at: Int64?) async {
        if let at, let e = emitted[sequence] { presentationMs.append(Double(at - e) / 1e6) }
        let record: FeedbackRecord
        switch display {
        case .bar(let side, let length):
            record = FeedbackRecord(predictionSequence: sequence, shown: true, side: side, length: length, words: nil, presentedAtMonotonicNanos: at)
        case .hidden(let words):
            record = FeedbackRecord(predictionSequence: sequence, shown: false, side: nil, length: nil, words: words, presentedAtMonotonicNanos: at)
        }
        try? await writer?.append(record)
    }

    /// Test seam: SIGKILL the inference worker, as Activity Monitor would.
    func killWorkerForTesting() async { await client?.forceTerminate() }

    // MARK: Frames

    private func handle(_ frame: AcquisitionSession.InferenceFrame) async {
        let chunk = frame.chunk
        guard chunk.count > 0 else { return }
        lastDrain = chunk.drainedAtMonotonicNanos
        // BrainFlow receipt (its wall-clock timestamp) → drain. A playback file carries its
        // original timestamps, so anything outside 0…10 s is not a buffer wait and is skipped.
        if let row = configuration.timestampRow, let pair = frame.clockPair, row < chunk.numRows, let last = chunk.row(row).last,
           case let wait = (pair.wallSeconds - last) * 1000, wait.isFinite, (0...10_000).contains(wait) {
            bufferWaitsMs.append(wait)
        }
        // A new stream segment, or frames lost from the newest-wins buffer: the worker starts
        // a new segment (filter reset, warm-up again), never joins across the hole.
        if frame.segment != streamSegment || frame.firstSample != nextStreamSample {
            workerSegment += 1
            workerNext = 0
            pendingCues = []
        }
        streamSegment = frame.segment
        nextStreamSample = frame.firstSample + chunk.count
        let first = workerNext
        workerNext += chunk.count
        lastFrameEnd = (first + chunk.count - 1, chunk.drainedAtMonotonicNanos)
        if condition == .stale || condition == .disconnected { condition = nil }
        guard condition != .workerUnavailable, let c = client, let s = session else { return }

        let rows = configuration.channelRows.map { Array(chunk.row($0)) }
        let gaps = frame.gaps.filter { Self.dataGaps.contains($0.evidence) }
            .map { LiveGap(afterSample: first + $0.afterSampleIndex, evidence: $0.evidence.rawValue) }
        let cues = pendingCues
        pendingCues = []
        let results: [LivePushResult]
        do {
            results = try await c.livePush(session: s, segment: workerSegment, firstSample: first, rows: rows, gaps: gaps, cues: cues,
                                           timeout: configuration.workerTimeout)
        } catch let error as WorkerError where error.code == "bad_request" && error.message.contains("non-finite") {
            // Nothing reached the worker: log the chunk as invalid input, restart the segment.
            workerSegment += 1
            workerNext = 0
            await log(PredictionRecord(pipelineID: configuration.model.sourcePipelineID, inputSegment: workerSegment - 1,
                                       inputSampleRange: .init(start: first, count: chunk.count), score: nil, validity: .invalidInput,
                                       emittedAtMonotonicNanos: now(), action: .abstain, feedbackPresentedAtMonotonicNanos: nil,
                                       validityDetail: "non_finite_samples", acquisitionReceiptMonotonicNanos: chunk.drainedAtMonotonicNanos))
            return
        } catch {
            await workerLost("\(error)")
            return
        }
        for r in results { await log(r.predictions, receipt: chunk.drainedAtMonotonicNanos, compute: r.workerComputeNanos) }
    }

    /// Every tick: a disconnected board, a dead worker or a silent stream hides the bar now.
    private func tick() async {
        guard !loops.isEmpty else { return }
        if condition != .workerUnavailable, let c = client, await c.state != .ready { return await workerLost("the inference worker exited") }
        switch sourceState() {
        case .interrupted, .failed, .disconnected, .stopping:
            await enter(.disconnected, detail: "acquisition_interrupted")
        default:
            if let d = lastDrain, now() - d > configuration.policy.staleLimitNanos { await enter(.stale, detail: "no_samples_drained") }
        }
    }

    private func workerLost(_ why: String) async {
        guard condition != .workerUnavailable else { return }
        if let c = client { await c.forceTerminate() }
        await enter(.workerUnavailable, detail: "worker_lost: \(why)")
    }

    /// Logs one prediction-less record for a condition starting, and hides the bar.
    private func enter(_ v: Validity, detail: String) async {
        guard condition != v, condition != .workerUnavailable else { return }
        condition = v
        await log(PredictionRecord(pipelineID: configuration.model.sourcePipelineID, inputSegment: max(workerSegment, 0), inputSampleRange: nil,
                                   score: nil, validity: v, emittedAtMonotonicNanos: now(), action: .abstain,
                                   feedbackPresentedAtMonotonicNanos: nil, validityDetail: detail))
    }

    // MARK: Logging

    private func log(_ predictions: [WorkerPrediction], receipt: Int64?, compute: Int64?) async {
        let t = now()
        let policy = configuration.policy
        for p in predictions {
            guard var r = try? ReplayRunner.record(p, model: configuration.model, threshold: policy.threshold, sequence: sequence, emittedAt: t) else {
                continue
            }
            r.acquisitionReceiptMonotonicNanos = receipt
            r.workerComputeNanos = compute
            if r.validity == .valid, let receipt, policy.isLate(receipt: receipt, emitted: t) {
                r.validity = .stale
                r.validityDetail = "prediction_late"
                r.action = .abstain
            }
            await log(r)
        }
    }

    private func log(_ record: PredictionRecord) async {
        var r = record
        r.sequence = sequence
        if let writer { r.sequence = (try? await writer.append(r)) ?? sequence }
        sequence += 1
        records.append(r)
        let seq = r.sequence ?? 0
        if let e = r.emittedAtMonotonicNanos { emitted[seq] = e }
        // Hop windows drive the bar; a cue-locked window is the trial's outcome, not feedback.
        let drivesDisplay = r.windowKind != "cue_locked"
        let display = configuration.policy.display(for: r)
        published.withLock { s in
            s.predictions += 1
            s.lastSequence = seq
            if drivesDisplay {
                s.validity = r.validity; s.detail = r.validityDetail; s.display = display
                s.score = r.score; s.confidence = r.confidence
            }
        }
        guard drivesDisplay, display != shown else { return }
        shown = display
        updateSink.yield(Update(sequence: seq, display: display))
    }

    // MARK: Helpers

    /// Gap evidence that makes a window `window_spans_detected_gap` (project_io DATA_GAP_EVIDENCE).
    static let dataGaps: Set<GapEvidence> = [.sequenceSkip, .staleHalf, .duplicateCounter, .invalidCounter, .overflowSuspected]

    /// Nearest-rank percentiles in milliseconds; nil when nothing was measured.
    static func percentiles(_ values: [Double]) -> LiveRunRecord.Percentiles? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        func rank(_ q: Double) -> Double { v[min(v.count - 1, max(0, Int((q * Double(v.count)).rounded(.up)) - 1))] }
        return .init(count: v.count, p50: rank(0.5), p95: rank(0.95), max: v[v.count - 1])
    }
}
