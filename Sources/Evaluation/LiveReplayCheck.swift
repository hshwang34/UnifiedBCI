import Foundation

/// After a live run (brief 006): the new recording replayed through the same model, and
/// every window the live run scored compared with the replay's window at the same place
/// (segment, last sample, kind, and trial for cue-locked windows). A window matches when its validity is the same and
/// its LDA score agrees within the parity tolerance. A mismatch is a bug report, not a result.
public enum LiveReplayCheck {
    /// The declared score tolerance (brief 006, Replay parity: LDA score ≤ 1 × 10⁻⁸).
    public static let scoreTolerance = 1e-8
    /// At most this many differing sequence numbers are stored.
    public static let maxListed = 200

    struct Key: Hashable {
        let segment: Int
        let stop: Int
        let kind: String
        let trial: String?
    }

    static func key(_ p: PredictionRecord) -> Key? {
        guard let r = p.inputSampleRange else { return nil }
        // A hop window's trial (the cue it falls in) depends on cue_end placement; only a
        // cue-locked window is identified by its trial.
        let kind = p.windowKind ?? "hop"
        return Key(segment: p.inputSegment, stop: r.start + r.count, kind: kind, trial: kind == "cue_locked" ? p.trialID : nil)
    }

    /// Live windows lateness made `stale` were scored like any other; the app's own lateness
    /// rule is not part of the transforms, so they compare as the worker scored them.
    static func workerValidity(_ p: PredictionRecord) -> Validity {
        p.validity == .stale && p.validityDetail == "prediction_late" ? .valid : p.validity
    }

    public static func compare(live: [PredictionRecord], replay: [PredictionRecord]) -> LiveRunRecord.ReplayCheck {
        var byKey: [Key: PredictionRecord] = [:]
        for p in replay { if let k = key(p), byKey[k] == nil { byKey[k] = p } }
        // Frames dropped from the live buffer restart the live segment mid-recording, so every
        // live window from that segment on sits at other indices than the recording's: expected.
        let drops = live.filter { $0.validityDetail?.hasPrefix("frames_dropped") == true }
        let firstDrop = drops.map(\.inputSegment).min()
        var compared = 0, matched = 0
        var differing: [Int] = [], explained: [Int] = []
        for p in live {
            guard let k = key(p) else { continue }          // condition records score nothing
            compared += 1
            if let r = byKey[k], agrees(p, r) { matched += 1; continue }
            if differing.count < maxListed { differing.append(p.sequence ?? -1) } else { continue }
            if let d = firstDrop, p.inputSegment >= d { explained.append(p.sequence ?? -1) }
        }
        let why = drops.isEmpty || explained.isEmpty ? nil : "frames were dropped from the live buffer ("
            + drops.prefix(5).map { "\($0.validityDetail!.replacingOccurrences(of: "frames_dropped:", with: "")) samples before live segment \($0.inputSegment)" }
                .joined(separator: "; ") + ")"
        return .init(windowsCompared: compared, windowsMatched: matched, differingSequences: differing,
                     explainedSequences: explained.isEmpty ? nil : explained, explanation: why)
    }

    static func agrees(_ live: PredictionRecord, _ replay: PredictionRecord) -> Bool {
        guard workerValidity(live) == replay.validity else { return false }
        switch (live.score, replay.score) {
        case (nil, nil): return true
        case let (a?, b?): return a.isFinite && b.isFinite && abs(a - b) <= scoreTolerance
        default: return false
        }
    }
}
