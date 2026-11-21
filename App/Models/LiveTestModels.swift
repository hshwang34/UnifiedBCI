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
    static let delayedDetail = "The newest bar is older than the 250 ms stale limit, so neither window shows it."
    static let directionProblem = "Live feedback needs one class cued with a left arrow and the other with a right arrow, so the bar's sides match the cues."

    static let betweenRunsState = "Between runs"
    static let betweenRunsLine = "No feedback between runs. It returns when the next run's cues start."
    static let sessionDoneState = "All runs done"
    static let sessionDoneLine = "No feedback after the session's last run. Finish Session stops the recording."

    static func modelLine(_ m: ModelRecord, _ p: ProtocolRecord) -> String { "\(m.name) · \(StartRunCopy.protocolTitle(p))" }
}

/// The operator's feedback state, built 20 times a second (it carries the stale rule), apart
/// from the tiles and trial rows (`LiveFeedbackPanelModel`, four times a second).
struct LiveFeedbackStateModel: Equatable {
    enum Tone: Equatable { case positive, info, warning, danger }
    /// No protocol run is in progress: the runner still scores the stream, but no cue can
    /// come, so the card names the gap instead of a per-window state.
    enum RunGap: Equatable { case betweenRuns, sessionDone }
    struct Bar: Equatable { let direction: Double; let length: Double }

    let state: String
    let tone: Tone
    let detail: String?

    /// The bar as the participant sees it: −1 left or +1 right, length 0…1; nil when hidden.
    let bar: Bar?
    let barSide: String?
    /// The classes at the bar's two ends, as the participant window places them.
    let leftEnd: String
    let rightEnd: String
    let prediction: String

    /// `mirror`: the feed's `mirror(now:)`, the participant's newest display under the same
    /// 250 ms / stall rule (nil before the first update); `mirrored`: the update it was decided
    /// from. The state, its detail and the confidence line all come from that one prediction
    /// when the update carries it, never from the 4 Hz status, which can be a window ahead or
    /// behind (the screenshot pass caught "Model unsure" beside "confidence 0.73" at a 0.60
    /// threshold). The bar never comes from `s`, so the operator is never shown a bar the
    /// participant sees as "Signal delayed". Stopped hides it for good.
    init(_ s: LiveInferenceRunner.Status, mirror: FeedbackPolicy.Display?, mirrored: LiveInferenceRunner.Update? = nil, gap: RunGap? = nil,
         model: ModelRecord, protocolRecord p: ProtocolRecord, directions: [String: Double]) {
        func name(_ label: String) -> String { p.classes.first { $0.label == label }?.displayName ?? ClassDisplay.name(label) }
        // The prediction the words describe: the mirrored update when it carries one.
        let source = mirrored.flatMap { $0.validity == nil ? nil : $0 }
        let validity = source?.validity ?? s.validity
        let validityDetail = source.map(\.detail) ?? s.detail
        let score = source.map(\.score) ?? s.score
        let confidence = source.map(\.confidence) ?? s.confidence
        let runGap = s.stopped ? nil : gap
        let delayedWords = FeedbackPolicy.words(.stale)
        let shown: FeedbackPolicy.Display
        if s.stopped {
            shown = .hidden(words: nil)
        } else if let mirror {
            shown = mirror
        } else if case .bar = s.display {
            shown = .hidden(words: delayedWords)        // no update in the feed yet: not trusted
        } else {
            shown = s.display
        }
        let delayedHere = !s.stopped && shown == .hidden(words: delayedWords) && (mirrored?.display ?? s.display) != shown
        switch (validity, shown) {
        case _ where s.stopped:
            (state, tone) = ("Stopped", .info)
        case _ where runGap != nil:
            // After a run (or the last one) the per-window words would be stale news.
            (state, tone) = (runGap == .betweenRuns ? LiveTestCopy.betweenRunsState : LiveTestCopy.sessionDoneState, .info)
        case _ where delayedHere:
            (state, tone) = (delayedWords, .warning)
        case (nil, _):
            (state, tone) = ("Starting analysis…", .info)
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
        detail = runGap != nil ? nil : delayedHere ? LiveTestCopy.delayedDetail : validity == .valid ? nil : validityDetail
        let left = model.classLabels.first { (directions[$0] ?? 1) < 0 } ?? model.classLabels[0]
        let right = model.classLabels.first { $0 != left } ?? model.classLabels[1]
        leftEnd = "◀ " + name(left)
        rightEnd = name(right) + " ▶"
        if runGap == nil, case .bar(let side, let length) = shown {
            bar = Bar(direction: directions[side] ?? 1, length: length)
            barSide = name(side)
        } else {
            bar = nil
            barSide = nil
        }
        if let gap = runGap {
            prediction = gap == .betweenRuns ? LiveTestCopy.betweenRunsLine : LiveTestCopy.sessionDoneLine
        } else if let c = confidence, let score {
            let label = model.classLabels[score > 0 ? 1 : 0]
            prediction = "\(name(label)) · model confidence \(Fmt.fixed(c)) · score \(Fmt.signed(score))"
        } else {
            prediction = "No prediction yet"
        }
    }
}

struct LiveFeedbackPanelModel: Equatable {
    typealias Tone = LiveFeedbackStateModel.Tone
    typealias Bar = LiveFeedbackStateModel.Bar

    struct TrialRow: Identifiable, Equatable {
        let id: String
        let cue: String
        let outcome: String
        /// nil: no outcome yet, abstained, invalid or aborted.
        let correct: Bool?
        let accessibilityLabel: String
    }

    let abstainValue: String
    let abstainLine: String
    let latencyValue: String
    let latencyLine: String
    let trials: [TrialRow]
    let trialsSummary: String

    /// Lines missing from the logs so far (failed writes), else nil.
    let logWarning: String?

    init(_ s: LiveInferenceRunner.Status, model: ModelRecord, protocolRecord p: ProtocolRecord,
         threshold: Double, truth: [String: String], aborted: Set<String>) {
        func name(_ label: String) -> String { p.classes.first { $0.label == label }?.displayName ?? ClassDisplay.name(label) }
        logWarning = LiveRunCopy.logGaps(predictions: s.predictionWriteFailures, feedback: s.feedbackWriteFailures)
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
                    (outcome, correct) = ("Abstained · model unsure", nil)
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
