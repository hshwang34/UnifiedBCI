import Foundation
import Synchronization

/// What the participant window draws for live feedback (brief 006 PR 7), decided per
/// refresh: the newest display the runner published, shown only while a cue is on screen
/// (fixation, rest, instructions and pauses show nothing). A bar older than the stale limit
/// at its refresh, or drawn after a display stall, is hidden as "Signal delayed" instead
/// (the stale rule enforced at presentation). Pure, so the rules are tested without a
/// display; `FeedbackFeed` wraps it for the display-link thread.
public struct FeedbackFrameState: Sendable, Equatable {
    public struct Shown: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
        /// Why the bar is hidden (feedback.jsonl `reason`); nil when it shows.
        public var reason: String?
        /// A new prediction caused this change (it counts in emission → presentation). False
        /// when the cue appearing or ending caused it, including for a prediction that arrived
        /// while the screen already showed the same thing (it is then not "new" when drawn).
        public var measured: Bool
    }

    public let staleLimitNanos: Int64
    public private(set) var latest: LiveInferenceRunner.Update?
    public private(set) var drawn: Shown?

    public init(staleLimitNanos: Int64 = FeedbackPolicy().staleLimitNanos) { self.staleLimitNanos = staleLimitNanos }

    public mutating func submit(_ u: LiveInferenceRunner.Update) {
        if let l = latest, l.sequence > u.sequence { return }      // never step back
        latest = u
    }

    /// What this refresh must draw when it differs from what is on screen, else nil.
    /// `targetNanos`: the refresh's presentation time (nil when unknown: a bar is then not
    /// trusted); `stall`: the display link missed frames before this refresh.
    public mutating func take(cueOnScreen: Bool, targetNanos: Int64? = nil, stall: Bool = false) -> Shown? {
        guard let latest else { return nil }
        var display = latest.display, reason = latest.reason
        if !cueOnScreen {
            (display, reason) = (.hidden(words: nil), "no_cue")
        } else if case .bar = display, stall || isOld(latest, at: targetNanos) {
            (display, reason) = (.hidden(words: FeedbackPolicy.words(.stale)), "delayed")
        }
        guard display != drawn?.display else {
            // Unchanged on screen, but this prediction is now the one behind it: when a later
            // change (the cue appearing) draws it, that is not a fresh prediction.
            drawn?.sequence = latest.sequence
            return nil
        }
        let next = Shown(sequence: latest.sequence, display: display, reason: reason, measured: latest.sequence != drawn?.sequence)
        drawn = next
        return next
    }

    /// When the run has stopped: the final hidden "stopped" record if the screen never logged
    /// one (the window was outside a cue, or no refresh took it), else nil. Its presentation
    /// time is unknown, so the report carries none rather than a guess.
    public mutating func stopRecord() -> Shown? {
        guard let latest, latest.reason == "stopped", drawn?.reason != "stopped" else { return nil }
        let last = Shown(sequence: latest.sequence, display: .hidden(words: nil), reason: "stopped", measured: false)
        drawn = last
        return last
    }

    /// What the operator mirror draws at `now` (`HostMonotonicClock`): the participant's newest
    /// display under the same stale rule, and hidden as "Signal delayed" while the participant
    /// window shows that for this same prediction (a stall). A newer bar that simply hasn't been
    /// drawn yet is judged by its own age, so the mirror doesn't flicker to "delayed" for a
    /// frame. Never a bar older than the stale limit.
    public func mirror(now: Int64) -> FeedbackPolicy.Display? {
        guard let latest else { return nil }
        let participantDelayed = drawn?.reason == "delayed" && drawn?.sequence == latest.sequence
        if case .bar = latest.display, participantDelayed || isOld(latest, at: now) {
            return .hidden(words: FeedbackPolicy.words(.stale))
        }
        return latest.display
    }

    private func isOld(_ u: LiveInferenceRunner.Update, at target: Int64?) -> Bool {
        guard let target, let e = u.emittedAt else { return true }
        return target - e > staleLimitNanos
    }
}

/// The runner's display updates in, presentation reports out. `submit` from any thread; the
/// display-link callback (main thread) calls `take` and then `presented` for the frame that
/// first showed a change, with that frame's target time on `HostMonotonicClock` (nil when the
/// refresh time is unknown). Reports leave in order through `reports`, unbounded so none is
/// ever dropped (there is at most one per refresh).
public final class FeedbackFeed: Sendable {
    public struct Report: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
        public var presentedAt: Int64?
        public var reason: String?
        public var measured: Bool = true
    }

    /// The side (−1 left, +1 right) each class label's bar grows toward.
    public let directions: [String: Double]
    public let reports: AsyncStream<Report>
    private let sink: AsyncStream<Report>.Continuation
    private let state: Mutex<FeedbackFrameState>

    public init(directions: [String: Double], staleLimitNanos: Int64 = FeedbackPolicy().staleLimitNanos) {
        self.directions = directions
        state = Mutex(FeedbackFrameState(staleLimitNanos: staleLimitNanos))
        (reports, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func submit(_ u: LiveInferenceRunner.Update) { state.withLock { $0.submit(u) } }
    public func take(cueOnScreen: Bool, targetNanos: Int64? = nil, stall: Bool = false) -> FeedbackFrameState.Shown? {
        state.withLock { $0.take(cueOnScreen: cueOnScreen, targetNanos: targetNanos, stall: stall) }
    }
    public func presented(_ s: FeedbackFrameState.Shown, at: Int64?) {
        sink.yield(Report(sequence: s.sequence, display: s.display, presentedAt: at, reason: s.reason, measured: s.measured))
    }
    public func mirror(now: Int64) -> FeedbackPolicy.Display? { state.withLock { $0.mirror(now: now) } }

    /// Ends the reports: the final hidden "stopped" record goes out first when the window
    /// didn't log one (submit the runner's last update before calling this), so every live
    /// run's feedback.jsonl ends hidden. Reports already queued stay queued, in order.
    public func finish() {
        if let last = state.withLock({ $0.stopRecord() }) {
            sink.yield(Report(sequence: last.sequence, display: last.display, presentedAt: nil, reason: last.reason, measured: false))
        }
        sink.finish()
    }

    /// −1 / +1 per class when the protocol cues one class with a left arrow and the other with
    /// a right arrow, so the bar's sides match the cues; nil otherwise (a live run is refused).
    public static func directions(classes: [ProtocolClass], modelLabels: [String]) -> [String: Double]? {
        guard modelLabels.count == 2 else { return nil }
        var out: [String: Double] = [:]
        for label in modelLabels {
            switch classes.first(where: { $0.label == label })?.cue {
            case .leftArrow?: out[label] = -1
            case .rightArrow?: out[label] = 1
            default: return nil
            }
        }
        return Set(out.values) == [-1, 1] ? out : nil
    }
}
