import Foundation

// Copy for the Freeze sheet, the parity view and the model error codes (brief 006). Built
// from stored records only; views stay thin and tests read the strings directly.

/// Plain words for the worker's model error codes.
enum ModelErrorText {
    static let modelCodes: Set<String> = ["invalid_model", "channel_mismatch"]

    /// Why `t` can't be an abstention threshold, or nil. Model confidence is always at
    /// least 0.5, so anything below would never abstain and 1 would always abstain.
    static func thresholdProblem(_ t: Double) -> String? {
        guard t.isFinite, t >= 0.5, t < 1 else {
            return "The abstention threshold must be at least 0.50 and below 1.00 (model confidence is never below 0.50)."
        }
        return nil
    }

    static func describe(code: String, message: String) -> String {
        switch code {
        case "invalid_model":
            return message.contains("changed since it was frozen")
                ? "This model's file changed since it was frozen, so it can't be trusted. Freeze the result again."
                : "This model can't be used: its stored arrays failed the check (\(message))."
        case "invalid_threshold":
            return message
        case "channel_mismatch":
            return "This recording doesn't match the model: \(message.replacingOccurrences(of: "channels differ from the model: ", with: "")). "
                + "Nothing is reordered or resampled."
        default:
            return message
        }
    }
}

extension Fmt {
    /// "1 × 10⁻⁸", "3.2 × 10⁻¹²", "0": tolerances and deviations, locale-independent.
    static func scientific(_ value: Double) -> String {
        guard value.isFinite, value != 0 else { return value == 0 ? "0" : "\(value)" }
        var exponent = Int(floor(log10(abs(value))))
        var mantissa = fixed(value / pow(10, Double(exponent)), 1)
        if mantissa.hasPrefix("10") || mantissa.hasPrefix("-10") { exponent += 1; mantissa = fixed(value / pow(10, Double(exponent)), 1) }
        if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
        let sup = String(exponent).map { c -> Character in
            c == "-" ? "⁻" : Array("⁰¹²³⁴⁵⁶⁷⁸⁹")[Int(String(c)) ?? 0]
        }
        return "\(mantissa) × 10\(String(sup))"
    }

    static func seconds(_ value: Double) -> String { "\(fixed(value, 1)) s" }
}

/// The "Freeze for live use…" sheet (brief 006 Freeze criteria, decisions #38 and #40).
struct FreezeSheetModel: Equatable {
    struct Row: Equatable, Identifiable { let label: String; let value: String; var id: String { label } }

    let title: String
    let defaultName: String
    let rows: [Row]
    /// "Feedback can show for 1.5 s of each 4.0 s cue …", or why it can't.
    let feedbackSpan: String
    /// Decision #40: suggest a 2 s window when the evaluation used another length.
    let windowSuggestion: String?
    let evidence: String
    let confidenceNote = "The bar shows model confidence: how strongly the classifier favours one of its two classes. "
        + "It is not calibrated and is not a probability of intent."
    let canFreeze: Bool

    static let suggestedWindowSeconds = 2.0

    /// `channelLabels`: channel id → the label the recording declares (`ChannelSpec.label`).
    init(result: StoredResult, report: EvaluationReport?, role: ModelRole, sessions: [String?], cueLengthSeconds: Double?,
         channelLabels: [String: String] = [:]) {
        let p = result.pipeline
        let c = p.configuration
        let offset = c["window_offset_s"].flatMap(Double.init)
        let length = c["window_length_s"].flatMap(Double.init)
        let recipe = role == .reference ? Self.recipeName(p.recipe) : Self.recipeName(c["baseline"] ?? "")
        let date = Self.dateText(result.meta.createdAt)
        title = "Freeze for live use"
        defaultName = "\(role == .reference ? "Model" : "Baseline") \(date)"
        let runs = report?.splitManifest.trainingRuns ?? []
        let knownSessions = Set(sessions.compactMap { $0 })
        let sessionText = sessions.isEmpty || sessions.contains(where: { $0 == nil }) ? "session unknown"
            : "session \(knownSessions.sorted().joined(separator: ", "))"
        var rows = [
            Row(label: "Model", value: "\(recipe), the fit on the training runs of the result from \(date)"),
            Row(label: "Training runs", value: runs.isEmpty ? "not recorded" : "\(runs.joined(separator: ", ")) · \(sessionText)"),
            Row(label: "Channels", value: Self.channels(p.expectedChannelIDs, labels: channelLabels)),
            Row(label: "Sample rate", value: Fmt.hertz(p.expectedSampleRateHz)),
        ]
        if let lo = c["bandpass_low_hz"].flatMap(Double.init), let hi = c["bandpass_high_hz"].flatMap(Double.init) {
            rows.append(Row(label: "Band-pass", value: "\(Fmt.fixed(lo, 1))–\(Fmt.fixed(hi, 1)) Hz, causal, order \(c["bandpass_order"] ?? "?")"))
        }
        if let offset, let length {
            rows.append(Row(label: "Window", value: "\(Fmt.seconds(length)) starting \(Fmt.seconds(offset)) after the cue"))
        }
        rows.append(Row(label: "Classes", value: [c["label_left"], c["label_right"]].compactMap { $0 }.joined(separator: " vs ")))
        self.rows = rows
        canFreeze = offset != nil && length != nil

        feedbackSpan = Self.span(offset: offset, length: length, cue: cueLengthSeconds)
        windowSuggestion = Self.suggestion(offset: offset, length: length, cue: cueLengthSeconds)
        let key = role == .reference ? report?.comparison.reference : report?.comparison.baseline
        if let h = key.flatMap({ report?.models[$0]?.holdout }) {
            let ci = Fmt.interval(h.accuracyCi95).map { " · accuracy \(Fmt.fixed(h.accuracy)), 95 % CI \($0) (trial-level, n = \(h.nTestTrials))" } ?? ""
            evidence = "This model's evidence is its held-out result: balanced accuracy \(Fmt.fixed(h.balancedAccuracy))\(ci). Freezing adds no new evidence."
        } else {
            evidence = "This model's evidence is the held-out result it was frozen from. Freezing adds no new evidence."
        }
    }

