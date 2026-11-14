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

    init(report: InspectionReport) {
        let titles = Dictionary(report.rules.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let rules = Dictionary(report.rules.map { ($0.id, $0.rule) }, uniquingKeysWith: { a, _ in a })
        legend = report.rules.map { LegendRow(id: $0.id, title: $0.title, rule: $0.rule, flagWhen: $0.flagWhen) }
        sections = report.segments.map { seg in
            let number = seg.index + 1
            let rows = seg.channels.map { Self.row($0, titles: titles, rules: rules) }
            let flagged = rows.filter { !$0.flags.isEmpty }.count
            return Section(
                id: seg.index,
                title: "Segment \(number) · \(seg.runId) · \(Self.num(seg.durationS)) s at \(Fmt.hertz(seg.sfreq))",
                summary: "Flags on \(flagged) of \(rows.count) channels in segment \(number)",
                rows: rows, spectra: seg.channels.map(Self.spectrum))
        }
        summary = sections.map(\.summary).joined(separator: "; ")
    }

    // MARK: Rows

    private static func row(_ c: InspectionReport.Channel, titles: [String: String], rules: [String: String]) -> ChannelRow {
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
                flags.append(Flag(ruleID: check.rule, title: title(check.rule), detail: detail(check, rule: rules[check.rule])))
            }
        }
        let notAssessed = skipped.map { "\($0.titles.joined(separator: ", ")) · \($0.reason)" }
        let assessedAny = c.checks.contains(where: \.assessable)
        let status: String? = flags.isEmpty ? (assessedAny ? noFlags : nothingAssessed) : nil
        let kindUnit = "\(kindName(c.kind)) · \(unitName(c.unit))"
        let spoken = ([status].compactMap { $0 } + flags.map(\.text) + notAssessed).joined(separator: ". ")
        return ChannelRow(id: c.id, label: c.label, kindUnit: kindUnit, flags: flags, notAssessed: notAssessed,
                          status: status, accessibilityLabel: "\(c.label), \(kindName(c.kind)) \(unitName(c.unit)). \(spoken).")
    }

    /// The measured value in plain words, with the worker's rule text where the threshold matters.
    private static func detail(_ check: InspectionReport.Check, rule: String?) -> String {
        let m = check.measured
        let because = rule.map { " (\($0))" } ?? ""
        switch check.rule {
        case "flatline":
            return "\(num(m?.flatS)) s of \(num(m?.totalS)) s flat\(because)"
        case "pinned":
            let runs = m?.runs ?? 0
            return "\(runs) \(runs == 1 ? "run" : "runs"), longest \(m?.longestRunSamples.map(String.init) ?? "—") samples\(because)"
        case "large_deflection":
            let pct = m?.fraction.map { "\(Fmt.fixed($0 * 100, 0)) %" } ?? "—"
            return "\(pct) of windows (\(m?.windowsOver.map(String.init) ?? "—") of \(m?.windows.map(String.init) ?? "—")) with \(rule ?? "large peak-to-peak")"
        case "mains_line":
            let fired = (m?.lines ?? []).filter(\.flagged).map { "\(Fmt.hertz($0.hz)) line \(num($0.db, 1)) dB over neighbours" }
            return fired.isEmpty ? "flagged" : fired.joined(separator: "; ")
        case "outlier_amplitude":
            return "variance \(ratio(m?.ratio)) the median channel"
        case "outlier_high_frequency":
            let band = m?.bandHz.flatMap { $0.count == 2 ? "\(num($0[0]))–\(num($0[1])) Hz" : nil } ?? "high-frequency"
            return "\(band) power \(ratio(m?.ratio)) the median channel"
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
            if let f, let v { out.append(Point(hz: f, db: v, run: run)) } else if out.last?.run == run { run += 1 }
        }
        return out
    }

    // MARK: Formatting

    /// Whole numbers without decimals ("42"), otherwise `digits` ("8.5"); "—" for null.
    static func num(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return v == v.rounded() && digits <= 1 ? Fmt.fixed(v, 0) : Fmt.fixed(v, digits)
    }

    static func ratio(_ v: Double?) -> String {
        guard let v else { return "—×" }
        return "\(Fmt.fixed(v, v < 1 ? 2 : 1))×"
    }

    static func kindName(_ kind: String) -> String {
        ["eeg", "emg", "eog", "ecg"].contains(kind.lowercased()) ? kind.uppercased() : kind
    }

    static func unitName(_ unit: String) -> String {
        if unit.trimmingCharacters(in: .whitespaces).isEmpty { return "unit not declared" }
        return ["uv", "µv", "μv", "microvolt", "microvolts"].contains(unit.lowercased()) ? "µV" : unit
    }
}
