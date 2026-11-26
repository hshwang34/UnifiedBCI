import Foundation

// Brief 007 PR 5 (decision #46): short "?" help at a fixed list of concept-heavy spots. Each
// topic is 2–4 plain sentences: what it is, what good looks like, what to do if it's bad.
// Offline, no network. The scientific rules hold here too: chance level is named wherever
// accuracy is, nothing is overclaimed, and model confidence is the model's own uncalibrated
// estimate.

/// Help copy that isn't a "?" topic.
enum HelpCopy {
    /// The Parameters… popover's one-line caption (a popover can't open a "?" popover).
    static let parametersCaption = "Changes apply to the next evaluation only; every value used is stored with its result."
    static let aboutTheseSettings = "About these settings"
}

enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    // The brief's "signal trace / lane height" spot is two topics, one per place, so each is exact.
    case streamHealth, channelMap, qualityChecks, livePreview, recordedTrace, headMontage, trialTiming
    case heldOutAccuracy, chanceAndBaseline, evaluationParameters, freeze, replayParity
    case modelConfidence, liveRunInterval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .streamHealth: return "Stream health"
        case .channelMap: return "Channel map"
        case .qualityChecks: return "Quality checks"
        case .livePreview: return "Live preview and lane height"
        case .recordedTrace: return "Signal trace"
        case .headMontage: return "Head montage"
        case .trialTiming: return "Trial timing"
        case .heldOutAccuracy: return "Held-out accuracy"
        case .chanceAndBaseline: return "Chance level and the baseline"
        case .evaluationParameters: return "Evaluation parameters"
        case .freeze: return "Freezing a model"
        case .replayParity: return "Replay parity"
        case .modelConfidence: return "Model confidence and the threshold"
        case .liveRunInterval: return "Live-run accuracy and its interval"
        }
    }

    /// The popover's sentences, in order: what it is, what good looks like, what to do.
    var sentences: [String] {
        switch self {
        case .streamHealth:
            return ["Stream health tells you whether samples are reaching the app from the board, not whether the signal itself is good.",
                    "A healthy stream has an effective rate close to the board's rate, no counter skips and no disconnects.",
                    "If skips or disconnects keep climbing, move the dongle closer to the board, check the battery and keep other 2.4 GHz devices away. Missing samples are recorded as gaps and never filled in."]
        case .channelMap:
            return ["The channel map says which scalp position each channel's electrode sits on, and what the reference is.",
                    "The app uses the map exactly as you declare it and never guesses positions from the number of channels.",
                    "If you don't know the positions, choose Record without positions: the montage is stored as \"undeclared\", and you can still record and evaluate."]
        case .qualityChecks:
            return ["The quality checks run six rules on every channel: flatline, pinned at a limit, large deflections, mains line noise, outlier amplitude and outlier high-frequency power.",
                    "A usable recording has few or no flags on the channels you plan to analyse.",
                    "If many channels are flagged, check electrode contact and the reference, then record again. The checks describe the data and never change it, and passing them doesn't prove a signal comes from the brain."]
        case .livePreview:
            return ["The live preview draws the last 10 seconds of every channel in microvolts, with each channel's mean removed for display only.",
                    "Lane height is the microvolt range one lane spans; on Auto it is picked so a typical channel fills its lane, and rare peaks clip at the lane edge.",
                    "Clean EEG looks like small, irregular waves; a flat line, a steady large wave or sudden steps usually mean a loose electrode, and changing the lane height only changes the drawing, never the recording."]
        case .recordedTrace:
            return ["The signal trace shows a 10-second window of every channel from the stored recording, raw or band-passed, with each lane centred on that channel's typical level.",
                    "All channels share one lane height, set from the typical channel's range, so a flat channel looks flat and a noisy one looks noisy.",
                    "Flagged lanes carry their quality flags; if a lane is flat or full of steps, check that electrode before the next recording, because stored data never changes."]
        case .headMontage:
            return ["The head shows where each channel's electrode sits, taken from the declared channel map; drag to turn it and click a sensor to find its channel.",
                    "Ringed sensors have at least one quality flag in the selected segment, and channels without a declared position are listed rather than placed.",
                    "If the positions look wrong, the map was declared wrongly; record again with a corrected map, because stored recordings never change."]
        case .trialTiming:
            return ["Each trial shows a fixation cross, then the cue telling the participant which hand to imagine moving, then a rest of random length so the next cue can't be anticipated.",
                    "The analysis window must fit inside the cue; the editor warns you when it wouldn't.",
                    "If the participant tires, use more runs with breaks between them rather than a shorter cue."]
        case .heldOutAccuracy:
            return ["Held-out accuracy is how often the decoder picked the right class on runs it never saw during training; balanced accuracy weights both classes equally.",
                    "The interval shows how uncertain that number is with this few trials, so compare it with chance level, marked on the bar as the larger-class rate (about 0.5 for two balanced classes), not with 1.",
                    "If the interval includes chance level, this result is not evidence that the decoder works; record more runs before drawing a conclusion."]
        case .chanceAndBaseline:
            return ["Chance level is what guessing would score: 0.5 for two balanced classes, or the larger class's share when the classes are unequal.",
                    "The baseline is a simpler method (log-variance features with the same classifier) tested on the same split. A decoder worth using clearly beats both chance level and the baseline.",
                    "If it doesn't beat the baseline, the spatial filtering isn't adding anything on this data."]
        case .evaluationParameters:
            return ["These settings change one evaluation: the seed picks which runs are held out, the window sets where after the cue the analysis looks, and CSP components set how many spatial filters are used.",
                    "The defaults come from the analysis worker, and every value used is stored with the result so it can be reproduced.",
                    "Trying settings until the number looks good overfits to this data. Choose them before you look, or report every setting you tried."]
        case .freeze:
            return ["Freezing saves the model fitted for this result exactly as it is, with its filters, channel order and sample rate, so live runs use the same model.",
                    "A frozen model never changes; to try other settings, evaluate again and freeze the new result.",
                    "Only freeze a result whose held-out accuracy is clearly above chance level; a model that isn't is not ready to give feedback."]
        case .replayParity:
            return ["Replay feeds a stored recording through the frozen model in small pieces, the way a live run does, and compares every output with the offline computation.",
                    "Passing means the live path computes the same numbers as the offline analysis, within the tolerances listed.",
                    "If it fails, don't run live with this model: the mismatch is a bug in the app, not a property of your data."]
        case .modelConfidence:
            return ["Model confidence is the model's own estimate of how sure it is about each window, and it is uncalibrated: 0.8 does not mean the model is right 80 % of the time.",
                    "When confidence is below the threshold (0.6 by default), the feedback abstains: the participant's bar is hidden and \"Model unsure\" is shown instead of a guess.",
                    "If it abstains on most windows, the model isn't separating the classes in this session; check the signal or record new training runs."]
        case .liveRunInterval:
            return ["The live run's accuracy counts the model's pick at each cued trial's scoring window, including trials where the feedback abstained; those are also counted separately.",
                    "The interval is an exact 95 % range for the true accuracy given this many trials. Compare it with chance level and with the frozen model's held-out result.",
                    "A short live run gives a wide interval, so run more trials before you say feedback works."]
        }
    }

    var text: String { sentences.joined(separator: " ") }

    /// "Help: Stream health".
    var accessibilityLabel: String { "Help: \(title)" }
}
