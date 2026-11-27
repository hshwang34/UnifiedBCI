import Foundation

/// The part of `evaluation.json` the result screen reads (worker/pipeline.py `fit_evaluate`,
/// plus `data_source` from project_io). Decoding only: the stored bytes are never rewritten.
struct EvaluationReport: Decodable, Equatable {
    struct SplitPolicy: Decodable, Equatable {
        var unit: String
        var grouping: String
        var holdout: String
        var holdoutFraction: Double?
        var cv: String
        var evidence: String
        var seed: Int
    }

    struct SplitManifest: Decodable, Equatable {
        struct Fold: Decodable, Equatable {
            var fold: Int
            var testRuns: [String]
        }
        var holdoutRuns: [String]
        var trainingRuns: [String]
        var folds: [Fold]
    }

    struct ClassCounts: Decodable, Equatable {
        var train: [Int]
        var holdout: [Int]
    }

    struct Exclusion: Decodable, Equatable {
        var trialId: String
        var runId: String
        var label: Int
        var reason: String
    }

    struct PerRun: Decodable, Equatable {
        var runId: String
        var nTrials: Int
        var balancedAccuracy: Double
        var accuracy: Double
    }

    struct Holdout: Decodable, Equatable {
        var balancedAccuracy: Double
        var accuracy: Double
        var confusionMatrix: [[Int]]
        var nTestTrials: Int
        var nTestRuns: Int
        var accuracyCi95: [Double]
        var perRun: [PerRun]
        /// Run-level bootstrap interval; null when fewer than two runs are held out.
        var balancedAccuracyRunBootstrapCi95: [Double]?
    }

    struct Model: Decodable, Equatable {
        var cvBalancedAccuracyPerFold: [Double]
        var cvBalancedAccuracyMean: Double
        var holdout: Holdout
    }

    struct Comparison: Decodable, Equatable {
        struct Paired: Decodable, Equatable {
            var referenceOnlyCorrect: Int
            var baselineOnlyCorrect: Int
            var bothCorrect: Int
            var neitherCorrect: Int
        }
        var reference: String
        var baseline: String
        var meanDifference: Double
        var differenceRunBootstrapCi95: [Double]?
        var pairedTrials: Paired
    }

    struct DataSource: Decodable, Equatable {
        var kind: String
        var warning: String?
        var dataset: String?
        var subject: String?
    }

    var splitPolicy: SplitPolicy
    var splitManifest: SplitManifest
    var classCounts: ClassCounts
    var exclusions: [Exclusion]
    var models: [String: Model]
    var comparison: Comparison
    var dataSource: DataSource?
    /// Things the worker reports beside the numbers (brief 005); absent on earlier records.
    var warnings: [Warning]?

    struct Warning: Decodable, Equatable {
        var kind: String
        var count: Int?
        var trialIds: [String]?
        var trialId: String?
        var line: Int?
    }

    static func decode(_ data: Data) throws -> EvaluationReport {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(EvaluationReport.self, from: data)
    }
}

/// Plain-language text for the worker's evidence and exclusion codes.
enum EvidenceText {
    static func describe(_ evidence: String) -> (symbol: String, text: String) {
        switch evidence {
        case "unknown-session":
            return ("questionmark.circle", "Session unknown — this is not evidence of cross-session transfer.")
        case "same-session":
            return ("person.crop.circle", "Same session — not evidence of transfer to another session.")
        case "cross-session":
            return ("arrow.left.arrow.right", "Cross-session — held-out runs come from a session the model was not trained on.")
        case "mixed-session":
            return ("circle.lefthalf.filled", "Mixed sessions — some held-out runs share a session with training runs.")
        default:
            return ("questionmark.circle", "Evidence: \(evidence)")
        }
    }

    /// One worker warning as a sentence (brief 005); nil for a kind this app doesn't know.
    static func warning(_ w: EvaluationReport.Warning) -> String? {
        switch w.kind {
        case "cue_by_nearest_timestamp":
            let n = w.count ?? w.trialIds?.count ?? 0
            let trials = (w.trialIds ?? []).prefix(6).joined(separator: ", ")
            let more = (w.trialIds?.count ?? 0) > 6 ? ", …" : ""
            return "\(n) cue\(n == 1 ? " was" : "s were") placed on the EEG by the nearest receipt timestamp, not a BrainFlow marker"
                + (trials.isEmpty ? "" : " (\(trials)\(more))") + ". That placement is software-only and less precise."
        case "events_last_line_truncated":
            return "The last line of the recording's event log was cut off (line \(w.line ?? 0)) and was ignored."
        case "abort_names_unknown_trial":
            return "An abort names trial \(w.trialId ?? "?"), which has no cue in this recording."
        default:
            return nil
        }
    }