    /// Decision #40, the worker's rule (`streaming._eligible_trial`): a window is eligible
    /// when it starts at or after cue + max(offset, 0) and ends by the cue's end, so eligible
    /// windows end during the last `cue − max(offset, 0) − length` seconds of the cue.
    static func eligibleSpanSeconds(offset: Double, length: Double, cue: Double) -> Double {
        cue - max(offset, 0) - length
    }

    /// Decision #40: suggest 2 s only to a longer window (it leaves more of the cue for
    /// feedback). A shorter window already leaves more; that is said without ranking it.
    static func suggestion(offset: Double?, length: Double?, cue: Double?) -> String? {
        guard let offset, let length, abs(length - suggestedWindowSeconds) > 1e-9 else { return nil }
        guard length > suggestedWindowSeconds else {
            return "This model's \(Fmt.seconds(length)) window is shorter than the 2 s suggested for live use, so feedback can show for more of each cue. "
                + "Its held-out result was measured with this window."
        }
        let then = cue.map { c in
            let s = eligibleSpanSeconds(offset: offset, length: suggestedWindowSeconds, cue: c)
            return s > 0 ? ": feedback would then show for \(Fmt.seconds(s)) of each cue" : ""
        } ?? ""
        return "For live feedback, evaluate with a 2 s window\(then). This model's \(Fmt.seconds(length)) window leaves less of the cue for feedback."
    }

    /// Decision #40: only windows wholly inside the imagery period show feedback.
    static func span(offset: Double?, length: Double?, cue: Double?) -> String {
        guard let offset, let length else { return "The evaluation didn't record its window, so the model can't be frozen." }
        guard let cue else { return "Feedback shows only for windows wholly inside each cue; how long depends on the protocol's cue length." }
        let s = eligibleSpanSeconds(offset: offset, length: length, cue: cue)
        guard s > 1e-9 else {
            return "Feedback can't show: the \(Fmt.seconds(offset)) offset and the \(Fmt.seconds(length)) window fill the whole \(Fmt.seconds(cue)) cue."
        }
        return "Feedback can show for \(Fmt.seconds(s)) of each \(Fmt.seconds(cue)) cue (only windows wholly inside the imagery period)."
    }

    /// "16, in this order: FC3, FC1, …": the electrode labels the model was trained on, from
    /// the recording's channel specs; a channel with no declared label keeps its id.
    static func channels(_ ids: [String], labels: [String: String]) -> String {
        let names = ids.map { id in labels[id].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? id }
        return "\(ids.count), in this order: \(names.joined(separator: ", "))"
    }

