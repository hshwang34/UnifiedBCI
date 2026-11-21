import Foundation

/// Protocol events on their way to `events.jsonl` (brief 005, "Sample association"). Runs
/// inside the recording writer's consumer, which sees every sample in order.
///
/// An event that wants a sample waits here for it. With a marker value, it takes the first
/// sample of its segment whose marker row holds that value, drained after the event was
/// queued (`brainflow_marker`): BrainFlow writes the marker on the next sample after the
/// call, and the event is always queued before the call. Without a marker (the insertion
/// failed, or no presentation callback came), or when no marked sample arrives within
/// `markerTimeoutNanos`, it falls back to `nearest_receipt_timestamp`: the event's time is
/// converted to wall clock with the newest (monotonic, wall) pair taken at drain, and the
/// sample whose BrainFlow timestamp is nearest is picked. Neither is corrected for transport
/// delay. An event is written only once the sample it names is committed, and events are
/// written in the order they were queued.
struct EventAssociator {
    static let markerTimeoutNanos: Int64 = 1_000_000_000
    /// How long after the event's time samples must keep arriving before the fallback
    /// picks one, so the nearest sample is not merely the newest.
    static let fallbackSettleNanos: Int64 = 250_000_000
    /// Timestamps kept for the fallback (≈ 30 s at 125 Hz).
    static let historyLimit = 4096

    struct Entry {
        var events: [EventRecord]
        var marker: Double?
        /// The event's time on `HostMonotonicClock` for the fallback; nil: no association wanted.
        var at: Int64?
        var queuedAt: Int64
        var segment: Int?
        var resolved: Bool
    }

    let recordingID: UUID
    private(set) var queue: [Entry] = []
    private var history: [(index: Int, timestamp: Double)] = []
    private var pair: RecordingWriter.ClockPair?

    init(recordingID: UUID) { self.recordingID = recordingID }

    /// `openSegment` nil: no segment is recording, so nothing can be associated.
    mutating func enqueue(_ events: [EventRecord], marker: Double?, at: Int64?, queuedAt: Int64, openSegment: Int?) {
        let wants = at != nil && openSegment != nil
        queue.append(.init(events: events, marker: wants ? marker : nil, at: at, queuedAt: queuedAt,
                           segment: openSegment, resolved: !wants))
    }

    mutating func markerFailed(_ eventID: UUID) {
        if let i = queue.firstIndex(where: { !$0.resolved && $0.events.contains { $0.eventID == eventID } }) { queue[i].marker = nil }
    }

    /// One accepted block of `segment`, whose first sample has index `firstIndex`.
    mutating func observe(markers: ArraySlice<Double>?, timestamps: ArraySlice<Double>?, firstIndex: Int, segment: Int,
                          drainedAt: Int64, pair newPair: RecordingWriter.ClockPair?) {
        if let newPair { pair = newPair }
        if let timestamps {
            for (j, t) in timestamps.enumerated() where t.isFinite { history.append((firstIndex + j, t)) }
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        if let markers {
            for (j, v) in markers.enumerated() where v != 0 {
                guard let i = queue.firstIndex(where: { !$0.resolved && $0.segment == segment && $0.marker == v && $0.queuedAt <= drainedAt })
                else { continue }      // a second copy of a marker (Daisy) or one nobody waits for
                resolve(i, sample: firstIndex + j, method: "brainflow_marker")
            }
        }
        for i in queue.indices where !queue[i].resolved && queue[i].segment == segment {
            let e = queue[i]
            let due = e.marker == nil ? drainedAt >= (e.at ?? 0) &+ Self.fallbackSettleNanos
                                      : drainedAt &- e.queuedAt > Self.markerTimeoutNanos
            if due { fallback(i, below: nil) }
        }
    }

    /// The segment closed with `committed` samples on disk: everything still waiting in it
    /// takes the fallback among those, and an association past them is replaced.
    mutating func closeSegment(_ segment: Int, committed: Int) {
        for i in queue.indices where queue[i].segment == segment {
            let sample = queue[i].events.first?.sampleAssociation?.sampleIndex
            if !queue[i].resolved || (sample ?? -1) >= committed { fallback(i, below: committed) }
        }
        history = []
    }

    /// Events ready to write, in queue order: resolved, and naming a committed sample.
    mutating func ready(openSegment: Int?, committed: Int) -> [EventRecord] {
        var out: [EventRecord] = []
        while let e = queue.first, e.resolved {
            if let a = e.events.first?.sampleAssociation, a.segment == openSegment, a.sampleIndex >= committed { break }
            out += e.events
            queue.removeFirst()
        }
        return out
    }

    /// Everything left (the recording is ending); waiting events take the fallback.
    mutating func drainAll(committed: Int) -> [EventRecord] {
        for i in queue.indices where !queue[i].resolved { fallback(i, below: committed) }
        defer { queue = [] }
        return queue.flatMap(\.events)
    }

    private mutating func resolve(_ i: Int, sample: Int?, method: String) {
        let association = sample.map { EventRecord.SampleAssociation(recordingID: recordingID, segment: queue[i].segment ?? 0, sampleIndex: $0, method: method) }
        for k in queue[i].events.indices { queue[i].events[k].sampleAssociation = association }
        queue[i].resolved = true
    }

    /// Nearest BrainFlow timestamp to the event's time, among samples below `limit`; no
    /// association when there is no sample, no clock pair or no event time.
    private mutating func fallback(_ i: Int, below limit: Int?) {
        guard let at = queue[i].at, let pair else { return resolve(i, sample: nil, method: "") }
        let wall = pair.wallSeconds + Double(at &- pair.monotonicNanos) / 1e9
        let nearest = history.lazy.filter { limit == nil || $0.index < limit! }.min { abs($0.timestamp - wall) < abs($1.timestamp - wall) }
        resolve(i, sample: nearest?.index, method: "nearest_receipt_timestamp")
    }
}
