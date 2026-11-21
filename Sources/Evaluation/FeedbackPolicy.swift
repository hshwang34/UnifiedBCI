import Foundation

/// What the participant is shown for each live prediction (brief 006, decision #27): the bar
/// only for a `valid`, confident prediction of a feedback-eligible window, otherwise hidden
/// with the state named in words. Pure, so every rule is unit-tested; the worker only scores.
public struct FeedbackPolicy: Sendable, Equatable {
    /// Confidence below this abstains (decision #39); stored with the live run.
    public private(set) var threshold: Double
    /// A prediction later than this after its window's last sample was drained, or no
    /// sample for this long, is `stale`.
    public private(set) var staleLimitNanos: Int64

    public static let defaultThreshold = 0.6
    public static let defaultStaleLimitMillis = 250

    /// The defaults (0.6, 250 ms).
    public init() {
        threshold = Self.defaultThreshold
        staleLimitNanos = Int64(Self.defaultStaleLimitMillis) * 1_000_000
    }

    /// Refuses a threshold outside 0.5 ≤ t < 1 (model confidence is never below 0.5, and 1
    /// would always abstain) or a stale limit outside 1…60 000 ms, before anything runs.
    public init(threshold: Double, staleLimitMillis: Int = FeedbackPolicy.defaultStaleLimitMillis) throws {
        guard threshold.isFinite, threshold >= 0.5, threshold < 1 else {
            throw WorkerError(code: "invalid_threshold", message: "the abstention threshold must be at least 0.50 and below 1.00")
        }
        guard (1...60_000).contains(staleLimitMillis) else {
            throw WorkerError(code: "invalid_threshold", message: "the stale limit must be 1 to 60 000 ms")
        }
        self.threshold = threshold
        staleLimitNanos = Int64(staleLimitMillis) * 1_000_000
    }

    public var staleLimitMillis: Int { Int(staleLimitNanos / 1_000_000) }

    public enum Display: Sendable, Equatable {
        /// The bar grows toward `side` (a class label); `length` is a fraction of the half-width.
        case bar(side: String, length: Double)
        /// No bar; `words` is the one line shown instead, nil outside the feedback span.
        case hidden(words: String?)

        public var isShown: Bool { if case .bar = self { true } else { false } }
    }

    /// The words for each state that hides the bar (brief 006 Live feedback criteria).
    public static func words(_ validity: Validity) -> String {
        switch validity {
        case .valid: return "Not confident"
        case .insufficientWindow: return "Waiting for enough signal"
        case .stale: return "Signal delayed"
        case .disconnected: return "Board disconnected"
        case .workerUnavailable: return "Analysis stopped"
        case .channelMismatch: return "Channels don't match the model"
        case .invalidInput: return "Invalid signal"
        }
    }

    /// Bar length for a confidence: (confidence − 0.5) / 0.5, clamped to 0…1.
    public static func barLength(confidence: Double) -> Double {
        guard confidence.isFinite else { return 0 }
        return min(max((confidence - 0.5) / 0.5, 0), 1)
    }

    /// The action for a prediction under this policy: a class only for a valid prediction
    /// at or above the threshold (abstention is a policy, never a third class).
    public func action(validity: Validity, confidence: Double?, label: String?) -> PredictionRecord.Action {
        guard validity == .valid, let c = confidence, c.isFinite, c >= threshold, let label else { return .abstain }
        return .chosen(label)
    }

    /// What to show for one logged prediction. A valid window outside the feedback span
    /// (decision #40: windows wholly inside the imagery period) shows nothing at all.
    public func display(for p: PredictionRecord) -> Display {
        guard p.validity == .valid else { return .hidden(words: Self.words(p.validity)) }
        guard p.feedbackEligible == true else { return .hidden(words: nil) }
        guard p.action.kind == .class, let side = p.action.label, let c = p.confidence else { return .hidden(words: Self.words(.valid)) }
        return .bar(side: side, length: Self.barLength(confidence: c))
    }

    /// Whether a prediction emitted at `emitted` for a window whose last sample was drained
    /// at `receipt` arrived too late to show.
    public func isLate(receipt: Int64, emitted: Int64) -> Bool { emitted - receipt > staleLimitNanos }

    /// Decision #41: a trial's live outcome is its cue-locked window (the one matching the
    /// training window), never the hop windows shown as feedback.
    public enum TrialOutcome: Sendable, Equatable {
        case chosen(String)
        case abstained
        /// No valid prediction for the window, with its validity (and detail).
        case invalid(Validity, String?)
    }

    public static func trialOutcomes(_ predictions: [PredictionRecord]) -> [String: TrialOutcome] {
        var out: [String: TrialOutcome] = [:]
        for p in predictions where p.windowKind == "cue_locked" {
            guard let trial = p.trialID, out[trial] == nil else { continue }
            if p.validity != .valid { out[trial] = .invalid(p.validity, p.validityDetail) }
            else if p.action.kind == .class, let label = p.action.label { out[trial] = .chosen(label) }
            else { out[trial] = .abstained }
        }
        return out
    }
}
