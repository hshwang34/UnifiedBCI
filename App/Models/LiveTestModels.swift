import Foundation

// Brief 006 PR 7: the Live Test operator view. Every string it shows is built here (Fmt,
// locale-independent). Confidence is "model confidence": the LDA's own posterior for its
// chosen class, not calibrated and never a probability of intent.

enum LiveTestCopy {
    static let title = "Live Test"
    static let feedbackHeader = "Live feedback"
    static let abstainHeader = "Abstained"
    static let latencyHeader = "Software latency"
    static let trialsHeader = "Trials"
    static let trialsNote = "Each trial's outcome is its cue-locked window, the one that matches the model's training window. The bar's frames are not counted."
    static let confidenceNote = "Model confidence is the classifier's own posterior for the class it picked, from 0.50 to 1.00. It is not calibrated, and it is not a probability of intent: a two-class model can't tell when nobody is imagining anything."
    static let latencyNote = "Measured in the app: from the drain of the window's last sample to the prediction. Radio or USB transport and display delay are not measured."
    static let previewPlaceholder = "Debug preview: connect a source, then Start Run… on the acquisition screen runs the protocol with live feedback from the newest frozen model."
    static let noTrials = "No trials yet."

    static func modelLine(_ m: ModelRecord, _ p: ProtocolRecord) -> String { "\(m.name) · \(StartRunCopy.protocolTitle(p))" }
}

struct LiveFeedbackPanelModel: Equatable {
    enum Tone: Equatable { case positive, info, warning, danger }

    struct TrialRow: Identifiable, Equatable {
        let id: String
        let cue: String
        let outcome: String
        /// nil: no outcome yet, abstained, invalid or aborted.
        let correct: Bool?
        let accessibilityLabel: String
    }

    let state: String
    let tone: Tone
    let detail: String?
    struct Bar: Equatable { let direction: Double; let length: Double }

    /// The bar as the participant sees it: −1 left or +1 right, length 0…1; nil when hidden.
    let bar: Bar?
    let barSide: String?
    /// The classes at the bar's two ends, as the participant window places them.
    let leftEnd: String
    let rightEnd: String
    let prediction: String
    let abstainValue: String
    let abstainLine: String
    let latencyValue: String
    let latencyLine: String
    let trials: [TrialRow]
    let trialsSummary: String

    init(_ s: LiveInferenceRunner.Status, model: ModelRecord, protocolRecord p: ProtocolRecord, threshold: Double,
         directions: [String: Double], truth: [String: String], aborted: Set<String>) {
        func name(_ label: String) -> String { p.classes.first { $0.label == label }?.displayName ?? ClassDisplay.name(label) }
        switch (s.validity, s.display) {
        case (nil, _):
            (state, tone) = (s.stopped ? "Stopped" : "Starting analysis…", .info)
        case (_, .bar):
            (state, tone) = ("Showing feedback", .positive)
        case (.valid?, .hidden(nil)):
            (state, tone) = ("Valid · outside the feedback span", .info)
        case (let v?, .hidden(let words)):
            state = words ?? FeedbackPolicy.words(v)
            switch v {
            case .valid, .insufficientWindow: tone = .info
            case .stale: tone = .warning
            case .disconnected, .workerUnavailable, .channelMismatch, .invalidInput: tone = .danger
            }
        }
        detail = s.validity == .valid ? nil : s.detail
        let left = model.classLabels.first { (directions[$0] ?? 1) < 0 } ?? model.classLabels[0]
        let right = model.classLabels.first { $0 != left } ?? model.classLabels[1]
        leftEnd = "◀ " + name(left)
        rightEnd = name(right) + " ▶"
        if case .bar(let side, let length) = s.display {
            bar = Bar(direction: directions[side] ?? 1, length: length)
            barSide = name(side)
        } else {
            bar = nil
            barSide = nil
        }
        if let c = s.confidence, let score = s.score {
            let label = model.classLabels[score > 0 ? 1 : 0]
            prediction = "\(name(label)) · model confidence \(Fmt.fixed(c)) · score \(Fmt.signed(score))"
        } else {
            prediction = "No prediction yet"
        }
        if let rate = s.abstainRate {
            abstainValue = "\(Int((rate * 100).rounded())) %"
            abstainLine = "of \(s.validHops) valid window\(s.validHops == 1 ? "" : "s") were below the threshold of \(Fmt.fixed(threshold))"
        } else {
            abstainValue = "–"
            abstainLine = "No valid windows yet · threshold \(Fmt.fixed(threshold))"
        }
        if let l = s.receiptToEmission {
            latencyValue = "\(Self.ms(l.p50)) / \(Self.ms(l.p95))"
            latencyLine = "p50 / p95 receipt → prediction, max \(Self.ms(l.max)) (n = \(l.count))"
        } else {
            latencyValue = "–"
            latencyLine = "Nothing measured yet"
        }
        var rows: [TrialRow] = []
        var counts = (right: 0, wrong: 0, abstained: 0, invalid: 0, pending: 0)
        for (trial, label) in truth.sorted(by: { $0.key < $1.key }) {
            let outcome: String, correct: Bool?
            if aborted.contains(trial) {
                (outcome, correct) = ("Aborted · not counted", nil)
            } else {
                switch s.outcomes[trial] {
                case .chosen(let c)?:
                    correct = c == label
                    outcome = "\(name(c)) · \(c == label ? "correct" : "wrong")"
                    if c == label { counts.right += 1 } else { counts.wrong += 1 }
                case .abstained?:
                    (outcome, correct) = ("Abstained · not confident", nil)
                    counts.abstained += 1
                case .invalid(let v, _)?:
                    (outcome, correct) = ("Invalid · \(FeedbackPolicy.words(v))", nil)
                    counts.invalid += 1
                case nil:
                    (outcome, correct) = ("Waiting for its window", nil)
                    counts.pending += 1
                }
            }
            rows.append(TrialRow(id: trial, cue: name(label), outcome: outcome, correct: correct,
                                 accessibilityLabel: "Trial \(trial), cue \(name(label)): \(outcome)"))
        }
        trials = rows
        let decided = counts.right + counts.wrong + counts.abstained + counts.invalid
        trialsSummary = rows.isEmpty ? LiveTestCopy.noTrials
            : "\(decided) of \(rows.count) trial\(rows.count == 1 ? "" : "s") decided: \(counts.right) correct, \(counts.wrong) wrong, "
                + "\(counts.abstained) abstained, \(counts.invalid) invalid"
    }

    /// Milliseconds for display; a value that isn't a finite, plausible time reads "–" (never traps).
    static func ms(_ v: Double) -> String {
        guard v.isFinite, abs(v) <= LiveRunRecord.maxMillis else { return "–" }
        return abs(v) < 10 ? "\(Fmt.fixed(v, 1)) ms" : "\(Int(v.rounded())) ms"
    }
}
