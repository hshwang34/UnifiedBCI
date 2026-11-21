import Foundation

/// The health panel's numbers (brief 004, "Preview and health"). Describes delivery only,
/// never signal quality. Times are `HostMonotonicClock` nanoseconds; intervals in seconds.
public struct StreamHealth: Sendable, Equatable {
    public struct GapTally: Sendable, Equatable {
        public var events = 0
        /// Sum of the counter estimates; ambiguous ones are counted in `ambiguous` too.
        public var estimatedMissingSamples = 0
        public var ambiguous = 0
    }

    public struct Spread: Sendable, Equatable {
        public var p50: Double
        public var p95: Double
        public var max: Double
    }

    /// Stream segment since connect: 0, then +1 for every reconnect.
    public var segment = 0
    public var reconnects = 0
    public var samplesThisSegment = 0
    /// Counter-derived: (received + counter-evidenced missing) samples per monotonic second,
    /// over the last 10 s of drains. Nil until the window spans at least 1 s.
    public var effectiveRateHz: Double?
    /// Gaps by evidence, as stored (`sequence_skip`, `stale_half`, `invalid_counter`,
    /// `overflow_suspected`, `disconnect`, and the provenance-only kinds).
    public var gaps: [GapEvidence: GapTally] = [:]
    /// `receipt_interval`: no samples for ≥ 1 s, then contiguous counters. "Arrival pause,
    /// no samples lost by counter"; never counted as lost samples.
    public var arrivalPauses = 0
    public var drainInterval: Spread?
    public var timestampInterval: Spread?
    /// Writer backlog, last commit, end reason (nil when not recording).
    public var writer: RecordingWriter.Status?
    public var freeBytes: Int64?
    /// Recording time left before the 100 MB stop (decision #33), at this board's data rate.
    public var hoursLeft: Double?
}

/// Builds `StreamHealth` from drained chunks. Owned by the drain loop; never shared.
struct HealthAccumulator {
    static let windowNanos: Int64 = 10_000_000_000
    static let pauseNanos: Int64 = 1_000_000_000
    /// Evidence that already explains a pause before a block's first sample.
    static let counterEvidence: Set<GapEvidence> = [.sequenceSkip, .staleHalf, .invalidCounter, .overflowSuspected]

    private(set) var health = StreamHealth()
    private let timestampRow: Int
    private let timestampCapacity: Int
    private var rateWindow: [(t: Int64, n: Int)] = []
    private var drainIntervals: [(t: Int64, seconds: Double)] = []
    private var timestampIntervals: [Double] = []
    private var lastDrain: Int64?
    private var lastSampleDrain: Int64?
    private var lastTimestamp: Double?

    init(board: BoardDescription) {
        timestampRow = board.timestampRow
        timestampCapacity = max(1, board.samplingRate * 10)
    }

    /// A new stream segment (connect or reconnect): per-segment counts and windows restart.
    mutating func beginSegment(reconnect: Bool) {
        if reconnect { health.segment += 1; health.reconnects += 1 }
        health.samplesThisSegment = 0
        health.effectiveRateHz = nil
        rateWindow = []; drainIntervals = []; timestampIntervals = []
        lastDrain = nil; lastSampleDrain = nil; lastTimestamp = nil
    }

    mutating func noteGap(_ evidence: GapEvidence) { health.gaps[evidence, default: .init()].events += 1 }

    /// Takes one drain and its stored gaps. Returns a `receipt_interval` gap to store before
    /// the block's first sample when samples paused ≥ 1 s and counters show nothing lost.
    mutating func ingest(_ chunk: SampleChunk, gaps: [RecordingManifest.Gap]) -> RecordingManifest.Gap? {
        let t = chunk.drainedAtMonotonicNanos
        if let lastDrain { drainIntervals.append((t, Double(t - lastDrain) / 1e9)) }
        lastDrain = t
        drainIntervals.removeAll { $0.t < t - Self.windowNanos }
        guard chunk.count > 0 else {
            updateRate(at: t)          // a stall must pull the rate down, not freeze it
            return nil
        }

        var pause: RecordingManifest.Gap?
        if health.samplesThisSegment > 0, let last = lastSampleDrain, t - last >= Self.pauseNanos,
           !gaps.contains(where: { $0.afterSampleIndex == -1 && Self.counterEvidence.contains($0.evidence) }) {
            pause = .init(afterSampleIndex: -1, evidence: .receiptInterval, estimatedMissingSamples: nil, ambiguous: false)
            health.arrivalPauses += 1
        }
        lastSampleDrain = t
        health.samplesThisSegment += chunk.count

        var missing = 0
        for gap in gaps {
            var tally = health.gaps[gap.evidence, default: .init()]
            tally.events += 1
            tally.estimatedMissingSamples += gap.estimatedMissingSamples ?? 0
            if gap.ambiguous { tally.ambiguous += 1 }
            health.gaps[gap.evidence] = tally
            // Only a skip leaves counter slots without a sample. A stale half is a received
            // sample (one Daisy half lost, its counter not advanced): it is already in
            // `chunk.count` and adds no slot, so it is not counted again.
            if gap.evidence == .sequenceSkip { missing += gap.estimatedMissingSamples ?? 0 }
        }

        rateWindow.append((t, chunk.count + missing))
        updateRate(at: t)

        for value in chunk.row(timestampRow) {
            if let lastTimestamp { timestampIntervals.append(value - lastTimestamp) }
            lastTimestamp = value
        }
        if timestampIntervals.count > 2 * timestampCapacity {
            timestampIntervals.removeFirst(timestampIntervals.count - timestampCapacity)
        }
        return pause
    }

    /// Counter slots per monotonic second from the window's first drain to `t` (that drain's
    /// own samples arrived before the window opened). Empty window after samples: 0.
    private mutating func updateRate(at t: Int64) {
        rateWindow.removeAll { $0.t < t - Self.windowNanos }
        if let first = rateWindow.first {
            guard t - first.t >= Self.pauseNanos else { return }
            let counted = rateWindow.dropFirst().reduce(0) { $0 + $1.n }
            health.effectiveRateHz = Double(counted) / (Double(t - first.t) / 1e9)
        } else if health.samplesThisSegment > 0 {
            health.effectiveRateHz = 0
        }
    }

    /// The panel's numbers; spreads are computed here (about once per second), not per drain.
    func snapshot() -> StreamHealth {
        var h = health
        h.drainInterval = Self.spread(drainIntervals.map(\.seconds))
        h.timestampInterval = Self.spread(timestampIntervals.suffix(timestampCapacity))
        return h
    }

    static func spread<C: Collection>(_ values: C) -> StreamHealth.Spread? where C.Element == Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard let max = sorted.last else { return nil }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((q * Double(sorted.count - 1)).rounded()))] }
        return .init(p50: at(0.5), p95: at(0.95), max: max)
    }
}
