import Foundation

/// Every string the Quality tab shows (brief 002), built from an `InspectionReport`.
/// Rule titles and rule text come from the worker's `rules()`, never from constants here,
/// so the wording and the thresholds cannot drift apart (decision #23). Flags are
/// measurements, not verdicts (decisions #22, #25): no row, summary or label calls a
/// channel good, clean or neural, and unflagged reads "None of these rules fired".
struct QualityModel: Equatable {
    static let footer = "These checks describe the recording. They can't show that a signal comes from the brain."
    static let noFlags = "None of these rules fired"
    static let nothingAssessed = "No rule could be assessed"
    static let rawTitle = "Raw (mean removed)"
    static let processedTitle = "Band-passed (reference pipeline)"
    static let frequencyAxis = "Frequency (Hz)"
    static let powerAxis = "Power (dB)"

    /// One line per check that fired: "<rule title> · <measured value in words>".
    struct Flag: Equatable {
        let ruleID: String
        let title: String
        let detail: String
        var text: String { "\(title) · \(detail)" }
    }

    struct ChannelRow: Identifiable, Equatable {
        let id: String
        let label: String
        let kindUnit: String
        let flags: [Flag]
        /// Checks that could not run, grouped by reason: "Flatline, Large deflections · not assessed (unit mV)".
        let notAssessed: [String]
        /// `noFlags` / `nothingAssessed` when nothing fired; nil when there are flags.
        let status: String?
        /// VoiceOver: channel first, then flags (brief 002 acceptance criteria).
        let accessibilityLabel: String
    }

    /// A PSD line for Swift Charts. Null bins are gaps: `run` increments after each, so
    /// plotting with `series: run` never draws across missing power.
    struct Point: Equatable {
        let hz: Double
        let db: Double
        let run: Int
    }

    struct Spectrum: Identifiable, Equatable {
        let id: String
        let label: String
        let raw: [Point]
        let processed: [Point]
        /// Why a spectrum is missing (non-finite samples, segment too short), else nil.
        let rawNote: String?
        let processedNote: String?
        /// "FC3: strongest peak 10.2 Hz". Describes the spectrum's shape; names no rhythm.
        let accessibilitySummary: String
    }

    struct Section: Identifiable, Equatable {
        let id: Int
        let title: String
        /// Counts only: "Flags on 15 of 16 channels in segment 1".
        let summary: String
        let rows: [ChannelRow]
        let spectra: [Spectrum]
        /// The chart's upper frequency bound (brief: 1 Hz to Nyquist).
        var nyquistHz: Double = 0
        /// "All 16 channels: Large deflections" when every flagged channel carries the same
        /// flags (brief 011): said once, and the rows carry a marker only.
        var sharedFlags: String? { QualityModel.sharedFlagLine(rows.map { $0.flags.map(\.title) }) }
    }

    /// One line for flags every flagged channel shares; nil when fewer than two channels are
    /// flagged or their flags differ. Counts only, never a verdict (decision #22).
    static func sharedFlagLine(_ flags: [[String]]) -> String? {
        let flagged = flags.filter { !$0.isEmpty }
        guard flagged.count >= 2, let first = flagged.first, flagged.allSatisfy({ $0 == first }) else { return nil }
        let who = flagged.count == flags.count ? "All \(flags.count) channels" : "\(flagged.count) of \(flags.count) channels"
        return "\(who): \(first.joined(separator: ", "))"
    }

    struct LegendRow: Identifiable, Equatable {
        let id: String
        let title: String
        let rule: String
        let flagWhen: String
        var text: String { "\(rule) · flag when \(flagWhen)" }
    }

    let legend: [LegendRow]
    let sections: [Section]
    /// One line for the whole recording, the segment summaries joined.
    let summary: String

