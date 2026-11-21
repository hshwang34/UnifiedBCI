import Foundation
import Synchronization

/// What the participant window draws for live feedback (brief 006 PR 7), decided per
/// refresh: the newest display the runner published, shown only while a cue is on screen
/// (fixation, rest, instructions and pauses show nothing). Pure, so the rule is tested
/// without a display; `FeedbackFeed` wraps it for the display-link thread.
public struct FeedbackFrameState: Sendable, Equatable {
    public struct Shown: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
    }

    public private(set) var latest: LiveInferenceRunner.Update?
    public private(set) var drawn: Shown?

    public init() {}

    public mutating func submit(_ u: LiveInferenceRunner.Update) {
        if let l = latest, l.sequence > u.sequence { return }      // never step back
        latest = u
    }

    /// What this refresh must draw when it differs from what is on screen, else nil.
    /// Nothing is drawn (or logged) before the first prediction.
    public mutating func take(cueOnScreen: Bool) -> Shown? {
        guard let latest else { return nil }
        let next = Shown(sequence: latest.sequence, display: cueOnScreen ? latest.display : .hidden(words: nil))
        guard next.display != drawn?.display else { return nil }
        drawn = next
        return next
    }
}

/// The runner's display updates in, presentation reports out. `submit` from any thread; the
/// display-link callback (main thread) calls `take` and then `presented` for the frame that
/// first showed a change, with that frame's target time on `HostMonotonicClock` (nil when the
/// refresh time is unknown). Reports leave in order through `reports`.
public final class FeedbackFeed: Sendable {
    public struct Report: Sendable, Equatable {
        public var sequence: Int
        public var display: FeedbackPolicy.Display
        public var presentedAt: Int64?
    }

    /// The side (−1 left, +1 right) each class label's bar grows toward.
    public let directions: [String: Double]
    public let reports: AsyncStream<Report>
    private let sink: AsyncStream<Report>.Continuation
    private let state = Mutex(FeedbackFrameState())

    public init(directions: [String: Double]) {
        self.directions = directions
        (reports, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func submit(_ u: LiveInferenceRunner.Update) { state.withLock { $0.submit(u) } }
    public func take(cueOnScreen: Bool) -> FeedbackFrameState.Shown? { state.withLock { $0.take(cueOnScreen: cueOnScreen) } }
    public func presented(_ s: FeedbackFrameState.Shown, at: Int64?) { sink.yield(Report(sequence: s.sequence, display: s.display, presentedAt: at)) }
    public func finish() { sink.finish() }

    /// −1 or +1 for a class: left and right arrows by their side; other cues (up, down) by
    /// the model's class order, the first class to the left.
    public static func directions(classes: [ProtocolClass], modelLabels: [String]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, label) in modelLabels.enumerated() {
            switch classes.first(where: { $0.label == label })?.cue {
            case .leftArrow?: out[label] = -1
            case .rightArrow?: out[label] = 1
            default: out[label] = i == 0 ? -1 : 1
            }
        }
        return out
    }
}
