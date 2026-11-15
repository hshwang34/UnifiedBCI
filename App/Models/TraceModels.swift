import Foundation

/// Every string and number the Quality tab's signal view shows (brief 002), built from a
/// `SignalWindow` and the segment's quality flags. All channels share one vertical scale,
/// so a flat channel looks flat and a noisy one looks noisy; flagged lanes carry a flag
/// symbol and their rule titles, never colour alone.
struct TraceModel: Equatable {
    static let title = "Signal"
    static let rawTitle = "Raw"
    static let processedTitle = QualityModel.processedTitle
    static let earlier = "Earlier"
    static let later = "Later"
    static let positionLabel = "Window start"
    static let loading = "Loading the window…"
    static let unavailableTitle = "Signal unavailable"
    static let flaggedLegend = "Flagged channels carry a flag and list the rules that fired."
    static let warmupTag = "warm-up"
    static let timeAxis = "Time in segment (s)"
    /// Why the warm-up is drawn rather than cut: the evaluation skips it, the view says so.
    static func warmupText(_ seconds: Double) -> String {
        "Shaded: band-pass warm-up, the first \(Fmt.fixed(seconds, 2)) s of the segment. Shown here; evaluation leaves out trials that start in it."
    }

    /// One envelope point: min and max of its samples at `t` seconds. `run` increments
    /// after a gap (no finite samples), so no line is drawn across missing data.
    struct Point: Equatable {
        let t: Double
        let lo: Double
        let hi: Double
        let run: Int
    }

    struct Lane: Identifiable, Equatable {
        let id: String
        let label: String
        let flags: [String]
        /// Points relative to `center`, in the channel's unit.
        let points: [Point]
        let center: Double
        /// Why there is no trace (band-pass can't run, non-finite samples), else nil.
        let note: String?
        /// Some of the trace runs past the lane's scale and is clipped there.
        let clipped: Bool
        let accessibilityLabel: String
        var isFlagged: Bool { !flags.isEmpty }
    }

    let lanes: [Lane]
    let startS: Double
    let endS: Double
    let segmentDurationS: Double
    /// Height of one lane in the channels' unit; traces are clipped at ± one lane.
    let laneScale: Double
    let scaleText: String
    let rangeText: String
    /// Warm-up inside this window (band-passed only), in segment seconds.
    let warmup: ClosedRange<Double>?
    let warmupNote: String?

    /// `flags`: channel id → titles of the rules that fired in this segment.
    init(window w: SignalWindow, processed: Bool, flags: [String: [String]]) {
        startS = w.startS
        endS = w.startS + w.durationS
        segmentDurationS = w.segmentDurationS
        let range = "\(Fmt.fixed(startS, 1))–\(Fmt.fixed(endS, 1)) s of \(QualityModel.num(w.segmentDurationS)) s"
        rangeText = range
        if processed, let bp = w.bandpass, bp.warmupEndS > startS {
            warmup = startS...min(bp.warmupEndS, endS)
            warmupNote = Self.warmupText(bp.warmupEndS)
        } else {
            warmup = nil
            warmupNote = nil
        }
        let settled = warmup?.upperBound ?? -.infinity
        let traces = w.channels.map { processed ? $0.bandpassed : $0.raw }
        // Scale from the settled part, so a filter transient doesn't flatten every lane.
        let spans = traces.compactMap { t -> Double? in
            guard let t else { return nil }
            let lo = zip(w.tS, t.min).filter { $0.0 >= settled }.compactMap(\.1).min()
            let hi = zip(w.tS, t.max).filter { $0.0 >= settled }.compactMap(\.1).max()
            guard let lo, let hi else { return nil }
            return hi - lo
        }.sorted()
        laneScale = Self.nice(spans.isEmpty ? 1 : spans[spans.count / 2])
        let unit = w.channels.first.map { QualityModel.unitName($0.unit) } ?? ""
        scaleText = "Lane height \(QualityModel.num(laneScale)) \(unit)"
        let scale = laneScale
        lanes = zip(w.channels, traces).map { ch, trace in
            let flagTitles = flags[ch.id] ?? []
            let unit = QualityModel.unitName(ch.unit)
            let flagText = flagTitles.isEmpty ? "no flags" : "flags: \(flagTitles.joined(separator: ", "))"
            guard let trace else {
                let note = ch.bandpassedReason ?? "no samples"
                return Lane(id: ch.id, label: ch.label, flags: flagTitles, points: [], center: 0, note: note, clipped: false,
                            accessibilityLabel: "\(ch.label), \(flagText). Not available: \(note).")
            }
            var points: [Point] = []
            var run = 0
            for (t, (lo, hi)) in zip(w.tS, zip(trace.min, trace.max)) {
                if let lo, let hi { points.append(Point(t: t, lo: lo, hi: hi, run: run)) } else if points.last?.run == run { run += 1 }
            }
            let mids = points.map { ($0.lo + $0.hi) / 2 }.sorted()
            let center = mids.isEmpty ? 0 : mids[mids.count / 2]
            let clipped = points.contains { $0.hi - center > scale || center - $0.lo > scale }
            let extent = [trace.lo, trace.hi].allSatisfy { $0 != nil }
                ? "min \(QualityModel.num(trace.lo)) \(unit), max \(QualityModel.num(trace.hi)) \(unit)" : "no finite samples"
            let kind = processed ? "Band-passed" : "Raw"
            return Lane(id: ch.id, label: ch.label, flags: flagTitles,
                        points: points.map { Point(t: $0.t, lo: $0.lo - center, hi: $0.hi - center, run: $0.run) },
                        center: center, note: nil, clipped: clipped,
                        accessibilityLabel: "\(ch.label), \(flagText). \(kind) \(range): \(extent)\(clipped ? ", exceeds the lane scale" : "").")
        }
    }

    /// The window start for moving one window earlier or later, inside the segment.
    static func step(_ start: Double, by direction: Double, segment: Double) -> Double {
        clampStart(start + direction * SignalWindowRunner.durationS, segment: segment)
    }

    static func clampStart(_ start: Double, segment: Double) -> Double {
        min(max(0, start), max(0, segment - SignalWindowRunner.durationS))
    }

    /// The smallest 1-2-5 step at or above `v`, so the scale reads as a round number.
    static func nice(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 1 }
        let p = pow(10, floor(log10(v)))
        return [1.0, 2, 5, 10].map { $0 * p }.first { $0 >= v * (1 - 1e-9) } ?? 10 * p
    }

    /// Time-axis ticks: whole seconds, every 2 s for a 10 s window.
    var ticks: [Double] {
        let first = (startS / 2).rounded(.up) * 2
        return stride(from: first, through: endS + 1e-9, by: 2).map { $0 }
    }
}

extension QualityModel {
    /// Channel id → titles of the rules that fired in a section (the trace lanes' flags).
    func flagTitles(section: Int) -> [String: [String]] {
        guard sections.indices.contains(section) else { return [:] }
        return Dictionary(sections[section].rows.map { ($0.id, $0.flags.map(\.title)) }, uniquingKeysWith: { a, _ in a })
    }
}