    /// `segmentStarts`: worker segment index → its stored start (`StreamSegment.startedAtMonotonicNanos`)
    /// in seconds after the recording's earliest segment start. A segment missing from it is
    /// titled by its duration only.
    init(report: InspectionReport, segmentStarts: [Int: Double] = [:]) {
        let titles = Dictionary(report.rules.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let rules = Dictionary(report.rules.map { ($0.id, $0.rule) }, uniquingKeysWith: { a, _ in a })
        let limits = Dictionary(report.rules.map { ($0.id, Self.numbers(in: $0.flagWhen)) }, uniquingKeysWith: { a, _ in a })
        legend = report.rules.map { LegendRow(id: $0.id, title: $0.title, rule: $0.rule, flagWhen: $0.flagWhen) }
        // Numbered by position, as the progress events count segments ("segment k of n"),
        // and placed by each segment's own stored start, never assumed back to back.
        sections = report.segments.enumerated().map { position, seg in
            let number = position + 1
            let rows = seg.channels.map { Self.row($0, titles: titles, rules: rules, limits: limits) }
            let flagged = rows.filter { !$0.flags.isEmpty }.count
            return Section(
                id: seg.index,
                title: Self.segmentTitle(number: number, runID: seg.runId, start: segmentStarts[seg.index], duration: seg.durationS, rateHz: seg.sfreq),
                summary: "Flags on \(flagged) of \(rows.count) channels in segment \(number)",
                rows: rows, spectra: seg.channels.map(Self.spectrum), nyquistHz: seg.sfreq / 2)
        }
        summary = sections.map(\.summary).joined(separator: "; ")
    }

    // MARK: Rows

    private static func row(_ c: InspectionReport.Channel, titles: [String: String], rules: [String: String],
                            limits: [String: [Double]]) -> ChannelRow {
        let title = { (id: String) in titles[id] ?? id }
        var flags: [Flag] = []
        var skipped: [(reason: String, titles: [String])] = []
        func skip(_ reason: String, _ t: String) {
            if let i = skipped.firstIndex(where: { $0.reason == reason }) { skipped[i].titles.append(t) } else { skipped.append((reason, [t])) }
        }
        for check in c.checks {
            if !check.assessable {
                skip(check.reason ?? "not assessed", title(check.rule))
                continue
            }
            // A mains line the rate can't reach is noted even when the other line was assessed.
            for line in check.measured?.lines ?? [] where !line.assessable {
                skip("\(Fmt.hertz(line.hz)) \(line.reason ?? "not assessed")", title(check.rule))
            }
            if check.flagged {
                flags.append(Flag(ruleID: check.rule, title: title(check.rule), detail: detail(check, rule: rules[check.rule], limits: limits[check.rule] ?? [])))
            }
        }
        let notAssessed = skipped.map { "\($0.titles.joined(separator: ", ")) · \($0.reason)" }
        let assessed = c.checks.filter(\.assessable).count
        let status: String? = !flags.isEmpty ? nil
            : assessed == c.checks.count ? noFlags
            : assessed == 0 ? nothingAssessed
            : "None of the \(assessed) assessed rules fired"
        let kindUnit = "\(kindName(c.kind)) · \(unitName(c.unit))"
        let spoken = ([status].compactMap { $0 } + flags.map(\.text) + notAssessed).joined(separator: ". ")
        return ChannelRow(id: c.id, label: c.label, kindUnit: kindUnit, flags: flags, notAssessed: notAssessed,
                          status: status, accessibilityLabel: "\(c.label), \(kindName(c.kind)) \(unitName(c.unit)). \(spoken).")
    }

    /// The measured value in plain words, with the worker's rule text where the threshold matters.
    /// Numbers that sit on a rule's flag boundary (from its `flag_when`) are shown with
    /// enough decimals that the shown value is on the same side of the boundary as the
    /// measured one (`faithful`).
    private static func detail(_ check: InspectionReport.Check, rule: String?, limits: [Double]) -> String {
        let m = check.measured
        let because = rule.map { " (\($0))" } ?? ""
        switch check.rule {
        case "flatline":
            return "\(num(m?.flatS)) s of \(num(m?.totalS)) s flat\(because)"
        case "pinned":
            let runs = m?.runs ?? 0
            return "\(runs) \(runs == 1 ? "run" : "runs"), longest \(m?.longestRunSamples.map(String.init) ?? "—") samples\(because)"
        case "large_deflection":
            let pct = m?.fraction.map { "\(faithful($0 * 100, digits: 0, boundaries: limits + [0, 100])) %" } ?? "—"
            return "\(pct) of windows (\(m?.windowsOver.map(String.init) ?? "—") of \(m?.windows.map(String.init) ?? "—")) with \(rule ?? "large peak-to-peak")"
        case "mains_line":
            let fired = (m?.lines ?? []).filter(\.flagged).map { "\(Fmt.hertz($0.hz)) line \($0.db.map { faithful($0, digits: 1, boundaries: limits) } ?? "—") dB over neighbours" }
            return fired.isEmpty ? "flagged" : fired.joined(separator: "; ")
        case "outlier_amplitude":
            return "variance \(ratio(m?.ratio, limits)) the median channel"
        case "outlier_high_frequency":
            let band = m?.bandHz.flatMap { $0.count == 2 ? "\(num($0[0]))–\(num($0[1])) Hz" : nil } ?? "high-frequency"
            return "\(band) power \(ratio(m?.ratio, limits)) the median channel"
        default:
            return "flagged\(because)"
        }
    }

    // MARK: Spectra

    private static func spectrum(_ c: InspectionReport.Channel) -> Spectrum {
        let peak = c.peakHz.map { "strongest peak \(Fmt.fixed($0, 1)) Hz" } ?? (c.psd.raw == nil ? "no spectrum" : "no spectral peak")
        return Spectrum(id: c.id, label: c.label, raw: points(c.psd.freqs, c.psd.raw), processed: points(c.psd.freqs, c.psd.processed),
                        rawNote: c.psd.raw == nil ? (c.psd.processedReason ?? "no spectrum") : nil,
                        processedNote: c.psd.processed == nil ? (c.psd.processedReason ?? "no spectrum") : nil,
                        accessibilitySummary: "\(c.label): \(peak)")
    }

    private static func points(_ freqs: [Double?], _ db: [Double?]?) -> [Point] {
        guard let db else { return [] }
        var out: [Point] = []
        var run = 0
        for (f, v) in zip(freqs, db) {
            if let f, let v, f >= 1 { out.append(Point(hz: f, db: v, run: run)) } else if out.last?.run == run { run += 1 }
        }
        return out
    }

    // MARK: Formatting

    /// "Segment 1 · S001R04 · 0:00–0:42 at 160 Hz": the run named only when it has a human
    /// name (a live recording's run ids are UUIDs), and its span from its stored start. With no
    /// stored start (nil) only the duration is named ("Segment 2 · 42 s at 160 Hz").
    static func segmentTitle(number: Int, runID: String, start: Double?, duration: Double, rateHz: Double) -> String {
        let run = runID.isEmpty || UUID(uuidString: runID) != nil ? "" : " · \(runID)"
        let span = start.map { "\(clock($0))–\(clock($0 + duration))" } ?? "\(num(duration)) s"
        return "Segment \(number)\(run) · \(span) at \(Fmt.hertz(rateHz))"
    }

    /// Longest time `clock` names (100 days); beyond it, or not finite, it reads "—".
    static let clockLimitSeconds = 8_640_000.0

    /// "0:08", "12:05", "1:02:03"; "—" for NaN, infinity or an absurd value (never traps).
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, abs(seconds) <= clockLimitSeconds else { return "—" }
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Whole numbers without decimals ("42"), otherwise `digits` ("8.5"); "—" for null.
    static func num(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return v == v.rounded() && digits <= 1 ? Fmt.fixed(v, 0) : Fmt.fixed(v, digits)
    }

    static func ratio(_ v: Double?, _ boundaries: [Double] = []) -> String {
        guard let v else { return "—×" }
        return "\(faithful(v, digits: v < 1 ? 2 : 1, boundaries: boundaries))×"
    }

    /// `v` with at least `digits` decimals, adding decimals (up to 6) until the rounded
    /// value lies on the same side of every boundary as `v` itself: 0.101 of windows
    /// against "> 10 %" reads "10.1 %", never "10 %"; 5.04× against "> 5×" reads "5.04×".
    static func faithful(_ v: Double, digits: Int, boundaries: [Double]) -> String {
        var d = digits
        while true {
            let s = Fmt.fixed(v, d)
            let r = Double(s) ?? v
            if d >= 6 || boundaries.allSatisfy({ (r > $0) == (v > $0) && (r < $0) == (v < $0) }) { return s }
            d += 1
        }
    }

    /// The numbers in a rule's flag condition: "> 5× or < 0.2×" → [5, 0.2].
    static func numbers(in text: String) -> [Double] {
        text.split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
    }

    static func kindName(_ kind: String) -> String {
        ["eeg", "emg", "eog", "ecg"].contains(kind.lowercased()) ? kind.uppercased() : kind
    }

    static func unitName(_ unit: String) -> String {
        if unit.trimmingCharacters(in: .whitespaces).isEmpty { return "unit not declared" }
        return ["uv", "µv", "μv", "microvolt", "microvolts"].contains(unit.lowercased()) ? "µV" : unit
    }
}

// MARK: - Quality tab (brief 002 PR 4)

/// What the Quality tab shows for the selected recording (`ProjectSession.qualityState`).
enum QualityTabState: Equatable {
    /// Not inspected in this session (or another recording's run is in the way): an Inspect button.
    case notStarted
    case running(InspectionRunner.Progress)
    case ready(QualityModel)
    /// The worker could not start, died or timed out: the "analysis unavailable" banner with Retry.
    case unavailable(details: String)
    /// The worker refused: a banner without Retry, as for evaluation.
    case failed(details: String)
    case cancelled
}

extension QualityModel {
    /// Each segment's stored start (`startedAtMonotonicNanos`) in seconds after the earliest
    /// one, by index. An imported dataset stores every run on its own clock from 0, so its
    /// segments each read from 0:00; nothing here assumes the segments are back to back.
    static func segmentStarts(_ segments: [RecordingManifest.StreamSegment]) -> [Int: Double] {
        guard let first = segments.map(\.startedAtMonotonicNanos).min() else { return [:] }
        return Dictionary(segments.map { ($0.index, Double($0.startedAtMonotonicNanos - first) / 1e9) }, uniquingKeysWith: { a, _ in a })
    }

