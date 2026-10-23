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
        default: return code.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The result screen, every line built from the stored result (decision #8 wording).
struct ResultDetailModel {
    struct Headline: Equatable {
        /// "Balanced accuracy 0.68"
        let balancedAccuracy: String
        /// "Accuracy 0.70 · 95 % CI 0.51–0.84 (trial-level, n = 14)". The only interval on
        /// this line is the trial-level one, and it is labelled as accuracy's.
        let accuracy: String
        /// The run-level bootstrap interval for balanced accuracy, or why there is none.
        let balancedAccuracyInterval: String
    }

    struct Cell: Identifiable, Equatable {
        let row: Int
        let column: Int
        let count: Int
        let accessibilityLabel: String
        var id: Int { row * 2 + column }
        var isCorrect: Bool { row == column }
    }

    struct CountRow: Identifiable, Equatable {
        let className: String
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

    let report: EvaluationReport
    let meta: ResultMeta
    let classNames: [String]
    let referenceName: String
    let baselineName: String
    let headline: Headline
    let trialsLine: String
    let warning: String?
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
    let exclusions: [String]

    /// - Parameters:
    ///   - allResults: every result in the project, to name the original of a reproduction.
    ///   - modelName: display names for the worker's model keys (from `fit_evaluate_defaults`).
    init(stored: StoredResult, allResults: [ResultMeta] = [], modelName: (String) -> String = { $0 }) throws {
        let r = try EvaluationReport.decode(stored.evaluationJSON)
        report = r
        meta = stored.meta
        let config = stored.pipeline.configuration
        classNames = [config["label_left"] ?? "class 0", config["label_right"] ?? "class 1"]
        referenceName = modelName(r.comparison.reference)
        baselineName = modelName(r.comparison.baseline)
        guard let ref = r.models[r.comparison.reference], let base = r.models[r.comparison.baseline] else {
            throw ProjectStoreError.invalidManifest("evaluation.json lacks the models its comparison names")
        }
        let h = ref.holdout
        headline = Self.headline(h)
        trialsLine = "n = \(h.nTestTrials) held-out trials in \(h.nTestRuns) run\(h.nTestRuns == 1 ? "" : "s") · \(EvidenceText.short(r.splitPolicy.evidence))"
        warning = r.dataSource?.warning
        evidence = EvidenceText.describe(r.splitPolicy.evidence)

        let original = stored.meta.reproductionOf ?? stored.meta.divergedFrom
        reproduction = original.map { id in
            Reproduction(kind: stored.meta.reproductionOf != nil ? .identical : .differs, originalID: id,
                         originalCreatedAt: allResults.first { $0.resultID == id }?.createdAt)
        }

        let names = classNames
        var cells: [Cell] = []
        for (i, row) in h.confusionMatrix.enumerated() where i < 2 {
            for (j, count) in row.enumerated() where j < 2 {
                cells.append(Cell(row: i, column: j, count: count,
                                  accessibilityLabel: "True \(names[i]), predicted \(names[j]): \(count) trial\(count == 1 ? "" : "s")"))
            }
        }
        self.cells = cells
        let correct = cells.filter(\.isCorrect).map(\.count).reduce(0, +)
        let perClass = (0..<2).map { i -> String in
            let total = cells.filter { $0.row == i }.map(\.count).reduce(0, +)
            let right = cells.first { $0.row == i && $0.column == i }?.count ?? 0
            return "\(right) of \(total) \(names[i])"
        }
        confusionSummary = "Of \(h.nTestTrials) held-out trials, \(correct) were classified correctly: \(perClass.joined(separator: " and "))."

        classCounts = (0..<2).map { i in
            CountRow(className: names[i], train: r.classCounts.train[safe: i] ?? 0, holdout: r.classCounts.holdout[safe: i] ?? 0)
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
            .init(label: "Unit", value: sp.unit),
            .init(label: "Grouping", value: "by \(sp.grouping)"),
            .init(label: "Holdout", value: sp.holdout),
            .init(label: "Held-out runs", value: r.splitManifest.holdoutRuns.joined(separator: ", ")),
            .init(label: "Training runs", value: r.splitManifest.trainingRuns.joined(separator: ", ")),
            .init(label: "Folds", value: "\(r.splitManifest.folds.count) (\(sp.cv))"),
            .init(label: "Seed", value: "\(sp.seed)"),
            .init(label: "Evidence", value: sp.evidence),
        ]
        exclusions = r.exclusions.map { e in
            "Trial \(e.trialId) (\(e.runId), \(names[safe: e.label] ?? "class \(e.label)")): \(EvidenceText.exclusionReason(e.reason))"
        }
    }

    /// Decision #8. Never puts the trial-level interval on the balanced-accuracy line.
    static func headline(_ h: EvaluationReport.Holdout) -> Headline {
        let accCI = Fmt.interval(h.accuracyCi95) ?? "unavailable"
        let interval: String
        if let ci = h.balancedAccuracyRunBootstrapCi95.flatMap({ Fmt.interval($0) }), h.nTestRuns >= 2 {
            interval = "Balanced-accuracy interval \(ci) (run-level bootstrap, \(h.nTestRuns) held-out runs)"
        } else if h.nTestRuns == 1 {
            interval = "Balanced-accuracy interval: unavailable (one held-out run)"
        } else {
            interval = "Balanced-accuracy interval: unavailable"
        }
        return Headline(balancedAccuracy: "Balanced accuracy \(Fmt.fixed(h.balancedAccuracy))",
                        accuracy: "Accuracy \(Fmt.fixed(h.accuracy)) · 95 % CI \(accCI) (trial-level, n = \(h.nTestTrials))",
                        balancedAccuracyInterval: interval)
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
    let changes: [String]
    let misleading: [Bullet]
    let splitExplanation: [String]

    init(manifest m: RecordingManifest, events: [EventRecord], latest: EvaluationReport?,
         defaults: EvaluationDefaults?, recipes: [EvaluationDefaults.Recipe] = [], modelName: (String) -> String) {
        recordingTitle = RecordingDetailModel.title(for: m)
        let recipes = recipes.map(\.name)
        let what = recipes.isEmpty ? "the reference recipe and its baseline" : recipes.joined(separator: " and ")
        changes = [
            "Runs \(what) on the \(m.segments.count) run\(m.segments.count == 1 ? "" : "s") of this recording, in the analysis worker.",
            "The recording is not modified.",
            "The result is stored as a new record in this project; earlier results are kept.",
        ]

        var bullets: [Bullet] = []
        // Trials per class: cue events carry a trial id; rests do not.
        let trials = Dictionary(grouping: events.filter { $0.trialID != nil }, by: \.label).mapValues(\.count)
        if !trials.isEmpty {
            let parts = trials.sorted { $0.key < $1.key }.map { "\($0.value) “\($0.key)”" }
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
        switch m.source.kind {
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
