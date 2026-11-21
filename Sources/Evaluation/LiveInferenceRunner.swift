import Foundation
import Synchronization

/// Live inference for one live run (brief 006): its own `WorkerClient`, so a long fit never
/// blocks a prediction; fed from the `AcquisitionSession` fan-out (never a second board read)
/// with `live_push`, one drained chunk at a time. Decides validity in Swift: abstention,
/// `stale`, `insufficient_window`, `invalid_input`, `disconnected` and `worker_unavailable` are
/// explicit states that hide the bar (decision #27). Every due window is logged to
/// `predictions.jsonl`; every change of what the participant sees to `feedback.jsonl`.
///
/// Cues are placed like brief 005's `EventAssociator`: on the sample whose marker row holds
/// the cue's BrainFlow marker (the sample replay uses), else by an estimate from the drain
/// time corrected by the measured buffer wait, flagged on the trial's record. A cue that
/// can't reach the worker is never dropped silently: its trial gets an outcome record.
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
        /// The board's marker row, for marker-exact cue samples; nil: estimates only.
        public var markerRow: Int?
        public var policy: FeedbackPolicy
        /// `live_push` answers within this or the worker counts as unavailable (brief: 1 s).
        public var workerTimeout: Duration = .seconds(1)
        public var tickInterval: Duration = .milliseconds(50)

        public init(model: ModelRecord, arraysPath: String, channelRows: [Int], channelIDs: [String], sampleRateHz: Double,
                    timestampRow: Int?, markerRow: Int?, policy: FeedbackPolicy = .init()) {
            self.model = model; self.arraysPath = arraysPath; self.channelRows = channelRows; self.channelIDs = channelIDs
            self.sampleRateHz = sampleRateHz; self.timestampRow = timestampRow; self.markerRow = markerRow; self.policy = policy
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
        /// Valid hop windows and how many of them abstained (the operator's abstain rate).
        public var validHops = 0
        public var abstainedHops = 0
        /// Receipt → emission so far, in milliseconds (operator panel; `run.json` at the end).
        public var receiptToEmission: LiveRunRecord.Percentiles?
        /// Each trial's live outcome so far (decision #41), by trial id.
        public var outcomes: [String: FeedbackPolicy.TrialOutcome] = [:]

        /// Valid hop windows that abstained, 0…1; nil before the first valid window.
        public var abstainRate: Double? { validHops > 0 ? Double(abstainedHops) / Double(validHops) : nil }
    }

    /// One change of the display, for the participant window: it calls `presented` when the
    /// frame showing it is on screen.
    public struct Update: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
    }

    /// Where a cue landed: on the stream (segment and sample since its start, as the fan-out
    /// numbers them) and in the worker; `method` as in `EventRecord.SampleAssociation`.
    public struct CuePlacement: Sendable, Equatable {
        public var streamSegment: Int
        public var streamSample: Int
        public var method: String
    }

    public static let markerMethod = "brainflow_marker"
    public static let estimateMethod = "drain_time_minus_buffer_wait"

    public nonisolated let configuration: Configuration
    public nonisolated var status: Status { published.withLock { $0 } }
    public nonisolated var placements: [String: CuePlacement] { placed.withLock { $0 } }
    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateSink: AsyncStream<Update>.Continuation
    private nonisolated let published = Mutex(Status())
    private nonisolated let placed = Mutex<[String: CuePlacement]>([:])

    private struct WaitingCue { var trialID: String; var marker: Double?; var presentedAt: Int64; var queuedAt: Int64; var lengthSeconds: Double }

    private let launch: WorkerLaunch?
    private let writer: LiveRunWriter?
    private let now: @Sendable () -> Int64
    private let sourceState: @Sendable () -> AcquisitionSession.State
    private var client: WorkerClient?
    private var session: String?
    private var loops: [Task<Void, Never>] = []
    private var unsubscribe: (@Sendable () -> Void)?
    private var sequence = 0
    private var shown: FeedbackPolicy.Display?
    /// Stream position: the segment and next sample the fan-out should deliver.
    private var streamSegment: Int?
    private var nextStreamSample = 0
    /// Worker position: its segment id (new on every discontinuity) and next sample; the
    /// stream sample of worker sample 0.
    private var workerSegment = -1
    private var workerNext = 0
    private var workerOrigin = 0
    private var lastDrain: Int64?
    private var lastFrameEnd: (sample: Int, drained: Int64)?
    /// Cues waiting for their marked sample, and cues placed but not yet sent.
    private var waiting: [WaitingCue] = []
    private var pendingCues: [LiveCue] = []
    private var cueMethods: [String: String] = [:]
    /// A condition that overrides predictions (stale stream, disconnected, worker gone).
    private var condition: Validity?
    private var records: [PredictionRecord] = []
    private var bufferWaitsMs: [Double] = []
    private var presentationMs: [Double] = []
    private var receiptMs: [Double] = []
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
    /// before anything runs), then subscribes to `source`'s fan-out (only now, so no backlog
    /// builds up while the worker starts). `stop()` unsubscribes.
    public func start(source: AcquisitionSession) async throws {
        try await start {
            let (id, frames) = source.inferenceFrames()
            return (frames, { source.removeInferenceConsumer(id) })
        }
    }

    /// The same with any frame source (tests feed hand-made frames).
    func start(subscribe: @Sendable () -> (AsyncStream<AcquisitionSession.InferenceFrame>, @Sendable () -> Void)) async throws {
        guard let launch else { throw WorkerError(code: "launch_failed", message: "no analysis worker is available") }
        let c = WorkerClient(launch: launch)
        client = c
        do {
            _ = try await c.start()
            session = try await c.liveOpen(model: configuration.model, arraysPath: configuration.arraysPath, channelIDs: configuration.channelIDs,
                                           sampleRateHz: configuration.sampleRateHz).session
        } catch {
            await c.shutdown()
            client = nil
            throw error
        }
        let (frames, cancel) = subscribe()
        unsubscribe = cancel
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

    /// Ends the run: unsubscribes, closes the worker session (its unfinished cue-locked
    /// windows are logged), stops the worker and writes the summaries into `run.json` (with
    /// `runIDs`, the protocol runs it covered, when given).
    @discardableResult
    public func stop(runIDs: [String]? = nil) async -> (summary: LiveRunRecord.Summary, latency: LiveRunRecord.LatencySummary) {
        unsubscribe?()
        unsubscribe = nil
        loops.forEach { $0.cancel() }
        loops = []
        for cue in waiting { await lose(cue.trialID, "cue_lost_run_stopped") }
        waiting = []
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
        let latency = LiveRunRecord.LatencySummary(receiptToEmission: Self.percentiles(receiptMs), bufferWait: Self.percentiles(bufferWaitsMs),
                                                   emissionToPresentation: Self.percentiles(presentationMs))
        try? await writer?.finish(endedAt: Date(), summary: summary, latency: latency, replayCheck: nil, runIDs: runIDs)
        return (summary, latency)
    }

    /// A cue presented at `presentedAt` (`HostMonotonicClock`) whose imagery lasts
    /// `lengthSeconds`. With `marker` (the BrainFlow marker the protocol inserted, brief 005)
    /// it waits for the marked sample; without one, or after `EventAssociator.markerTimeoutNanos`,
    /// it is placed by the estimate.
    public func addCue(trialID: String, marker: Double?, presentedAt: Int64, lengthSeconds: Double) async {
        guard condition != .workerUnavailable else { return await lose(trialID, "cue_lost_worker_unavailable") }
        let cue = WaitingCue(trialID: trialID, marker: marker, presentedAt: presentedAt, queuedAt: now(), lengthSeconds: lengthSeconds)
        if marker == nil || configuration.markerRow == nil { return await placeByEstimate(cue) }
        waiting.append(cue)
    }

    /// The participant window showed `sequence`'s display on the frame presented at `at`,
    /// on `HostMonotonicClock` (the cue window converts its display-link time, brief 005).
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

    /// Test seam: one frame, handled to completion (no stream, no timing).
    func ingest(_ frame: AcquisitionSession.InferenceFrame) async { await handle(frame) }

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
        // State changes first, logging after: a log line suspends the actor, and a cue added
        // meanwhile must land in the new segment, not be counted as lost with the old one.
        var lost: (cues: [String], reason: String, dropped: Int?)?
        if frame.segment != streamSegment || frame.firstSample != nextStreamSample {
            if streamSegment != nil {
                let dropped = frame.segment == streamSegment
                lost = (waiting.map(\.trialID) + pendingCues.map(\.trialID), dropped ? "cue_lost_frames_dropped" : "cue_lost_stream_restarted",
                        dropped ? frame.firstSample - nextStreamSample : nil)
                waiting = []
                pendingCues = []
            }
            workerSegment += 1
            workerNext = 0
            workerOrigin = frame.firstSample
        }
        streamSegment = frame.segment
        nextStreamSample = frame.firstSample + chunk.count
        let first = workerNext
        workerNext += chunk.count
        lastFrameEnd = (first + chunk.count - 1, chunk.drainedAtMonotonicNanos)
        if let lost {
            if let n = lost.dropped { await enterOnce(.insufficientWindow, detail: "frames_dropped:\(n)") }
            for trial in lost.cues { await lose(trial, lost.reason) }
        }
        if condition == .stale || condition == .disconnected { condition = nil }
        await placeMarkedCues(chunk, first: first)
        guard condition != .workerUnavailable, let c = client, let s = session else {
            for cue in pendingCues { await lose(cue.trialID, "cue_lost_worker_unavailable") }
            pendingCues = []
            return
        }

        let rows = configuration.channelRows.map { Array(chunk.row($0)) }
        let gaps = frame.gaps.filter { Self.dataGaps.contains($0.evidence) }
            .map { LiveGap(afterSample: first + $0.afterSampleIndex, evidence: $0.evidence.rawValue) }
        let cues = pendingCues
        pendingCues = []
        let results: [LivePushResult]
        do {
            results = try await c.livePush(session: s, segment: workerSegment, firstSample: first, rows: rows, gaps: gaps, cues: cues,
                                           timeout: configuration.workerTimeout)
        } catch let error as WorkerError where error.code == "non_finite_samples" {
            // Nothing reached the worker: log the chunk as invalid input, restart the segment.
            let segment = workerSegment
            workerSegment += 1
            workerNext = 0
            workerOrigin = nextStreamSample
            for cue in cues { await lose(cue.trialID, "cue_lost_push_refused") }
            await log(record(.invalidInput, detail: "non_finite_samples", segment: segment,
                             range: .init(start: first, count: chunk.count), receipt: chunk.drainedAtMonotonicNanos))
            return
        } catch {
            for cue in cues { await lose(cue.trialID, "cue_lost_worker_unavailable") }
            await workerLost("\(error)")
            return
        }
        for r in results { await log(r.predictions, receipt: chunk.drainedAtMonotonicNanos, compute: r.workerComputeNanos) }
    }

    // MARK: Cues

    /// Marked samples in this chunk place the cues waiting for them; a cue whose marker
    /// hasn't come within the timeout falls back to the estimate.
    private func placeMarkedCues(_ chunk: SampleChunk, first: Int) async {
        if let row = configuration.markerRow, row < chunk.numRows {
            for (j, v) in chunk.row(row).enumerated() where v != 0 {
                guard let i = waiting.firstIndex(where: { $0.marker == v && $0.queuedAt <= chunk.drainedAtMonotonicNanos }) else { continue }
                let cue = waiting.remove(at: i)
                place(cue, workerSample: first + j, method: Self.markerMethod)
            }
        }
        let due = waiting.filter { chunk.drainedAtMonotonicNanos - $0.queuedAt > EventAssociator.markerTimeoutNanos }
        waiting.removeAll { w in due.contains { $0.trialID == w.trialID } }
        for cue in due { await placeByEstimate(cue) }
    }

    /// The newest drained chunk's last sample was received about one buffer wait before its
    /// drain; the cue's sample is counted from there at the nominal rate.
    private func placeByEstimate(_ cue: WaitingCue) async {
        guard let end = lastFrameEnd, workerSegment >= 0 else { return await lose(cue.trialID, "cue_lost_no_stream") }
        let waitNanos = Int64((Self.median(bufferWaitsMs.suffix(64)) ?? 0) * 1e6)
        let sample = end.sample + Int((Double(cue.presentedAt - (end.drained - waitNanos)) / 1e9 * configuration.sampleRateHz).rounded())
        guard sample >= 0 else { return await lose(cue.trialID, "cue_lost_before_segment") }
        place(cue, workerSample: sample, method: Self.estimateMethod)
    }

    private func place(_ cue: WaitingCue, workerSample: Int, method: String) {
        let length = Int((cue.lengthSeconds * configuration.sampleRateHz).rounded())
        pendingCues.append(LiveCue(sample: workerSample, trialID: cue.trialID, endSample: workerSample + max(length, 0)))
        cueMethods[cue.trialID] = method
        let p = CuePlacement(streamSegment: streamSegment ?? 0, streamSample: workerOrigin + workerSample, method: method)
        placed.withLock { $0[cue.trialID] = p }
    }

    /// The trial's outcome record when its cue never reached the worker.
    private func lose(_ trialID: String, _ reason: String) async {
        var r = record(.insufficientWindow, detail: reason, segment: max(workerSegment, 0), range: nil, receipt: nil)
        r.windowKind = "cue_locked"
        r.trialID = trialID
        await log(r)
    }

    // MARK: Conditions

    /// Every tick: a disconnected board, a dead worker or a silent stream hides the bar now.
    private func tick() async {
        guard !loops.isEmpty else { return }
        if condition != .workerUnavailable, let c = client, await c.state != .ready { return await workerLost("the inference worker exited") }
        switch sourceState() {
        case .interrupted, .failed, .disconnected, .stopping:
            await enterOnce(.disconnected, detail: "acquisition_interrupted")
        default:
            if let d = lastDrain, now() - d > configuration.policy.staleLimitNanos { await enterOnce(.stale, detail: "no_samples_drained") }
        }
    }

    private func workerLost(_ why: String) async {
        guard condition != .workerUnavailable else { return }
        if let c = client { await c.forceTerminate() }
        await enterOnce(.workerUnavailable, detail: "worker_lost: \(why)")
        for cue in waiting { await lose(cue.trialID, "cue_lost_worker_unavailable") }
        waiting = []
    }

    /// Logs one prediction-less record when a condition starts, and hides the bar. A frame
    /// drop (`insufficient_window`) is logged every time; it doesn't persist as a condition.
    private func enterOnce(_ v: Validity, detail: String) async {
        guard condition != v, condition != .workerUnavailable else { return }
        if v != .insufficientWindow { condition = v }
        await log(record(v, detail: detail, segment: max(workerSegment, 0), range: nil, receipt: nil))
    }

    private func record(_ v: Validity, detail: String, segment: Int, range: PredictionRecord.SampleRange?, receipt: Int64?) -> PredictionRecord {
        PredictionRecord(pipelineID: configuration.model.sourcePipelineID, inputSegment: segment, inputSampleRange: range, score: nil, validity: v,
                         emittedAtMonotonicNanos: now(), action: .abstain, feedbackPresentedAtMonotonicNanos: nil, validityDetail: detail,
                         acquisitionReceiptMonotonicNanos: receipt)
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
            if r.windowKind == "cue_locked", let trial = r.trialID { r.cueSampleMethod = cueMethods[trial] }
            // Lateness hides feedback; it never changes a trial's outcome window (decision #41).
            if r.windowKind != "cue_locked", r.validity == .valid, let receipt, policy.isLate(receipt: receipt, emitted: t) {
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
        if let rc = r.acquisitionReceiptMonotonicNanos, let e = r.emittedAtMonotonicNanos { receiptMs.append(Double(e - rc) / 1e6) }
        let latency = drivesDisplay && r.acquisitionReceiptMonotonicNanos != nil ? Self.percentiles(receiptMs) : nil
        let outcome = FeedbackPolicy.trialOutcomes([r]).first
        published.withLock { s in
            s.predictions += 1
            s.lastSequence = seq
            if drivesDisplay {
                s.validity = r.validity; s.detail = r.validityDetail; s.display = display
                s.score = r.score; s.confidence = r.confidence
                if r.validity == .valid, r.inputSampleRange != nil {
                    s.validHops += 1
                    if r.action.kind == .abstain { s.abstainedHops += 1 }
                }
                if let latency { s.receiptToEmission = latency }
            }
            if let outcome, s.outcomes[outcome.key] == nil { s.outcomes[outcome.key] = outcome.value }
        }
        guard drivesDisplay, display != shown else { return }
        shown = display
        updateSink.yield(Update(sequence: seq, display: display))
    }

    // MARK: Helpers

    /// Gap evidence that makes a window `window_spans_detected_gap` (project_io DATA_GAP_EVIDENCE).
    static let dataGaps: Set<GapEvidence> = [.sequenceSkip, .staleHalf, .duplicateCounter, .invalidCounter, .overflowSuspected]

    static func median<C: Collection>(_ values: C) -> Double? where C.Element == Double {
        let v = values.sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    /// Nearest-rank percentiles in milliseconds; nil when nothing was measured.
    static func percentiles(_ values: [Double]) -> LiveRunRecord.Percentiles? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        func rank(_ q: Double) -> Double { v[min(v.count - 1, max(0, Int((q * Double(v.count)).rounded(.up)) - 1))] }
        return .init(count: v.count, p50: rank(0.5), p95: rank(0.95), max: v[v.count - 1])
    }
}