    static let tabTitle = "Quality"
    static let inspectButton = "Inspect"
    static let notStartedText = "Run the six quality checks on every channel and segment of this recording."
    static let cancelledText = "Inspection cancelled. Nothing was kept."
    static let unavailableTitle = "Analysis unavailable"
    static let unavailableMessage = "The analysis worker stopped. Your recording is unchanged."
    static let failedTitle = "Inspection failed"
    static let failedMessage = "The analysis worker refused this request; nothing changed. Retrying without a change will fail the same way."
    static let progressLabel = "Inspection progress"
    static let cancelButton = "Cancel"
    static let legendTitle = "Rules"
    static let spectrumTitle = "Spectrum"
    static let segmentPicker = "Segment"
    static let flagsColumn = "Flags"
    static let channelColumn = "Channel"
    static let kindUnitColumn = "Kind · unit"
    /// Montage caption while the Quality tab is open (decision #17: a shape, not a colour scale).
    static let ringCaption = "Ringed electrodes have at least one flag in this segment."
    static let electrodeFlagged = "has quality flags"

    static func progressText(_ p: InspectionRunner.Progress) -> String {
        switch p {
        case .starting: return "Starting the analysis worker…"
        case .loading: return "Reading the recording…"
        case .segment(let k, let of): return "Checking segment \(k) of \(of)…"
        }
    }

