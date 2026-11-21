import Foundation
import Synchronization

/// The frames the runner handed to the participant window and not yet drawn, with the rule
/// `CueDisplay.show` documents: a new frame drops every pending frame whose time is at or
/// after its own; each refresh draws the newest frame due, and a frame overtaken before any
/// refresh drew it is never reported. Pure, so the rule is tested without a display.
public struct CueFrameQueue: Sendable {
    public struct Pending: Sendable {
        public let frame: CueFrame
        public let at: Int64
        public let token: PresentationToken
        public let sink: any PresentationSink
    }

    /// Strictly increasing in `at` (the drop rule keeps it so).
    public private(set) var pending: [Pending] = []

    public init() {}

    public mutating func submit(_ frame: CueFrame, at: Int64, token: PresentationToken, sink: any PresentationSink) {
        pending.removeAll { $0.at >= at }
        pending.append(Pending(frame: frame, at: at, token: token, sink: sink))
    }

    /// The frame to draw for a refresh that reaches the screen at `targetNanos` (the first
    /// refresh at or after each frame's time), or nil when nothing is due. Every due frame
    /// leaves the queue; only the newest is drawn and reported.
    public mutating func take(forRefreshAt targetNanos: Int64) -> Pending? {
        let due = pending.prefix { $0.at <= targetNanos }
        guard let newest = due.last else { return nil }
        pending.removeFirst(due.count)
        return newest
    }
}

/// Converts a display-link timestamp (`CACurrentMediaTime` seconds, on `mach_absolute_time`)
/// to `HostMonotonicClock` nanoseconds by an offset sampled in the same callback (brief 005,
/// "Scheduling"). The two clocks may drift apart across sleep, which is why the offset is
/// taken per callback and never cached.
public enum PresentationClock {
    public static func monotonicNanos(mediaTime: Double, sampledMonotonicNanos: Int64, sampledMediaTime: Double) -> Int64 {
        let delta = mediaTime - sampledMediaTime
        // A hostile or broken timestamp must not trap the conversion.
        guard delta.isFinite, abs(delta) < 3600 else { return sampledMonotonicNanos }
        return sampledMonotonicNanos + Int64((delta * 1e9).rounded())
    }
}

/// The participant window's side of `CueDisplay`: the runner's actor calls `show`, the
/// display-link callback (main thread) calls `refresh`. Thread-safe and non-blocking.
public final class CueFrameScheduler: CueDisplay {
    private let queue = Mutex(CueFrameQueue())

    public init() {}

    public func show(_ frame: CueFrame, atMonotonicNanos: Int64, token: PresentationToken, sink: any PresentationSink) {
        queue.withLock { $0.submit(frame, at: atMonotonicNanos, token: token, sink: sink) }
    }

    /// Called once per refresh with that refresh's target presentation time on
    /// `HostMonotonicClock`. Returns the frame to draw now; the caller reports it with
    /// `report` once the frame is set for this refresh.
    public func take(forRefreshAt targetNanos: Int64) -> CueFrameQueue.Pending? {
        queue.withLock { $0.take(forRefreshAt: targetNanos) }
    }

    /// Drops everything not yet drawn (the window is closing); none of it is reported.
    public func clear() { queue.withLock { $0 = CueFrameQueue() } }
}
