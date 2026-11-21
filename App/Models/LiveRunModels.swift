import Foundation

// Brief 006 PR 8: Live Test setup and the live-run card (fresh-session evidence). Every
// string is built here (Fmt, locale-independent). Nothing calls a live run "working" or
// "successful"; a chance-level run reads exactly like a good one.

enum LiveRunCopy {
    static let setupTitle = "New live run"
    static let setupIntro = "Runs a cued protocol on the connected source and shows the participant a bar with the model's confidence during each cue. The run is recorded, and afterwards replayed through the same model as a check."
    static let modelLabel = "Frozen model"
    static let thresholdLabel = "Abstention threshold"
    static let thresholdHelp = "Model confidence below this hides the bar and shows \"Not confident\". Stored with the live run (default 0.60)."
    static let start = "Start Live Run"
    static let starting = "Starting the analysis worker…"
    static let noModels = "Freeze a result for live use first (Results → Freeze for live use…)."
    static let noSource = "Connect a source first: File → New Recording…, or the Demo."
    static let runsListTitle = "Live runs"
    static let newRunRow = "New live run"
    static let pausedDuringLive = "Paused during a live run"
    static let noRunsChecked = "No run was started, so there is nothing to replay."
    static let cardTitle = "Live run"
    static let scoringNote = "Scored like the offline result: every valid trial counts with the class its cue-locked window favours. Abstention only hides the bar; abstained trials are counted here and listed."
    static let latencyTarget = "Initial target: p95 under 100 ms after the window is available."
    static let latencyCaveat = "Software only: radio or USB transport and display delay are not measured."
    static let notLive = "Live feedback runs only on a connected source."
    static let showSource = "Show the Offline Result"
    static let matrixTitle = "Confusion matrix (live trials)"
    static let checking = "Run finished. Replaying the recording through the model to check the live predictions…"
    static let stopping = "Stopping the analysis worker…"
    static let liveRunsUnderResult = "Live runs of models frozen from this result"

    static func modelSummary(_ m: ModelRecord) -> String {
        "\(m.expectedChannelIDs.count) channels at \(Fmt.hertz(m.expectedSampleRateHz)) · window \(Fmt.seconds(m.window.offsetSeconds))–\(Fmt.seconds(m.window.offsetSeconds + m.window.lengthSeconds)) after the cue · "
            + "\(m.classLabels.map(ClassDisplay.name).joined(separator: " vs "))"
    }

    static func runTitle(_ r: LiveRunRecord) -> String {
        "Live run · \(r.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Why the protocol can't be scored against the model: its classes must be the model's.
    static func classMismatch(model m: ModelRecord, protocolRecord p: ProtocolRecord) -> String? {
        let labels = Set(p.classes.map(\.label))
        guard labels != Set(m.classLabels) else { return nil }
        return "This protocol cues \(p.classes.map { "“\($0.label)”" }.joined(separator: " and ")), but the model was trained on "
            + "\(m.classLabels.map { "“\($0)”" }.joined(separator: " and ")). Pick a protocol with the model's classes."
    }

    /// Why the model can't run on the connected stream (never reordered or resampled), or nil.
    static func mismatch(model m: ModelRecord, channelIDs: [String], rateHz: Double) -> String? {
        if abs(m.expectedSampleRateHz - rateHz) > 1e-9 {
            return "The model expects \(Fmt.hertz(m.expectedSampleRateHz)) and the source streams \(Fmt.hertz(rateHz)). Nothing is resampled: evaluate a recording from this source and freeze that."
        }
        if m.expectedChannelIDs != channelIDs {
            let missing = m.expectedChannelIDs.filter { !channelIDs.contains($0) }
            let detail = missing.isEmpty ? "the same channels in another order" : "missing \(missing.prefix(4).joined(separator: ", "))\(missing.count > 4 ? "…" : "")"
            return "The model's channels don't match the source's channel map (\(detail)). Nothing is reordered."
        }
        return nil
    }
}

/// The Live Test setup form (decision #39: the threshold is editable and stored per run).
struct LiveTestForm: Equatable {
    var modelID: UUID?
    var thresholdText = Fmt.fixed(FeedbackPolicy.defaultThreshold)

    var threshold: Double? { Double(thresholdText.trimmingCharacters(in: .whitespaces)) }