    /// Channel id → declared label for one recording.
    static func labels(_ channels: [ChannelSpec]) -> [String: String] {
        Dictionary(channels.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    static func recipeName(_ id: String) -> String {
        switch id {
        case "csp_rlda_v1": return "CSP + shrinkage LDA"
        case "logvar_rlda_v1": return "Log-variance + shrinkage LDA (baseline)"
        default: return id
        }
    }

    /// Local time, like the run and result lists (`Fmt.dateTime`).
    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String { Fmt.dateTime(date, timeZone: timeZone) }
}

/// The parity view of one stored replay (brief 006 Replay parity criteria).
struct ParityViewModel: Equatable {
    struct Line: Equatable, Identifiable {
        let quantity: String
        let text: String
        /// nil when nothing was compared for this quantity.
        let within: Bool?
        var id: String { quantity }
    }

    let passed: Bool
    let headline: String
    let symbol: String
    let tolerances: [Line]
    let windows: String
    let boundary: String
    let firstValid: String
    let chunkings: String
    let mismatches: [String]
    /// "Cue-locked trial windows: 40 of 40 match offline", from the stored predictions.
    let cueLocked: String
    /// "At threshold 0.60: hop windows 12 of 140 valid abstained · cue-locked …".
    let abstentions: String

    /// `predictions`: the replay's stored `predictions.jsonl` (the first chunking), which
    /// carry the offline reference for every window; empty when they couldn't be read.
    init?(record: LiveRunRecord, sampleRateHz: Double, predictions: [PredictionRecord] = []) {
        guard let p = record.parity else { return nil }
        let scoreTolerance = p.deviations.first { $0.quantity == "score" }?.allowed ?? 1e-8
        let cl = predictions.filter { $0.windowKind == "cue_locked" && $0.offline != nil }
        if cl.isEmpty {
            cueLocked = p.cueLockedCompared.map { "Cue-locked trial windows compared: \($0)" } ?? "No cue-locked trial windows were compared"
        } else {
            let matched = cl.filter { q in
                guard let o = q.offline, o.validity == q.validity else { return false }
                guard let a = q.score, let b = o.score else { return q.score == nil && o.score == nil }
                return abs(a - b) <= scoreTolerance
            }.count
            cueLocked = "Cue-locked trial windows: \(matched) of \(cl.count) match offline (the windows each trial is scored on)"
        }
        let threshold = Fmt.fixed(record.abstainThreshold)
        if predictions.isEmpty {
            let valid = record.summary?.byValidity[Validity.valid.rawValue] ?? 0
            abstentions = "At threshold \(threshold): \(record.summary?.abstained ?? 0) of \(valid) valid windows abstained (model confidence below \(threshold))"
        } else {
            func count(_ kind: String) -> String {
                let valid = predictions.filter { $0.windowKind == kind && $0.validity == .valid }
                return "\(valid.filter { $0.action.kind == .abstain }.count) of \(valid.count)"
            }
            abstentions = "At threshold \(threshold), abstained: hop windows \(count("hop")) valid · cue-locked trial windows \(count("cue_locked")) valid "
                + "(model confidence below \(threshold))"
        }
        // Every declared quantity is listed; one the worker reported no value for is "not
        // compared", never a number.
        let names = ["bandpassed_uv", "features", "score"] + p.deviations.map(\.quantity).filter { !["bandpassed_uv", "features", "score"].contains($0) }
        tolerances = names.map { q in
            let name = Self.quantityName(q)
            guard let d = p.deviations.first(where: { $0.quantity == q }), let observed = d.observed else {
                return Line(quantity: q, text: "\(name): not compared", within: nil)
            }
            let unit = q == "bandpassed_uv" ? " µV" : ""
            return Line(quantity: q, text: "\(name): largest difference \(Fmt.scientific(observed))\(unit) · allowed \(Fmt.scientific(d.allowed))\(unit)",
                        within: observed.isFinite && observed <= d.allowed)
        }
        // The headline can't say "matches" while a line shows a difference over its tolerance.
        passed = p.passed && !tolerances.contains { $0.within == false }
        headline = passed ? "Streaming matches offline within tolerance" : "Streaming differs from offline"
        symbol = passed ? "checkmark.seal" : "exclamationmark.triangle"
        let cue = p.cueLockedCompared.map { ", \($0) of them cue-locked trial windows" } ?? ""
        windows = "\(p.windowsCompared) windows compared\(cue)"
        boundary = p.boundaryWindows == 0 ? "No windows on the decision boundary"
            : "\(p.boundaryWindows) window\(p.boundaryWindows == 1 ? "" : "s") on the decision boundary (listed, not counted as differences)"
        firstValid = p.firstValidWindowStop.enumerated().map { i, stop in
            stop < 0 ? "segment \(i + 1): no valid window"
                : "segment \(i + 1): first valid window ends at \(Fmt.seconds(Double(stop) / max(sampleRateHz, 1)))"
        }.joined(separator: " · ")
        chunkings = "Re-chunked as " + p.chunkings.map { $0 == "random" ? "a seeded random mix" : "\($0)-sample" }.joined(separator: ", ") + " pieces"
        mismatches = p.mismatches ?? []
    }

    static func quantityName(_ q: String) -> String {
        switch q {
        case "bandpassed_uv": return "Band-passed samples"
        case "features": return "Features"
        case "score": return "LDA score"
        default: return q
        }
    }
}

/// One frozen model in the Pipelines list (brief 006 Freeze criteria).
struct FrozenModelRowModel: Equatable, Identifiable {
    let id: UUID
    let name: String
    let source: String
    let usage: String

    init(model: ModelRecord, sourceResultDate: Date?, liveRuns: Int) {
        id = model.modelID
        name = model.name
        source = "\(FreezeSheetModel.recipeName(model.recipe)) · from the result of "
            + (sourceResultDate.map { FreezeSheetModel.dateText($0) } ?? "a result no longer in this project")
        usage = liveRuns == 0 ? "Not used in a live run yet" : "Used in \(liveRuns) live run\(liveRuns == 1 ? "" : "s")"
    }

    /// The model's facts on its detail page.
    /// `channelLabels`: from the model's source recording (empty when it is gone: ids then).
    static func facts(_ m: ModelRecord, channelLabels: [String: String] = [:]) -> [FreezeSheetModel.Row] {
        [
            .init(label: "Channels", value: FreezeSheetModel.channels(m.expectedChannelIDs, labels: channelLabels)),
            .init(label: "Sample rate", value: Fmt.hertz(m.expectedSampleRateHz)),
            .init(label: "Band-pass", value: "\(Fmt.fixed(m.bandpass.lowHz, 1))–\(Fmt.fixed(m.bandpass.highHz, 1)) Hz, causal, order \(m.bandpass.order)"),
            .init(label: "Window", value: "\(Fmt.seconds(m.window.lengthSeconds)) starting \(Fmt.seconds(m.window.offsetSeconds)) after the cue"),
            .init(label: "Filter warm-up", value: "\(m.warmupSamples) samples (\(Fmt.seconds(Double(m.warmupSamples) / max(m.expectedSampleRateHz, 1))))"),
            .init(label: "Classes", value: "\(m.classLabels[0]) vs \(m.classLabels[1])"),
            .init(label: "Training runs", value: m.trainingRunIDs.isEmpty ? "not recorded" : m.trainingRunIDs.joined(separator: ", ")),
            .init(label: "Frozen", value: FreezeSheetModel.dateText(m.frozenAt)),
            .init(label: "Arrays SHA-256", value: String(m.fittedSHA256.prefix(16)) + "…"),
        ]
    }
}

/// Copy for Freeze and Replay outside the two models above.
enum ReplayCopy {
    static let freezeButton = "Freeze for live use…"
    static let freezeHelp = "Freeze this result's fitted model for replay and live feedback"
    static let replayButton = "Replay…"
    static let replayHelp = "Run a recording through a frozen model chunk by chunk and compare with offline"
    static let modelsSection = "Frozen models"
    static let recipesSection = "Recipes"
    static let noModels = "No frozen models. Open a result and choose Freeze for live use…."
    static let noModelForReplay = "No frozen model yet. Open a result and choose Freeze for live use… first."
    static let replaysTitle = "Replays"
    static let noReplays = "Not replayed yet. Replay… runs a recording through this model chunk by chunk."
    static let thresholdHelp = "Model confidence below this counts as an abstention (decision #39). It is stored with the replay."
    static let replayExplainer = "The recording is fed through the model in pieces of 1, 7, 13 and 125 samples and a seeded random mix, "
        + "and every window is compared with the offline evaluation. Channels must match the model exactly; nothing is reordered or resampled."

    static func frozen(_ name: String) -> String { "Frozen as \u{201C}\(name)\u{201D}. It is listed under Pipelines." }

    static func replayRow(_ r: LiveRunRecord, recording: String) -> String {
        "\(FreezeSheetModel.dateText(r.startedAt)) · \(recording) · " + (r.parity?.passed == true ? "matches" : "differs")
    }

    /// The Replay sheet's status line for the runner's state.
    static func state(_ s: ReplayRunner.State) -> String? {
        switch s {
        case .idle, .done: return nil
        case .running(.starting): return "Starting the analysis worker…"
        case .running(.loading): return "Loading the recording and the model…"
        case .running(.replaying): return "Replaying chunk by chunk at five chunkings…"
        case .running(.storing): return "Saving the replay…"
        case .analysisUnavailable(let why): return "Analysis unavailable: the worker stopped (\(why)). Nothing was saved."
        case .refused(let code, let message): return ModelErrorText.describe(code: code, message: message)
        case .failed(let why): return "Replay failed; nothing was saved. \(why)"
        case .cancelled: return "Cancelled — nothing saved."
        }
    }

    /// Why Freeze failed, in words: the worker's model codes, or the store's refusal.
    static func freezeFailed(_ error: Error) -> String {
        if let e = error as? WorkerError {
            return ModelErrorText.modelCodes.contains(e.code) ? ModelErrorText.describe(code: e.code, message: e.message)
                : "The analysis worker couldn't check the model (\(e.message)). Nothing was frozen."
        }
        if case ProjectStoreError.invalidModel(let why) = error { return "Not frozen: \(why)." }
        return "Not frozen: \(error)"
    }
}
