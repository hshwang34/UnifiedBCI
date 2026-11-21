import Foundation

// Frozen models (`models/<uuid>/model.json`) and live runs and replays (`live/<uuid>/`),
// brief 006. Older readers never open either directory, so no format bump
// (docs/data-contracts.md, "Frozen models and live runs").

/// Which fit inside an evaluation's `fitted.npz` a model uses: the recipe at the top level,
/// or the `baseline__`-prefixed one.
public enum ModelRole: String, Codable, Sendable { case reference, baseline }

/// One frozen model (decision #38): the evaluation's own fit on its training runs, so its
/// evidence is the result it came from. Immutable once committed. The arrays stay in the
/// pipeline directory (`pipelines/<sourcePipelineID>/fitted.npz`, a path built from the id,
/// never stored) and are named by their SHA-256; the worker refuses them if it changed.
public struct ModelRecord: Codable, Sendable, Equatable, Identifiable {
    public var formatVersion: Int = ContractVersion.format
    public var modelID: UUID
    public var name: String
    public var sourcePipelineID: UUID
    public var sourceResultID: UUID
    public var sourceRecordingID: UUID
    public var role: ModelRole
    public var recipe: String                     // "csp_rlda_v1" | "logvar_rlda_v1"
    public var featureKind: String                // the arrays' `feature_kind`, as validated
    public var expectedChannelIDs: [String]
    public var expectedSampleRateHz: Double
    public var bandpass: Bandpass
    public var window: Window
    /// The filter warm-up (`settling_samples`) the worker derived from the arrays.
    public var warmupSamples: Int
    /// Class labels in LDA class order: a positive score favours `classLabels[1]`.
    public var classLabels: [String]
    /// The training runs of the fit (its split manifest) and their sessions, null where the
    /// recording defines none; fresh-session evidence is derived from these.
    public var trainingRunIDs: [String]
    public var trainingSessionIDs: [String?]
    public var fittedSHA256: String
    public var configHash: String
    public var workerVersions: [String: String]
    public var frozenAt: Date
    public var id: UUID { modelID }

    public struct Bandpass: Codable, Sendable, Equatable {
        public var lowHz: Double
        public var highHz: Double
        public var order: Int
        public init(lowHz: Double, highHz: Double, order: Int) { self.lowHz = lowHz; self.highHz = highHz; self.order = order }
    }

    /// Trial window relative to the cue, in seconds (the evaluation's configuration).
    public struct Window: Codable, Sendable, Equatable {
        public var offsetSeconds: Double
        public var lengthSeconds: Double
        public init(offsetSeconds: Double, lengthSeconds: Double) { self.offsetSeconds = offsetSeconds; self.lengthSeconds = lengthSeconds }
    }

    public static let maxFileBytes = 256 * 1024

    /// Why a stored model can't be trusted, or nil (a `.bciproj` may come from anyone).
    public func problem(directoryID: UUID) -> String? {
        guard formatVersion >= 1, formatVersion <= ContractVersion.format else { return "format \(formatVersion)" }
        guard modelID == directoryID else { return "id does not match its directory" }
        guard ChannelMapRecord.isSane(name, maxLength: 120) else { return "name is empty, too long or has control characters" }
        guard !expectedChannelIDs.isEmpty, expectedChannelIDs.count <= ChannelMapRecord.maxChannels,
              Set(expectedChannelIDs).count == expectedChannelIDs.count,
              expectedChannelIDs.allSatisfy({ ChannelMapRecord.isSane($0, maxLength: 32) }) else { return "channel ids are empty, repeated or not plain text" }
        guard classLabels.count == 2, classLabels[0] != classLabels[1],
              classLabels.allSatisfy({ ChannelMapRecord.isSane($0) }) else { return "needs two distinct class labels" }
        guard expectedSampleRateHz.isFinite, expectedSampleRateHz > 0, expectedSampleRateHz <= 100_000 else { return "sample rate out of range" }
        guard window.offsetSeconds.isFinite, window.lengthSeconds.isFinite, window.offsetSeconds >= 0,
              window.lengthSeconds > 0, window.offsetSeconds + window.lengthSeconds <= 60 else { return "window out of range" }
        guard bandpass.lowHz.isFinite, bandpass.highHz.isFinite, bandpass.lowHz > 0, bandpass.highHz > bandpass.lowHz else { return "band-pass out of range" }
        guard (0...1_000_000).contains(warmupSamples) else { return "warm-up out of range" }
        guard trainingRunIDs.count == trainingSessionIDs.count, trainingRunIDs.count <= 1_000 else { return "training runs and sessions differ in count" }
        guard Self.isSHA256(fittedSHA256) else { return "fitted-arrays hash is not a SHA-256" }
        return nil
    }