    /// The policy to run with, or why not.
    var policy: Result<FeedbackPolicy, LiveFormProblem> {
        guard let t = threshold, ModelErrorText.thresholdProblem(t) == nil else {
            return .failure(.init(text: ModelErrorText.thresholdProblem(threshold ?? .nan) ?? ""))
        }
        do { return .success(try FeedbackPolicy(threshold: t)) } catch { return .failure(.init(text: "\(error)")) }
    }
}

struct LiveFormProblem: Error, Equatable { let text: String }

/// What a live-run card needs beyond `run.json`, read off the main thread.
struct LiveRunInputs: Sendable, Equatable {
    /// The run's cue-locked windows (one per trial that reached the worker).
    var cueLocked: [PredictionRecord]
    /// Each cued trial's class, from the recording's events; aborted trials apart.
    var truth: [String: String]
    var aborted: Set<String>
    /// Session ids of the recording's segments.
    var sessions: [String?]
    /// The source result's held-out figures, when readable.
    var offline: Offline?

    struct Offline: Sendable, Equatable {
        var balancedAccuracy: Double
        var accuracy: Double
        var interval: ClosedRange<Double>?
        var trials: Int
        var createdAt: Date
    }
}

/// The live run as fresh-session evidence (brief 006, decision #41).
struct LiveRunCardModel {
    struct Row: Identifiable, Equatable { let label: String; let value: String; var id: String { label } }

    let title: String
    let evidence: String
    let evidenceSentence: String
    let balancedAccuracy: Double?
    let balancedAccuracyValue: String
    let accuracy: Double?
    let accuracyLine: String
    let interval: ClosedRange<Double>?
    let largerClass: ResultDetailModel.LargerClass?
    let trialsLine: String
    let cells: [ResultDetailModel.Cell]
    let classNames: [String]
    let comparison: String
    let excluded: [String]
    let latency: [Row]
    let replayLine: String
    let replayOK: Bool?
    let accessibilityLabel: String

