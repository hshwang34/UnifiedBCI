import Foundation

/// SplitMix64 (Steele, Lea & Flood 2014): the PRNG of `seeded_shuffle_v1`. Chosen over the
/// platform generators because it is a few lines of wrapping integer arithmetic that the
/// worker mirrors exactly (`protocol_schedule.SplitMix64`); the golden vectors pin both.
public struct SplitMix64: Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// An unbiased integer in `0..<n` by rejection: draws until `x >= (2^64 − n) mod n`,
    /// then returns `x mod n`. Always draws at least once. `n` must be ≥ 1.
    public mutating func below(_ n: UInt64) -> UInt64 {
        precondition(n >= 1)
        let threshold = (0 &- n) % n
        while true {
            let x = next()
            if x >= threshold { return x % n }
        }
    }
}

/// The trial order and rests of one run under `seeded_shuffle_v1` (brief 005). Deterministic
/// from the protocol's content and the seed, on any Mac and in the worker:
///
/// 1. Start SplitMix64 at the run seed (session seed + run index).
/// 2. Shuffle the class-balanced list (class 0 × N, then class 1 × N) by Fisher–Yates from
///    the end: for i = count−1 down to 1, swap i with `below(i + 1)`.
/// 3. Then, per trial in order, rest = `restMinMs + below(restMaxMs − restMinMs + 1)`: a 1 ms
///    grid, so the plan doesn't depend on a display's frame rate (the runner presents each
///    phase at the first frame on or after its time).
/// 4. Offsets from the first fixation onset: cue = fixation + `fixationMs`, cue end = cue +
///    `cueMs`, end = cue end + rest = the next trial's fixation.
public enum ProtocolSchedule {
    public static func trials(_ p: ProtocolRecord, seed: UInt64, runID: String) -> [RunPlan.PlannedTrial] {
        precondition(ProtocolRecord.problems(p.draft).isEmpty && p.order == ProtocolRecord.orderSeededShuffleV1, "schedule needs a valid protocol")
        var rng = SplitMix64(seed: seed)
        var order = p.classes.flatMap { Array(repeating: $0.label, count: p.trialsPerClass) }
        var i = order.count - 1
        while i > 0 {
            order.swapAt(i, Int(rng.below(UInt64(i + 1))))
            i -= 1
        }
        let width = UInt64(p.timing.restMaxMs - p.timing.restMinMs + 1)
        let rests = order.map { _ in p.timing.restMinMs + Int(rng.below(width)) }
        var out: [RunPlan.PlannedTrial] = []
        var t = 0
        for (k, label) in order.enumerated() {
            let cue = t + p.timing.fixationMs, cueEnd = cue + p.timing.cueMs, end = cueEnd + rests[k]
            out.append(.init(trialID: RunPlan.trialID(runID: runID, index: k), label: label, restMs: rests[k],
                             fixationOffsetMs: t, cueOffsetMs: cue, cueEndOffsetMs: cueEnd, endOffsetMs: end))
            t = end
        }
        return out
    }

    /// A fresh session seed, below `RunPlan.sessionSeedLimit`. The one random draw a session
    /// makes; everything after it is reproducible from the stored value.
    public static func drawSessionSeed() -> UInt64 {
        UInt64.random(in: 0..<RunPlan.sessionSeedLimit)
    }

    /// The plan for run `runIndex` of a session, ready to store before the first cue.
    public static func plan(_ p: ProtocolRecord, recordingID: UUID, sessionID: String?, runID: String, runIndex: Int,
                            sessionSeed: UInt64, createdAt: Date = Date()) -> RunPlan {
        let seed = sessionSeed + UInt64(runIndex)
        return RunPlan(recordingID: recordingID, sessionID: sessionID, runID: runID, runIndex: runIndex,
                       protocolID: p.protocolID, protocolVersion: p.version, protocolContentHash: p.contentHash,
                       order: p.order, sessionSeed: sessionSeed, seed: seed, trials: trials(p, seed: seed, runID: runID),
                       createdAt: createdAt)
    }
}