    static func isSHA256(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// `live/<uuid>/run.json`: one live run (`kind: live`) or one stored replay (`kind: replay`).
/// A replay is written once (temp directory, then rename). A live run is written at start
/// and rewritten once at the end with its summaries, the same atomic rewrite as a manifest;
/// a run with no `endedAt` ended with the app. `predictions.jsonl` and `feedback.jsonl` next
/// to it are append-only and never rewritten.
public struct LiveRunRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case live, replay }

    public var formatVersion: Int = ContractVersion.format
    public var liveRunID: UUID
    public var kind: Kind
    public var modelID: UUID
    public var recordingID: UUID
    public var runIDs: [String]
    public var hopSamples: Int
    /// Confidence below this is `abstain` (decision #39, default 0.6), stored per run.
    public var abstainThreshold: Double
    /// Live only: a prediction older than this is `stale` (250 ms in brief 006).
    public var staleLimitMillis: Int?
    public var startedAt: Date
    public var endedAt: Date?
    public var parity: ParityReport?
    public var summary: Summary?
    public var latency: LatencySummary?
    public var replayCheck: ReplayCheck?
    /// Why logging stopped before the run ended (a log reached its size limit), or nil.
    public var loggingStopped: String?
    /// Lines that could not be appended to `feedback.jsonl` / `predictions.jsonl` (a write or
    /// fsync failed, or logging had stopped); nil when none failed. Each is missing from its log.
    public var feedbackWriteFailures: Int?
    public var predictionWriteFailures: Int?
    public var id: UUID { liveRunID }

    public init(liveRunID: UUID = UUID(), kind: Kind, modelID: UUID, recordingID: UUID, runIDs: [String], hopSamples: Int,
                abstainThreshold: Double, staleLimitMillis: Int?, startedAt: Date, endedAt: Date? = nil, parity: ParityReport? = nil,
                summary: Summary? = nil, latency: LatencySummary? = nil, replayCheck: ReplayCheck? = nil) {
        self.liveRunID = liveRunID; self.kind = kind; self.modelID = modelID; self.recordingID = recordingID
        self.runIDs = runIDs; self.hopSamples = hopSamples; self.abstainThreshold = abstainThreshold
        self.staleLimitMillis = staleLimitMillis; self.startedAt = startedAt; self.endedAt = endedAt
        self.parity = parity; self.summary = summary; self.latency = latency; self.replayCheck = replayCheck
    }

    /// Streaming vs offline (replay): per quantity the largest deviation seen and its
    /// declared tolerance, as the worker reported them.
    public struct ParityReport: Codable, Sendable, Equatable {
        public var passed: Bool
        public var windowsCompared: Int
        public var deviations: [Deviation]
        public var boundaryWindows: Int
        public var firstValidWindowStop: [Int]     // per segment, in segment order; -1 when none
        public var chunkings: [String]
        /// Cue-locked (training-window) windows among those compared.
        public var cueLockedCompared: Int?
        /// Where streaming and offline disagree, one plain line each (at most `maxMismatches`).
        public var mismatches: [String]?
        /// Which chunking's streamed predictions `predictions.jsonl` holds (the first one).
        public var storedChunking: String?
        public static let maxMismatches = 50
        public init(passed: Bool, windowsCompared: Int, deviations: [Deviation], boundaryWindows: Int, firstValidWindowStop: [Int], chunkings: [String],
                    cueLockedCompared: Int? = nil, mismatches: [String]? = nil, storedChunking: String? = nil) {
            self.passed = passed; self.windowsCompared = windowsCompared; self.deviations = deviations
            self.boundaryWindows = boundaryWindows; self.firstValidWindowStop = firstValidWindowStop; self.chunkings = chunkings
            self.cueLockedCompared = cueLockedCompared; self.mismatches = mismatches; self.storedChunking = storedChunking
        }
    }

    public struct Deviation: Codable, Sendable, Equatable {
        public var quantity: String               // "filtered", "features", "score", ...
        public var observed: Double?              // nil when nothing was compared
        public var allowed: Double
        public init(quantity: String, observed: Double?, allowed: Double) { self.quantity = quantity; self.observed = observed; self.allowed = allowed }
    }

    /// Prediction counts by validity and action, for live runs and replays alike.
    public struct Summary: Codable, Sendable, Equatable {
        public var predictions: Int
        public var byValidity: [String: Int]
        public var abstained: Int
        public init(predictions: Int, byValidity: [String: Int], abstained: Int) {
            self.predictions = predictions; self.byValidity = byValidity; self.abstained = abstained
        }
    }

    /// Software latency of a live run in milliseconds; transport and display are not measured.
    public struct LatencySummary: Codable, Sendable, Equatable {
        public var receiptToEmission: Percentiles?
        public var bufferWait: Percentiles?
        public var emissionToPresentation: Percentiles?
        public init(receiptToEmission: Percentiles?, bufferWait: Percentiles?, emissionToPresentation: Percentiles?) {
            self.receiptToEmission = receiptToEmission; self.bufferWait = bufferWait; self.emissionToPresentation = emissionToPresentation
        }
    }