    init(run: LiveRunRecord, model: ModelRecord?, inputs: LiveRunInputs, name: (String) -> String) {
        title = LiveRunCopy.runTitle(run)
        // Fresh-session evidence, from stored session ids only.
        let training = model?.trainingSessionIDs ?? [nil]
        if training.contains(where: { $0 == nil }) || inputs.sessions.isEmpty || inputs.sessions.contains(where: { $0 == nil }) {
            (evidence, evidenceSentence) = ("unknown-session", "A session id is missing, so whether this run is a new session can't be told.")
        } else if Set(training.compactMap { $0 }).isDisjoint(with: Set(inputs.sessions.compactMap { $0 })) {
            (evidence, evidenceSentence) = ("cross-session", "Recorded in a session the model never trained on.")
        } else {
            (evidence, evidenceSentence) = ("same-session", "Recorded in a session the model trained on, so this is not fresh-session evidence.")
        }
        let labels = model?.classLabels ?? Array(Set(inputs.truth.values)).sorted()
        classNames = labels.map(name)
        let windows = Dictionary(inputs.cueLocked.compactMap { p in p.trialID.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        var matrix = [[0, 0], [0, 0]]
        var abstained = 0
        var invalid: [String: Int] = [:]
        for (trial, truth) in inputs.truth where !inputs.aborted.contains(trial) {
            guard let row = labels.firstIndex(of: truth), row < 2 else { continue }
            guard let p = windows[trial], p.validity == .valid, let s = p.score, s.isFinite else {
                let why = windows[trial].map { FeedbackPolicy.words($0.validity) + ($0.validityDetail.map { " (\(EvidenceText.exclusionReason($0)))" } ?? "") }
                    ?? "no window was logged"
                invalid[why, default: 0] += 1
                continue
            }
            matrix[row][s > 0 ? 1 : 0] += 1
            if p.action.kind == .abstain { abstained += 1 }
        }
        let n = matrix.joined().reduce(0, +)
        let correct = matrix[0][0] + matrix[1][1]
        let recalls = (0..<2).compactMap { i -> Double? in
            let t = matrix[i][0] + matrix[i][1]
            return t > 0 ? Double(matrix[i][i]) / Double(t) : nil
        }
        balancedAccuracy = recalls.count == 2 ? recalls.reduce(0, +) / 2 : nil
        balancedAccuracyValue = balancedAccuracy.map { Fmt.fixed($0) } ?? "–"
        accuracy = n > 0 ? Double(correct) / Double(n) : nil
        interval = n > 0 ? ClopperPearson.interval(successes: correct, trials: n) : nil
        if let interval {
            accuracyLine = "Accuracy \(Fmt.fixed(Double(correct) / Double(n))) · 95 % CI \(Fmt.fixed(interval.lowerBound))–\(Fmt.fixed(interval.upperBound)) (trial-level, n = \(n))"
        } else {
            accuracyLine = "No valid trials, so no accuracy."
        }
        largerClass = ResultDetailModel.largerClass(holdoutCounts: matrix.map { $0[0] + $0[1] }, interval: interval)
        var cells: [ResultDetailModel.Cell] = []
        for i in 0..<2 {
            let total = matrix[i][0] + matrix[i][1]
            for j in 0..<2 {
                let names = classNames.count == 2 ? classNames : ["class 0", "class 1"]
                cells.append(.init(row: i, column: j, count: matrix[i][j], rowTotal: total,
                                   accessibilityLabel: "True \(names[i]), predicted \(names[j]): \(matrix[i][j]) of \(total)\(i == j ? ", correct" : ", wrong")"))
            }
        }
        self.cells = cells
        let runs = run.runIDs.count
        trialsLine = "n = \(n) valid trial\(n == 1 ? "" : "s") in \(runs) run\(runs == 1 ? "" : "s") · \(abstained) below the \(Fmt.fixed(run.abstainThreshold)) threshold"
        excluded = invalid.sorted { $0.key < $1.key }.map { "\($0.value) trial\($0.value == 1 ? "" : "s"): \($0.key)" }
            + (inputs.aborted.isEmpty ? [] : ["\(inputs.aborted.count) aborted trial\(inputs.aborted.count == 1 ? "" : "s") not counted"])
        if let o = inputs.offline {
            let ci = o.interval.map { ", 95 % CI \(Fmt.fixed($0.lowerBound))–\(Fmt.fixed($0.upperBound))" } ?? ""
            comparison = "The frozen model's held-out result: balanced accuracy \(Fmt.fixed(o.balancedAccuracy)) (accuracy \(Fmt.fixed(o.accuracy))\(ci), n = \(o.trials))."
        } else {
            comparison = "The frozen model's held-out result couldn't be read."
        }
        var rows: [Row] = []
        func add(_ label: String, _ p: LiveRunRecord.Percentiles?) {
            rows.append(.init(label: label, value: p.map { "p50 \(LiveFeedbackPanelModel.ms($0.p50)) · p95 \(LiveFeedbackPanelModel.ms($0.p95)) · max \(LiveFeedbackPanelModel.ms($0.max)) (n = \($0.count))" } ?? "not measured"))
        }
        add("Receipt → prediction", run.latency?.receiptToEmission)
        add("BrainFlow buffer wait", run.latency?.bufferWait)
        add("Prediction → display callback", run.latency?.emissionToPresentation)
        if let model { rows.append(.init(label: "Window length", value: "\(Fmt.seconds(model.window.lengthSeconds)) (the signal every prediction waits for)")) }
        latency = rows
        if let c = run.replayCheck {
            if c.windowsCompared > 0, c.windowsMatched == c.windowsCompared {
                (replayLine, replayOK) = ("Live matched replay: \(c.windowsMatched) of \(c.windowsCompared) windows within tolerance.", true)
            } else {
                let list = c.differingSequences.prefix(8).map(String.init).joined(separator: ", ")
                let more = c.differingSequences.count > 8 ? "…" : ""
                replayLine = "Live and replay differ in \(c.windowsCompared - c.windowsMatched) of \(c.windowsCompared) windows (predictions \(list)\(more)). That is a bug to report, not a result."
                replayOK = false
            }
        } else {
            (replayLine, replayOK) = (run.endedAt == nil ? "The run ended with the app; it was not replayed." : "The live-vs-replay check didn't run.", nil)
        }
        accessibilityLabel = "\(title). Balanced accuracy \(balancedAccuracyValue). \(accuracyLine). \(evidence). \(trialsLine)."
    }
}

/// The exact (Clopper-Pearson) 95 % interval for a binomial proportion, as the worker's
/// `clopper_pearson` computes it, by bisection on the binomial tails.
enum ClopperPearson {
    static func interval(successes k: Int, trials n: Int, alpha: Double = 0.05) -> ClosedRange<Double>? {
        guard n > 0, (0...n).contains(k) else { return nil }
        let lower = k == 0 ? 0 : solve { p in tail(atLeast: k, n, p) - alpha / 2 }     // increasing in p
        let upper = k == n ? 1 : solve { p in alpha / 2 - (1 - tail(atLeast: k + 1, n, p)) }
        return lower...upper
    }

    /// P(X ≥ k) for X ~ Binomial(n, p), summed in log space.
    static func tail(atLeast k: Int, _ n: Int, _ p: Double) -> Double {
        guard k > 0 else { return 1 }
        guard k <= n else { return 0 }
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        let (lp, lq) = (log(p), log1p(-p))
        var s = 0.0
        for i in k...n { s += exp(lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1)) + Double(i) * lp + Double(n - i) * lq) }
        return min(1, s)
    }

    /// The root of an increasing function on (0, 1).
    private static func solve(_ f: (Double) -> Double) -> Double {
        var (lo, hi) = (0.0, 1.0)
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if f(mid) < 0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