    /// The selected channel's spectrum, or the segment's first when none (or another
    /// segment's channel) is selected, so the chart is never empty while data exists.
    func spectrum(section: Int, channel: String?) -> Spectrum? {
        guard sections.indices.contains(section) else { return nil }
        let spectra = sections[section].spectra
        return spectra.first { $0.id == channel } ?? spectra.first
    }

    /// Channel ids with at least one flag in a segment (the montage rings).
    func flaggedChannels(section: Int) -> Set<String> {
        guard sections.indices.contains(section) else { return [] }
        return Set(sections[section].rows.filter { !$0.flags.isEmpty }.map(\.id))
    }
}

extension QualityModel.Spectrum {
    func series(processed: Bool) -> [QualityModel.Point] { processed ? self.processed : raw }

    /// VoiceOver for the spectrum on screen. Raw: the worker's peak summary. Band-passed:
    /// its highest-power frequency (the worker's peak describes the raw spectrum only).
    func accessibilitySummary(processed: Bool) -> String {
        guard processed else { return accessibilitySummary }
        guard let top = self.processed.max(by: { $0.db < $1.db }) else { return "\(label): no band-passed spectrum" }
        return "\(label), band-passed: highest power at \(Fmt.fixed(top.hz, 1)) Hz"
    }

    /// "Band-passed (reference pipeline) not available · <worker reason>", nil when it has points.
    func unavailableText(processed: Bool) -> String? {
        guard series(processed: processed).isEmpty else { return nil }
        let title = processed ? QualityModel.processedTitle : QualityModel.rawTitle
        return "\(title) not available · \((processed ? processedNote : rawNote) ?? "no spectrum")"
    }
}