    public struct Percentiles: Codable, Sendable, Equatable {
        public var count: Int
        public var p50: Double
        public var p95: Double
        public var max: Double
        public init(count: Int, p50: Double, p95: Double, max: Double) { self.count = count; self.p50 = p50; self.p95 = p95; self.max = max }
    }

    /// After a live run: the new recording replayed through the model vs what was logged live.
    public struct ReplayCheck: Codable, Sendable, Equatable {
        public var windowsCompared: Int
        public var windowsMatched: Int
        public var differingSequences: [Int]
        /// Differing windows a logged cause explains (frames dropped from the live buffer split
        /// the live segment, so its windows sit elsewhere than the recording's), and that cause.
        /// Only the rest are a bug. Optional; older readers ignore them.
        public var explainedSequences: [Int]?
        public var explanation: String?
        public init(windowsCompared: Int, windowsMatched: Int, differingSequences: [Int], explainedSequences: [Int]? = nil, explanation: String? = nil) {
            self.windowsCompared = windowsCompared; self.windowsMatched = windowsMatched; self.differingSequences = differingSequences
            self.explainedSequences = explainedSequences; self.explanation = explanation
        }

        /// Differing windows no logged cause explains.
        public var unexplained: [Int] { differingSequences.filter { !Set(explainedSequences ?? []).contains($0) } }
    }

    public static let maxFileBytes = 4 * 1024 * 1024

    public func problem(directoryID: UUID) -> String? {
        guard formatVersion >= 1, formatVersion <= ContractVersion.format else { return "format \(formatVersion)" }
        guard liveRunID == directoryID else { return "id does not match its directory" }
        guard hopSamples > 0, hopSamples <= 100_000 else { return "hop out of range" }
        guard abstainThreshold.isFinite, abstainThreshold >= 0.5, abstainThreshold < 1 else { return "abstention threshold out of range" }
        guard runIDs.count <= 1_000, staleLimitMillis.map({ (1...60_000).contains($0) }) ?? true else { return "runs or stale limit out of range" }
        guard [feedbackWriteFailures, predictionWriteFailures].allSatisfy({ $0.map { (0...Self.maxCount).contains($0) } ?? true }) else {
            return "write-failure counts out of range"
        }
        // Counts and times screens do arithmetic on: bounded, so a crafted file can't trap.
        if let c = replayCheck {
            guard (0...Self.maxCount).contains(c.windowsCompared), (0...c.windowsCompared).contains(c.windowsMatched),
                  c.differingSequences.count <= 1_000, (c.explainedSequences?.count ?? 0) <= 1_000,
                  (c.explanation?.count ?? 0) <= 500 else { return "replay check counts out of range" }
        }
        if let s = summary {
            guard (0...Self.maxCount).contains(s.predictions), (0...Self.maxCount).contains(s.abstained),
                  s.byValidity.count <= 64, s.byValidity.values.allSatisfy({ (0...Self.maxCount).contains($0) }) else { return "summary counts out of range" }
        }
        if let l = latency {
            for p in [l.receiptToEmission, l.bufferWait, l.emissionToPresentation].compactMap({ $0 }) {
                guard (0...Self.maxCount).contains(p.count), [p.p50, p.p95, p.max].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Self.maxMillis }),
                      p.p50 <= p.p95, p.p95 <= p.max else {
                    return "latency out of range"
                }
            }
        }
        return nil
    }

    /// Largest count a stored live run may claim (far above any real run: ~8 windows a second).
    public static let maxCount = 100_000_000
    /// Largest latency in milliseconds a stored live run may claim (a day).
    public static let maxMillis = 86_400_000.0
}

/// `live/<uuid>/feedback.jsonl`, one line per change of what the participant saw: the bar
/// (side and length as a fraction of the half-width) or hidden with its words, and the
/// presentation callback of the first frame that showed it. Keyed by prediction sequence.
public struct FeedbackRecord: Codable, Sendable, Equatable {
    public var predictionSequence: Int
    public var shown: Bool
    /// Class label the bar grows toward; nil when hidden.
    public var side: String?
    public var length: Double?
    /// The one line shown instead of the bar ("Model unsure", "Signal delayed", …).
    public var words: String?
    public var presentedAtMonotonicNanos: Int64?
    /// Why the bar was hidden: `no_cue`, `outside_span`, `abstain`, `stale`, `delayed` (too old
    /// at presentation, or a display stall), `invalid`, `disconnected`, `worker`, `stopped`.
    public var reason: String?

    public init(predictionSequence: Int, shown: Bool, side: String?, length: Double?, words: String?, presentedAtMonotonicNanos: Int64?,
                reason: String? = nil) {
        self.predictionSequence = predictionSequence; self.shown = shown; self.side = side
        self.length = length; self.words = words; self.presentedAtMonotonicNanos = presentedAtMonotonicNanos; self.reason = reason
    }
}