    /// The evidence as a short phrase for running text; never the raw token.
    static func short(_ evidence: String) -> String {
        switch evidence {
        case "unknown-session": return "Session unknown"
        case "same-session": return "Same session"
        case "cross-session": return "Cross-session"
        case "mixed-session": return "Mixed sessions"
        default: return "Evidence: \(evidence)"
        }
    }

    static func exclusionReason(_ code: String) -> String {
        switch code {
        case "window_starts_before_filter_warmup": return "window starts before filter warm-up"
        case "window_starts_before_segment": return "window starts before the recording"
        case "window_exceeds_segment": return "window runs past the end of the recording"
        case "trial_aborted": return "trial was aborted"
        case "window_spans_detected_gap": return "window or its filter warm-up spans a detected gap"
        case "no_sample_for_cue": return "no EEG sample could be matched to its cue"
        default: return code.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The result screen, every line built from the stored result (decision #8 wording).
struct ResultDetailModel {
    struct Headline: Equatable {
        /// "Balanced accuracy 0.68" (VoiceOver and tests; the hero shows label and value apart).
        let balancedAccuracy: String
        /// "0.68", the hero's display number.
        let balancedAccuracyValue: String
        /// "Accuracy 0.70 · 95 % CI 0.51–0.84 (trial-level, n = 14)". The only interval on
        /// this line is the trial-level one, and it is labelled as accuracy's.
        let accuracy: String
        /// The run-level bootstrap interval for balanced accuracy, or why there is none.
        let balancedAccuracyInterval: String
        /// Decision #62, the hero's display text: "0.48–0.79" when balanced accuracy has a
        /// run-level interval; nil when it has none (the hero then leads with the trial-level one).
        var intervalHeadline: String? = nil
        /// "95 % interval, run-level bootstrap over 3 held-out runs".
        var intervalCaption: String = ""
        /// "Point estimate 0.62", always beside the interval or the bare number.
        var pointEstimate: String = ""
        /// "Point estimate · no interval" with its reason, when there is no run-level interval.
        var noIntervalTag: String? = nil
        var noIntervalReason: String? = nil
        /// The trial-level accuracy interval as display text ("0.32–0.84") and its caption.
        var accuracyIntervalText: String? = nil
        var accuracyCaption: String = ""
        var accuracyPoint: String = ""
    }

    struct Cell: Identifiable, Equatable {
        let row: Int
        let column: Int
        let count: Int
        /// Trials whose true class is this row's: the cell reads "count of rowTotal".
        let rowTotal: Int
        let accessibilityLabel: String
        /// Share of the row, for the diagonal's shading.
        var rowShare: Double { rowTotal > 0 ? Double(count) / Double(rowTotal) : 0 }
        var id: Int { row * 2 + column }
        var isCorrect: Bool { row == column }
    }

    struct CountRow: Identifiable, Equatable {
        let className: String
        let displayName: String
        let train: Int
        let holdout: Int
        var id: String { className }
    }

    struct RunRow: Identifiable, Equatable {
        let runID: String
        let trials: Int
        let reference: String
        let baseline: String
        var id: String { runID }
    }

    struct Reproduction: Equatable {
        enum Kind: Equatable { case identical, differs }
        let kind: Kind
        let originalID: UUID
        let originalCreatedAt: Date?
    }

    /// The accuracy bar's reference: the larger class's share of the held-out trials,
    /// from stored counts only (decision #12).
    struct LargerClass: Equatable {
        let rate: Double
        let sentence: String
        let symbol: String
        /// "Always guessing the larger class scores 0.53 here.", in readable words beside the bar.
        var detail: String { "Always guessing the larger class scores \(Fmt.fixed(rate)) on these trials." }
    }

    let report: EvaluationReport
    let meta: ResultMeta
    /// Stored class labels (`label_left`, `label_right`), never replaced.
    let classNames: [String]
    /// "Left-fist cue" / "Right-fist cue" (decision #11), shown with the stored label.
    let classDisplayNames: [String]
    let accuracyValue: Double
    let accuracyInterval: ClosedRange<Double>?
    let balancedAccuracy: Double
    /// Run-level bootstrap interval for balanced accuracy; nil with fewer than two held-out runs.
    let balancedAccuracyInterval: ClosedRange<Double>?
    let balancedAccuracyBarLabel: String?
    let largerClass: LargerClass?
    let heroAccessibilityLabel: String
    let referenceBalancedAccuracy: Double
    let baselineBalancedAccuracy: Double
    let paired: EvaluationReport.Comparison.Paired
    let differenceUnavailable: Bool
    let referenceName: String
    let baselineName: String
    let headline: Headline
    let trialsLine: String
    let warning: String?
    /// The worker's warnings in words: fallback cue placement, a cut-off event log.
    let notes: [String]
    let evidence: (symbol: String, text: String)
    let reproduction: Reproduction?
    let cells: [Cell]
    let confusionSummary: String
    let classCounts: [CountRow]
    let perRun: [RunRow]
    let baselineLine: String
    let differenceLine: String
    let differenceInterval: String
    let pairedLine: String
    let cvLine: String
    let splitFields: [RecordingDetailModel.Field]
    /// Stored identifiers shown under Details (monospace).
    let detailFields: [RecordingDetailModel.Field]
    let exclusions: [String]

    /// - Parameters:
    ///   - allResults: every result in the project, to name the original of a reproduction.
    ///   - modelName: display names for the worker's model keys (from `fit_evaluate_defaults`).
    /// `isDemo`: the recording came from the Demo source, whose stored warning is not shown
    /// on screen (decision #42).
    /// `className`: a stored class label's name for primary text (protocol display name, else
    /// `ClassDisplay.name`).
    init(stored: StoredResult, allResults: [ResultMeta] = [], modelName: (String) -> String = { $0 }, isDemo: Bool = false,
         className: (String) -> String = ClassDisplay.name) throws {
        let r = try EvaluationReport.decode(stored.evaluationJSON)
        report = r
        meta = stored.meta
        let config = stored.pipeline.configuration
        classNames = [config["label_left"] ?? "class 0", config["label_right"] ?? "class 1"]
        classDisplayNames = classNames.map(className)
        referenceName = modelName(r.comparison.reference)
        baselineName = modelName(r.comparison.baseline)
        guard let ref = r.models[r.comparison.reference], let base = r.models[r.comparison.baseline] else {
            throw ProjectStoreError.invalidManifest("evaluation.json lacks the models its comparison names")
        }
        let h = ref.holdout
        headline = Self.headline(h)
        accuracyValue = h.accuracy
        accuracyInterval = Self.range(h.accuracyCi95)
        balancedAccuracy = h.balancedAccuracy
        balancedAccuracyInterval = h.nTestRuns >= 2 ? h.balancedAccuracyRunBootstrapCi95.flatMap(Self.range) : nil
        balancedAccuracyBarLabel = balancedAccuracyInterval == nil ? nil : "Run-level bootstrap, \(h.nTestRuns) held-out runs"
        largerClass = Self.largerClass(holdoutCounts: r.classCounts.holdout, interval: accuracyInterval)
        referenceBalancedAccuracy = h.balancedAccuracy
        baselineBalancedAccuracy = base.holdout.balancedAccuracy
        paired = r.comparison.pairedTrials
        differenceUnavailable = r.comparison.differenceRunBootstrapCi95 == nil
        let ci = accuracyInterval.map { "95 percent confidence interval \(Fmt.fixed($0.lowerBound)) to \(Fmt.fixed($0.upperBound))" } ?? "no confidence interval"
        heroAccessibilityLabel = "Balanced accuracy \(Fmt.fixed(h.balancedAccuracy)). Accuracy \(Fmt.fixed(h.accuracy)), \(ci), trial-level, \(h.nTestTrials) trials. \(headline.balancedAccuracyInterval)"
        trialsLine = "n = \(h.nTestTrials) held-out trials in \(h.nTestRuns) run\(h.nTestRuns == 1 ? "" : "s") · \(EvidenceText.short(r.splitPolicy.evidence))"
        warning = isDemo ? nil : r.dataSource?.warning
        notes = (r.warnings ?? []).compactMap(EvidenceText.warning)
        evidence = EvidenceText.describe(r.splitPolicy.evidence)

        let original = stored.meta.reproductionOf ?? stored.meta.divergedFrom
        reproduction = original.map { id in
            Reproduction(kind: stored.meta.reproductionOf != nil ? .identical : .differs, originalID: id,
                         originalCreatedAt: allResults.first { $0.resultID == id }?.createdAt)
        }

        let raw = classNames
        // Running text and VoiceOver keep the stored label beside the name.
        let names = raw.map { r in className(r) == r ? r : "\(className(r)) (\(r))" }
        var cells: [Cell] = []
        for (i, row) in h.confusionMatrix.enumerated() where i < 2 {
            let total = row.prefix(2).reduce(0, +)
            for (j, count) in row.enumerated() where j < 2 {
                cells.append(Cell(row: i, column: j, count: count, rowTotal: total,
                                  accessibilityLabel: "True \(names[i]), predicted \(names[j]): \(count) of \(total) trial\(total == 1 ? "" : "s")\(i == j ? ", correct" : ", wrong")"))
            }
        }
        self.cells = cells
        let correct = cells.filter(\.isCorrect).map(\.count).reduce(0, +)
        let perClass = (0..<2).map { i -> String in
            let total = cells.filter { $0.row == i }.map(\.count).reduce(0, +)
            let right = cells.first { $0.row == i && $0.column == i }?.count ?? 0
            return "\(right) of \(total) \(className(raw[i]))"
        }
        confusionSummary = "Of \(h.nTestTrials) held-out trials, \(correct) were classified correctly: \(perClass.joined(separator: " and "))."

        classCounts = (0..<2).map { i in
            CountRow(className: raw[i], displayName: className(raw[i]), train: r.classCounts.train[safe: i] ?? 0, holdout: r.classCounts.holdout[safe: i] ?? 0)
        }
        let baseRuns = Dictionary(base.holdout.perRun.map { ($0.runId, $0) }, uniquingKeysWith: { a, _ in a })
        perRun = h.perRun.map { run in
            RunRow(runID: run.runId, trials: run.nTrials, reference: Fmt.fixed(run.balancedAccuracy),
                   baseline: baseRuns[run.runId].map { Fmt.fixed($0.balancedAccuracy) } ?? "—")
        }

        baselineLine = "\(baselineName): balanced accuracy \(Fmt.fixed(base.holdout.balancedAccuracy))"
        differenceLine = "Difference (\(referenceName) − baseline): \(Fmt.signed(r.comparison.meanDifference)) balanced accuracy, paired by run"
        if let ci = r.comparison.differenceRunBootstrapCi95.flatMap({ Fmt.interval($0) }) {
            differenceInterval = "Difference interval \(ci) (run-level bootstrap)"
        } else {
            differenceInterval = h.nTestRuns == 1 ? "Difference interval: unavailable (one held-out run)" : "Difference interval: unavailable"
        }
        let p = r.comparison.pairedTrials
        pairedLine = "Both correct \(p.bothCorrect) · reference only \(p.referenceOnlyCorrect) · baseline only \(p.baselineOnlyCorrect) · neither \(p.neitherCorrect)"
        cvLine = "Cross-validation on training runs, balanced accuracy mean: \(referenceName) \(Fmt.fixed(ref.cvBalancedAccuracyMean)), \(baselineName) \(Fmt.fixed(base.cvBalancedAccuracyMean))"

        let sp = r.splitPolicy
        splitFields = [
            .init(label: "Held-out runs", value: r.splitManifest.holdoutRuns.joined(separator: ", ")),
            .init(label: "Training runs", value: r.splitManifest.trainingRuns.joined(separator: ", ")),
            .init(label: "Cross-validation", value: "\(r.splitManifest.folds.count) fold\(r.splitManifest.folds.count == 1 ? "" : "s"), whole runs"),
            .init(label: "Seed", value: "\(sp.seed)"),
        ]
        // Decision #63: the exact stored values, for Details.
        detailFields = [
            .init(label: "Unit", value: sp.unit, mono: true),
            .init(label: "Grouping", value: sp.grouping, mono: true),
            .init(label: "Holdout", value: sp.holdout, mono: true),
            .init(label: "CV", value: sp.cv, mono: true),
            .init(label: "Evidence", value: sp.evidence, mono: true),
            .init(label: "Recipe", value: stored.pipeline.recipe, mono: true),
            .init(label: "Baseline", value: r.comparison.baseline, mono: true),
        ] + raw.enumerated().map { .init(label: "Class \($0.offset + 1) label", value: $0.element, mono: true) }
            + [.init(label: "Result ID", value: stored.meta.resultID.uuidString, mono: true)]
        exclusions = r.exclusions.map { e in
            "Trial \(e.trialId) (\(e.runId), \(names[safe: e.label] ?? "class \(e.label)")): \(EvidenceText.exclusionReason(e.reason))"
        }
    }

    /// Decision #8. Never puts the trial-level interval on the balanced-accuracy line.
    static func headline(_ h: EvaluationReport.Holdout) -> Headline {
        let accCI = Fmt.interval(h.accuracyCi95) ?? "unavailable"
        let value = Fmt.fixed(h.balancedAccuracy)
        let interval: String
        if let ci = h.balancedAccuracyRunBootstrapCi95.flatMap({ Fmt.interval($0) }), h.nTestRuns >= 2 {
            interval = "Balanced-accuracy interval \(ci) (run-level bootstrap, \(h.nTestRuns) held-out runs)"
        } else if h.nTestRuns == 1 {
            interval = "Balanced-accuracy interval: unavailable (one held-out run)"
        } else {
            interval = "Balanced-accuracy interval: unavailable"
        }
        let runCI = h.nTestRuns >= 2 ? h.balancedAccuracyRunBootstrapCi95.flatMap { Fmt.interval($0) } : nil
        return Headline(balancedAccuracy: "Balanced accuracy \(value)", balancedAccuracyValue: value,
                        accuracy: "Accuracy \(Fmt.fixed(h.accuracy)) · 95 % CI \(accCI) (trial-level, n = \(h.nTestTrials))",
                        balancedAccuracyInterval: interval,
                        intervalHeadline: runCI,
                        intervalCaption: runCI == nil ? "" : "95 % interval · run-level bootstrap over \(h.nTestRuns) held-out runs",
                        pointEstimate: "Point estimate \(value)",
                        noIntervalTag: runCI == nil ? "Point estimate · no interval" : nil,
                        noIntervalReason: runCI != nil ? nil : h.nTestRuns == 1
                            ? "Only one run was held out, so balanced accuracy has no run-level interval. Read the trial-level accuracy interval below for the uncertainty."
                            : "Balanced accuracy has no run-level interval for this result. Read the trial-level accuracy interval below for the uncertainty.",
                        accuracyIntervalText: Fmt.interval(h.accuracyCi95),
                        accuracyCaption: "Accuracy · 95 % interval, trial-level, n = \(h.nTestTrials)",
                        accuracyPoint: "Point estimate \(Fmt.fixed(h.accuracy))")
    }
}

/// The results list: originals at the top level (oldest first); reruns with the same
/// recording, configuration and seed as children of their original (`OutlineGroup`).
struct ResultNode: Identifiable, Equatable {
    let meta: ResultMeta
    var children: [ResultNode]?
    var id: UUID { meta.resultID }

    var isReproduction: Bool { meta.reproductionOf != nil }
    var diverged: Bool { meta.divergedFrom != nil }

    static func tree(_ metas: [ResultMeta]) -> [ResultNode] {
        let sorted = metas.sorted { ($0.createdAt, $0.resultID.uuidString) < ($1.createdAt, $1.resultID.uuidString) }
        let ids = Set(sorted.map(\.resultID))
        func parent(_ m: ResultMeta) -> UUID? {
            guard let p = m.reproductionOf ?? m.divergedFrom, ids.contains(p) else { return nil }
            return p
        }
        let kids = Dictionary(grouping: sorted.filter { parent($0) != nil }, by: { parent($0)! })
        return sorted.filter { parent($0) == nil }.map { root in
            let children = (kids[root.resultID] ?? []).map { ResultNode(meta: $0, children: nil) }
            return ResultNode(meta: root, children: children.isEmpty ? nil : children)
        }
    }
}

/// The Evaluate inspector: what the action changes and what would make its number
/// misleading, every bullet derived from the recording (and from the latest result for
/// it, when there is one). No number in this text is a constant.
struct EvaluateInspectorModel {
    struct Bullet: Identifiable, Equatable {
        let symbol: String
        let text: String
        var id: String { text }
    }

    let recordingTitle: String
    /// Whether the recording has enough runs (brief 005), as a sentence.
    let runs: String
    let hasEnoughRuns: Bool
    /// A protocol recording's classes; nil for any other recording.
    let classes: String?
    let changes: [String]
    let misleading: [Bullet]
    let splitExplanation: [String]

    init(manifest m: RecordingManifest, events: [EventRecord], latest: EvaluationReport?,
         defaults: EvaluationDefaults?, recipes: [EvaluationDefaults.Recipe] = [], modelName: (String) -> String,
         protocol p: ProtocolRecord? = nil, windowEndMs: Int? = nil, pageShowsSourceWarning: Bool = false) {
        let className: (String) -> String = { raw in
            p?.classes.first { $0.label == raw && !$0.displayName.isEmpty }?.displayName ?? ClassDisplay.name(raw)
        }
        recordingTitle = RecordingDetailModel.title(for: m)
        let runCount = RunCountModel.runs(m)
        let usable = RunCountModel.evaluableRuns(events)
        runs = RunCountModel.message(runs: usable)
        hasEnoughRuns = usable >= RunCountModel.minimumRuns
        classes = p.map(RunCountModel.labels)
        let recipes = recipes.map(\.name)
        let what = recipes.isEmpty ? "the reference recipe and its baseline" : recipes.joined(separator: " and ")
        changes = [
            "Runs \(what) on the \(runCount) run\(runCount == 1 ? "" : "s") of this recording, in the analysis worker.",
            "The recording is not modified.",
            "The result is stored as a new record in this project; earlier results are kept.",
        ]

        var bullets: [Bullet] = []
        // The protocol's cue must hold the evaluation window (brief 005 validation).
        if let p, let windowEndMs, let warning = ProtocolCopy.windowWarning(cueMs: p.timing.cueMs, windowEndMs: windowEndMs) {
            bullets.append(Bullet(symbol: "exclamationmark.triangle", text: warning))
        }
        // Trials per class: cue events carry a trial id; rests do not.
        let trials = Dictionary(grouping: events.filter { $0.trialID != nil }, by: \.label).mapValues(\.count)
        if !trials.isEmpty {
            let parts = trials.sorted { $0.key < $1.key }.map { "\($0.value) \(className($0.key))" }
            bullets.append(Bullet(symbol: "number",
                                  text: "\(parts.joined(separator: " and ")) trials. Small samples give wide intervals; an accuracy that looks good can still be compatible with chance."))
        }
        let sessions = Set(m.segments.map(\.sessionID))
        if sessions.contains(nil) {
            bullets.append(Bullet(symbol: "questionmark.circle",
                                  text: "No session is recorded for \(m.segments.filter { $0.sessionID == nil }.count == m.segments.count ? "any run" : "some runs"), so the result is not evidence of cross-session transfer."))
        } else if sessions.count == 1 {
            bullets.append(Bullet(symbol: "person.crop.circle", text: "Every run is from one session; the result is not evidence of transfer to another session."))
        }
        if let subject = m.source.subject {
            bullets.append(Bullet(symbol: "person", text: "One subject (\(subject)): no claim about anyone else."))
        }
        // Decision #66: the page's warning chip already says it; the inspector doesn't repeat it.
        switch pageShowsSourceWarning ? "" : m.source.kind {
        case "public_dataset":
            bullets.append(Bullet(symbol: "exclamationmark.triangle", text: "Public recording, not recorded on your device; your hardware may behave differently."))
        case "synthetic":
            bullets.append(Bullet(symbol: "exclamationmark.triangle", text: "Synthetic data exercises the pipeline only; it is not evidence about any participant."))
        default: break
        }
        if let latest {
            if !latest.exclusions.isEmpty {
                let reasons = Set(latest.exclusions.map { EvidenceText.exclusionReason($0.reason) }).sorted().joined(separator: "; ")
                bullets.append(Bullet(symbol: "minus.circle",
                                      text: "The last evaluation excluded \(latest.exclusions.count) trial\(latest.exclusions.count == 1 ? "" : "s") (\(reasons))."))
            }
            let held = latest.splitManifest.holdoutRuns.count
            if held == 1 {
                bullets.append(Bullet(symbol: "chart.bar.xaxis",
                                      text: "One run is held out, so balanced accuracy has no run-level interval; only the trial-level accuracy interval exists."))
            }
        }
        misleading = bullets

        if let sp = latest?.splitPolicy, let sm = latest?.splitManifest {
            splitExplanation = [
                "Unit: \(sp.unit); trials are grouped by \(sp.grouping), so no run is split between training and testing.",
                "Holdout: \(sp.holdout). Last time: \(sm.holdoutRuns.joined(separator: ", ")) held out.",
                "Cross-validation: \(sp.cv), \(sm.folds.count) fold\(sm.folds.count == 1 ? "" : "s") over \(sm.trainingRuns.joined(separator: ", ")).",
                "Every step, including CSP, is fitted inside the training fold only.",
                "The seed picks the held-out runs; rerunning with the same seed reproduces the split.",
            ]
        } else if let d = defaults {
            splitExplanation = [
                "Trials are grouped by run: no run is split between training and testing.",
                "A fraction \(Fmt.fixed(d.params.holdout_fraction)) of the runs is held out, chosen with the seed and frozen before anything is fitted.",
                "Cross-validation folds are whole training runs; every step, including CSP, is fitted inside the training fold only.",
            ]
        } else {
            splitExplanation = [
                "Trials are grouped by run: no run is split between training and testing.",
                "The held-out runs are chosen with the seed and frozen before anything is fitted.",
            ]
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension ResultDetailModel {
    static func range(_ ci: [Double]) -> ClosedRange<Double>? {
        guard ci.count == 2, ci[0] <= ci[1] else { return nil }
        return ci[0]...ci[1]
    }

    /// Decision #12: is the accuracy interval around, above or below the larger class's
    /// share of the held-out trials (what always guessing that class would score)?
    static func largerClass(holdoutCounts: [Int], interval: ClosedRange<Double>?) -> LargerClass? {
        let total = holdoutCounts.reduce(0, +)
        guard total > 0, let biggest = holdoutCounts.max(), let interval else { return nil }
        let rate = Double(biggest) / Double(total)
        if interval.contains(rate) {
            return LargerClass(rate: rate, sentence: "Interval includes the larger-class rate.", symbol: "info.circle")
        }
        return interval.lowerBound > rate
            ? LargerClass(rate: rate, sentence: "Interval lies entirely above the larger-class rate.", symbol: "arrow.up.circle")
            : LargerClass(rate: rate, sentence: "Interval lies entirely below the larger-class rate.", symbol: "arrow.down.circle")
    }
}

/// Copy for the export notice (brief 005 PR 7). Run plans the export left out are named, so
/// a user never takes a partial export for a complete one.
enum ExportNoticeText {
    static func exported(_ url: URL, leftOut: String?, added: String? = nil) -> String {
        (["Exported to \((url.path as NSString).abbreviatingWithTildeInPath)."] + [added, leftOut].compactMap { $0 }).joined(separator: " ")
    }

    /// What the export carries beyond the chosen result and its recording (brief 006), so a
    /// reader isn't surprised by a model or live run from elsewhere; nil when nothing.
    static func added(_ s: ExportSummary) -> String? {
        let m = s.modelsFromOtherResults, r = s.liveRunsOnOtherRecordings
        var parts: [String] = []
        if m > 0 { parts.append(m == 1 ? "1 model frozen from another result" : "\(m) models frozen from other results") }
        if r > 0 { parts.append(r == 1 ? "1 live run on another recording" : "\(r) live runs on other recordings") }
        return parts.isEmpty ? nil : "Also includes " + parts.joined(separator: " and ") + "."
    }

    /// Nil when nothing was left out.
    static func leftOut(_ s: ExportSummary) -> String? {
        var parts: [String] = []
        let n = s.unverifiedRunPlans.count
        if n > 0 {
            parts.append(n == 1 ? "1 run plan was left out because its protocol couldn't be verified."
                                : "\(n) run plans were left out because their protocol couldn't be verified.")
        }
        let m = s.unreadableRunPlans
        if m > 0 {
            parts.append(m == 1 ? "1 run plan file couldn't be read and was left out."
                                : "\(m) run plan files couldn't be read and were left out.")
        }
        func count(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append(n == 1 ? one : "\(n) " + many) } }
        count(s.unverifiedModels, "1 frozen model was left out because its model file is missing or changed since it was frozen.",
              "frozen models were left out because their model files are missing or changed since they were frozen.")
        count(s.unreadableModels, "1 frozen model folder couldn't be read and was left out.",
              "frozen model folders couldn't be read and were left out.")
        count(s.unverifiedLiveRuns, "1 live run was left out because its model couldn't be exported.",
              "live runs were left out because their models couldn't be exported.")
        count(s.unreadableLiveRuns, "1 live run folder couldn't be read and was left out.",
              "live run folders couldn't be read and were left out.")
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
