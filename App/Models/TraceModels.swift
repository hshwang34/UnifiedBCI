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
    static let unavailableMessage = "The window could not be loaded. The recording is unchanged."
    static let flaggedLegend = "Flagged channels carry a flag and list the rules that fired."
    static let flaggedLegendShared = "Flagged channels carry a flag; hover a lane for its details."
    static let warmupTag = "warm-up"
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
        /// The lane's full height in the channel's unit: the trace is drawn within
        /// ± `scale` / 2 of `center` and clipped there, so it never crosses into a neighbour.
        let scale: Double
        /// Why there is no trace (band-pass can't run, non-finite samples), else nil.
        let note: String?
        /// Some of the trace runs past ± `scale` / 2 and is clipped at the lane's edge.
        let clipped: Bool
        let accessibilityLabel: String
        var isFlagged: Bool { !flags.isEmpty }
        var halfScale: Double { scale / 2 }
    }

    /// One lane height per unit: channels with the same unit share it.
    struct Scale: Equatable {
        let unit: String
        let height: Double
    }

    let lanes: [Lane]
    let startS: Double
    let endS: Double
    let segmentDurationS: Double
    let scales: [Scale]
    let scaleText: String
    /// Set when the whole window lies in the band-pass warm-up, so the scale comes from it.
    let scaleNote: String?
    let rangeText: String
    /// "Signal · 0.0–10.0 s of 42 s", or just "Signal" before a window arrives.
    let headerText: String
    /// Warm-up inside this window (band-passed only), in segment seconds.
    let warmup: ClosedRange<Double>?
    let warmupNote: String?
    /// Brief 011: "All 16 channels: Large deflections" when the flagged lanes share their
    /// flags; the lanes then carry a marker only and the detail is in each lane's tooltip.
    var sharedFlags: String? { QualityModel.sharedFlagLine(lanes.map(\.flags)) }

    /// `flags`: channel id → titles of the rules that fired in this segment.
    init(window w: SignalWindow, processed: Bool, flags: [String: [String]]) {
        startS = w.startS
        endS = w.startS + w.durationS
        segmentDurationS = w.segmentDurationS
        let range = "\(Fmt.fixed(startS, 1))–\(Fmt.fixed(endS, 1)) s of \(QualityModel.num(w.segmentDurationS)) s"
        rangeText = range
        headerText = Self.header(range)
        if processed, let bp = w.bandpass, bp.warmupEndS > startS {
            warmup = startS...min(bp.warmupEndS, endS)
            warmupNote = Self.warmupText(bp.warmupEndS)
        } else {
            warmup = nil
            warmupNote = nil
        }
        let traces = w.channels.map { processed ? $0.bandpassed : $0.raw }
        // Scale from the settled part, so a filter transient doesn't flatten every lane; a
        // window wholly inside the warm-up has no settled part, so it scales from all of it.
        func spans(after settled: Double, unit: String) -> [Double] {
            zip(w.channels, traces).compactMap { ch, t -> Double? in
                guard let t, QualityModel.unitName(ch.unit) == unit else { return nil }
                let kept = zip(w.tS, zip(t.min, t.max)).filter { $0.0 >= settled }.map(\.1)
                guard let lo = kept.compactMap(\.0).min(), let hi = kept.compactMap(\.1).max() else { return nil }
                return hi - lo
            }.sorted()
        }
        var units: [String] = []
        for ch in w.channels where !units.contains(QualityModel.unitName(ch.unit)) { units.append(QualityModel.unitName(ch.unit)) }
        var inWarmup = false
        let warm = warmup
        let built: [Scale] = units.map { unit in
            var s = spans(after: warm?.upperBound ?? -.infinity, unit: unit)
            if s.isEmpty, warm != nil {
                s = spans(after: -.infinity, unit: unit)
                if !s.isEmpty { inWarmup = true }
            }
            return Scale(unit: unit, height: Self.nice(s.isEmpty ? 1 : s[s.count / 2]))
        }
        scales = built
        scaleText = Self.scaleText(built)
        scaleNote = inWarmup ? Self.insideWarmupText : nil
        lanes = zip(w.channels, traces).map { ch, trace in
            let flagTitles = flags[ch.id] ?? []
            let unit = QualityModel.unitName(ch.unit)
            let scale = built.first { $0.unit == unit }?.height ?? 1
            let flagText = flagTitles.isEmpty ? "no flags" : "flags: \(flagTitles.joined(separator: ", "))"
            guard let trace else {
                let note = ch.bandpassedReason ?? "no samples"
                return Lane(id: ch.id, label: ch.label, flags: flagTitles, points: [], center: 0, scale: scale, note: note, clipped: false,
                            accessibilityLabel: "\(ch.label), \(flagText). Not available: \(note).")
            }
            var points: [Point] = []
            var run = 0
            for (t, (lo, hi)) in zip(w.tS, zip(trace.min, trace.max)) {
                if let lo, let hi { points.append(Point(t: t, lo: lo, hi: hi, run: run)) } else if points.last?.run == run { run += 1 }
            }
            let mids = points.map { ($0.lo + $0.hi) / 2 }.sorted()
            let center = mids.isEmpty ? 0 : mids[mids.count / 2]
            let half = scale / 2
            let clipped = points.contains { $0.hi - center > half || center - $0.lo > half }
            let extent = [trace.lo, trace.hi].allSatisfy { $0 != nil }
                ? "min \(QualityModel.num(trace.lo)) \(unit), max \(QualityModel.num(trace.hi)) \(unit)" : "no finite samples"
            let kind = processed ? "Band-passed" : "Raw"
            return Lane(id: ch.id, label: ch.label, flags: flagTitles,
                        points: points.map { Point(t: $0.t, lo: $0.lo - center, hi: $0.hi - center, run: $0.run) },
                        center: center, scale: scale, note: nil, clipped: clipped,
                        accessibilityLabel: "\(ch.label), \(flagText). \(kind) \(range): \(extent)\(clipped ? ", exceeds the lane height" : "").")
        }
    }

    static let insideWarmupText = "This whole window lies in the band-pass warm-up, so the lane height comes from warm-up samples."

    static func header(_ range: String?) -> String {
        [title, range].compactMap { $0 }.joined(separator: " · ")
    }

    static func scaleText(_ scales: [Scale]) -> String {
        "Lane height " + scales.map { "\(scaleNumber($0.height)) \($0.unit)" }.joined(separator: " · ")
    }

    /// A 1-2-5 height with the decimals it needs: 500, 2, 0.05.
    static func scaleNumber(_ v: Double) -> String {
        Fmt.fixed(v, v > 0 && v < 1 ? Int(-floor(log10(v))) : 0)
    }

    static func tickLabel(_ t: Double) -> String { "\(Fmt.fixed(t, 0)) s" }

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
