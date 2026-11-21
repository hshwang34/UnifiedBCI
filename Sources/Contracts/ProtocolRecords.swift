import CryptoKit
import Foundation

// Cued-protocol records (brief 005): a protocol version and the plan of one run made from it.
// Both are additive to format 1 (older readers never look in `protocols/` or `runs/`).
// docs/data-contracts.md, "Protocols and run plans", has the rules.

/// What the participant sees for a class during its cue phase.
public enum CueSymbol: String, Codable, Sendable, CaseIterable {
    case leftArrow = "left_arrow"
    case rightArrow = "right_arrow"
    case upArrow = "up_arrow"
    case downArrow = "down_arrow"
}

/// The editable part of a protocol (decision #28: every value is editable). A new version is
/// a draft written as a new `ProtocolRecord`; nothing is edited in place.
public struct ProtocolDraft: Codable, Sendable, Equatable {
    public var name: String
    public var classes: [ProtocolClass]
    public var timing: PhaseTiming
    public var trialsPerClass: Int
    public var runsPerSession: Int
    /// Shown to the participant before the first trial.
    public var instructions: String

    public init(name: String, classes: [ProtocolClass], timing: PhaseTiming, trialsPerClass: Int, runsPerSession: Int, instructions: String) {
        self.name = name; self.classes = classes; self.timing = timing
        self.trialsPerClass = trialsPerClass; self.runsPerSession = runsPerSession; self.instructions = instructions
    }

    /// Decision #28 (Graz-style left vs right hand) with decision #37's 4 runs per session.
    public static let grazDefault = ProtocolDraft(
        name: "Left vs right hand (Graz-style)",
        classes: [.init(label: "cue_left_hand", displayName: "Left hand", cue: .leftArrow),
                  .init(label: "cue_right_hand", displayName: "Right hand", cue: .rightArrow)],
        timing: .init(fixationMs: 2000, cueMs: 4000, restMinMs: 1500, restMaxMs: 2500),
        trialsPerClass: 20, runsPerSession: 4,
        instructions: "Look at the cross. When an arrow appears, imagine squeezing that hand until the arrow goes away. Keep still and relax when the screen is blank.")
}

public struct ProtocolClass: Codable, Sendable, Equatable {
    /// Stored on cue events and used by the evaluation, e.g. `cue_left_hand`. `[a-z0-9_]`.
    public var label: String
    public var displayName: String
    public var cue: CueSymbol

    public init(label: String, displayName: String, cue: CueSymbol) {
        self.label = label; self.displayName = displayName; self.cue = cue
    }
}

/// Phase durations in whole milliseconds, so a schedule is integer arithmetic only and
/// reproduces exactly in the worker. Rest is drawn per trial from `restMinMs...restMaxMs`.
public struct PhaseTiming: Codable, Sendable, Equatable {
    public var fixationMs: Int
    public var cueMs: Int
    public var restMinMs: Int
    public var restMaxMs: Int

    public init(fixationMs: Int, cueMs: Int, restMinMs: Int, restMaxMs: Int) {
        self.fixationMs = fixationMs; self.cueMs = cueMs; self.restMinMs = restMinMs; self.restMaxMs = restMaxMs
    }
}

/// A rule a protocol breaks, named so the editor can say which one (brief 005 validation).
public enum ProtocolProblem: Equatable, Sendable, CustomStringConvertible {
    case format(Int)
    case directoryMismatch
    case version
    case order(String)
    case classCount(Int)
    case label(String)
    case duplicateLabel(String)
    case text(String)
    case duration(String)
    case restRange
    case trialsPerClass(Int)
    case runsPerSession(Int)
    case contentHash

    public var description: String {
        switch self {
        case .format(let v): return "format \(v)"
        case .directoryMismatch: return "id does not match its directory"
        case .version: return "version must be 1 without basedOn, or above 1 with it"
        case .order(let o): return "unknown order \"\(o)\""
        case .classCount(let n): return "this recipe needs exactly two classes, not \(n)"
        case .label(let l): return "label \"\(l)\" must be 1–\(ProtocolRecord.maxLabelLength) characters of a–z, 0–9 and _"
        case .duplicateLabel(let l): return "label \"\(l)\" is used twice"
        case .text(let what): return "\(what) is empty, too long or has control characters"
        case .duration(let what): return "\(what) must be more than 0 s and at most 30 s"
        case .restRange: return "shortest rest must not exceed longest rest"
        case .trialsPerClass(let n): return "trials per class must be 1–100, not \(n)"
        case .runsPerSession(let n): return "runs per session must be 1–\(ProtocolRecord.maxRunsPerSession), not \(n)"
        case .contentHash: return "contentHash does not match the protocol's content"
        }
    }
}

/// `protocols/<protocolID>/protocol.json`: one immutable protocol version. A new version is
/// a new directory with `basedOn` naming its parent and the same `lineageID` (the id of v1).
public struct ProtocolRecord: Codable, Sendable, Equatable, Identifiable {
    public static let orderSeededShuffleV1 = "seeded_shuffle_v1"
    public static let maxPhaseMs = 30_000
    public static let trialsPerClassRange = 1...100
    public static let maxRunsPerSession = 20
    public static let maxLabelLength = 48
    public static let maxVersion = 10_000
    public static let maxInstructionsLength = 2000
    /// Largest `protocol.json` read at all; a valid one is a few KB.
    public static let maxFileBytes = 64 * 1024

    public var formatVersion: Int = ContractVersion.format
    public var protocolID: UUID
    public var lineageID: UUID
    public var version: Int
    public var basedOn: UUID?
    public var name: String
    public var classes: [ProtocolClass]
    public var timing: PhaseTiming
    public var trialsPerClass: Int
    public var runsPerSession: Int
    public var order: String
    public var instructions: String
    public var createdAt: Date
    /// SHA-256 (hex) over `canonicalContent`; copied to every run plan made from this version.
    public var contentHash: String
    public var id: UUID { protocolID }

    /// A version from `draft`. `parent` nil makes v1 of a new lineage.
    public init(draft: ProtocolDraft, parent: ProtocolRecord?, version: Int? = nil, protocolID: UUID = UUID(), createdAt: Date = Date()) {
        self.protocolID = protocolID
        self.lineageID = parent?.lineageID ?? protocolID
        self.version = version ?? (parent.map { $0.version + 1 } ?? 1)
        self.basedOn = parent?.protocolID
        self.name = draft.name; self.classes = draft.classes; self.timing = draft.timing
        self.trialsPerClass = draft.trialsPerClass; self.runsPerSession = draft.runsPerSession
        self.order = Self.orderSeededShuffleV1
        self.instructions = draft.instructions
        self.createdAt = createdAt
        self.contentHash = ""
        self.contentHash = Self.contentHash(of: self)
    }

    public var draft: ProtocolDraft {
        ProtocolDraft(name: name, classes: classes, timing: timing, trialsPerClass: trialsPerClass,
                      runsPerSession: runsPerSession, instructions: instructions)
    }

    /// The bytes `contentHash` covers: what the participant sees and when (class labels and
    /// cue symbols, phase timing, trials per class, order algorithm), as compact JSON with
    /// sorted keys. Names, instructions and runs per session are left out: they don't change
    /// a run's stimuli. The worker mirror (`protocol_schedule.canonical_content`) builds the
    /// same bytes; the golden vectors pin them.
    public static func canonicalContent(classes: [ProtocolClass], timing: PhaseTiming, trialsPerClass: Int, order: String) -> Data {
        struct Cls: Encodable { let cue: String; let label: String }
        struct Content: Encodable { let classes: [Cls]; let order: String; let timing: PhaseTiming; let trialsPerClass: Int }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = Content(classes: classes.map { Cls(cue: $0.cue.rawValue, label: $0.label) }, order: order, timing: timing, trialsPerClass: trialsPerClass)
        return (try? e.encode(content)) ?? Data()
    }

    public static func contentHash(of r: ProtocolRecord) -> String {
        sha256Hex(canonicalContent(classes: r.classes, timing: r.timing, trialsPerClass: r.trialsPerClass, order: r.order))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every rule the draft breaks (empty when valid). The editor names each one.
    public static func problems(_ d: ProtocolDraft) -> [ProtocolProblem] {
        var out: [ProtocolProblem] = []
        if !ChannelMapRecord.isSane(d.name) { out.append(.text("name")) }
        if d.classes.count != 2 { out.append(.classCount(d.classes.count)) }
        var seen = Set<String>()
        for c in d.classes {
            if !isValidLabel(c.label) { out.append(.label(c.label)) }
            if !seen.insert(c.label).inserted { out.append(.duplicateLabel(c.label)) }
            if !ChannelMapRecord.isSane(c.displayName) { out.append(.text("display name")) }
        }
        let t = d.timing
        for (what, ms) in [("fixation", t.fixationMs), ("cue", t.cueMs), ("shortest rest", t.restMinMs), ("longest rest", t.restMaxMs)]
        where !(1...maxPhaseMs).contains(ms) {
            out.append(.duration(what))
        }
        if t.restMinMs > t.restMaxMs { out.append(.restRange) }
        if !trialsPerClassRange.contains(d.trialsPerClass) { out.append(.trialsPerClass(d.trialsPerClass)) }
        if !(1...maxRunsPerSession).contains(d.runsPerSession) { out.append(.runsPerSession(d.runsPerSession)) }
        if !isSaneInstructions(d.instructions) { out.append(.text("instructions")) }
        return out
    }

    /// Why a stored version can't be trusted, or nil. A `.bciproj` may come from anyone.
    public func problem(directoryID: UUID) -> ProtocolProblem? {
        guard formatVersion >= 1, formatVersion <= ContractVersion.format else { return .format(formatVersion) }
        guard protocolID == directoryID else { return .directoryMismatch }
        guard (version == 1 && basedOn == nil && lineageID == protocolID)
                || ((2...Self.maxVersion).contains(version) && basedOn != nil && basedOn != protocolID) else { return .version }
        guard order == Self.orderSeededShuffleV1 else { return .order(order) }
        if let first = Self.problems(draft).first { return first }
        guard contentHash == Self.contentHash(of: self) else { return .contentHash }
        return nil
    }

    public static func isValidLabel(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= maxLabelLength && s.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5f }
    }

    /// Like `ChannelMapRecord.isSane` but longer and allowing line breaks.
    static func isSaneInstructions(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return text.count <= maxInstructionsLength && !lines.isEmpty
            && lines.allSatisfy { ChannelMapRecord.isSane(String($0), maxLength: maxInstructionsLength) }
    }
}

/// `recordings/<recordingID>/runs/<runID>.plan.json`: the planned trials of one run, written
/// atomically before the run's first cue and never changed. Offsets are nominal milliseconds
/// from the first fixation onset (pauses shift what happens, not the plan).
public struct RunPlan: Codable, Sendable, Equatable {
    public static let maxFileBytes = 1024 * 1024
    /// Session seeds stay below 2^52 so every seed is exact as a JSON number in any reader.
    public static let sessionSeedLimit: UInt64 = 1 << 52

    public var formatVersion: Int = ContractVersion.format
    public var recordingID: UUID
    public var sessionID: String?
    public var runID: String
    /// 0-based position of this run in its session.
    public var runIndex: Int
    public var protocolID: UUID
    public var protocolVersion: Int
    public var protocolContentHash: String
    public var order: String
    /// Drawn once per session; `seed` = `sessionSeed` + `runIndex`.
    public var sessionSeed: UInt64
    public var seed: UInt64
    public var trials: [PlannedTrial]
    public var createdAt: Date

    public init(recordingID: UUID, sessionID: String?, runID: String, runIndex: Int, protocolID: UUID, protocolVersion: Int,
                protocolContentHash: String, order: String, sessionSeed: UInt64, seed: UInt64, trials: [PlannedTrial], createdAt: Date) {
        self.recordingID = recordingID; self.sessionID = sessionID; self.runID = runID; self.runIndex = runIndex
        self.protocolID = protocolID; self.protocolVersion = protocolVersion; self.protocolContentHash = protocolContentHash
        self.order = order; self.sessionSeed = sessionSeed; self.seed = seed; self.trials = trials; self.createdAt = createdAt
    }

    public struct PlannedTrial: Codable, Sendable, Equatable {
        public var trialID: String
        public var label: String
        public var restMs: Int
        public var fixationOffsetMs: Int
        public var cueOffsetMs: Int
        public var cueEndOffsetMs: Int
        public var endOffsetMs: Int

        public init(trialID: String, label: String, restMs: Int, fixationOffsetMs: Int, cueOffsetMs: Int, cueEndOffsetMs: Int, endOffsetMs: Int) {
            self.trialID = trialID; self.label = label; self.restMs = restMs; self.fixationOffsetMs = fixationOffsetMs
            self.cueOffsetMs = cueOffsetMs; self.cueEndOffsetMs = cueEndOffsetMs; self.endOffsetMs = endOffsetMs
        }
    }

    /// `<runID>-t<nn>`, numbered from 1.
    public static func trialID(runID: String, index: Int) -> String {
        runID + "-t" + (index + 1 < 10 ? "0" : "") + String(index + 1)
    }

    /// Run ids name a file, so they are restricted to `[A-Za-z0-9_-]`, 1–64 characters.
    public static func isValidRunID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy {
            (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5f || $0 == 0x2d
        }
    }

    /// Why a stored plan can't be trusted, or nil: it must be this format, sit in its
    /// recording under its own run id, and describe a consistent, gapless trial sequence.
    public func problem(recordingID dirID: UUID, fileRunID: String) -> String? {
        guard formatVersion >= 1, formatVersion <= ContractVersion.format else { return "format \(formatVersion)" }
        guard recordingID == dirID, runID == fileRunID, Self.isValidRunID(runID) else { return "plan does not match its file" }
        guard order == ProtocolRecord.orderSeededShuffleV1 else { return "unknown order \"\(order)\"" }
        guard protocolVersion >= 1, protocolContentHash.utf8.count == 64,
              protocolContentHash.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return "protocol reference is malformed" }
        guard (0..<ProtocolRecord.maxRunsPerSession).contains(runIndex), sessionSeed < Self.sessionSeedLimit,
              seed == sessionSeed + UInt64(runIndex) else { return "seed is not session seed + run index" }
        let maxTrials = 2 * ProtocolRecord.trialsPerClassRange.upperBound
        guard (2...maxTrials).contains(trials.count) else { return "trial count \(trials.count) out of range" }
        var next = 0
        let phase = 1...ProtocolRecord.maxPhaseMs
        let span = 0...(maxTrials * 3 * ProtocolRecord.maxPhaseMs)    // bounds every offset before any arithmetic
        for (k, t) in trials.enumerated() {
            guard [t.fixationOffsetMs, t.cueOffsetMs, t.cueEndOffsetMs, t.endOffsetMs].allSatisfy(span.contains) else { return "trial \(k + 1) is out of range" }
            guard t.trialID == Self.trialID(runID: runID, index: k), ProtocolRecord.isValidLabel(t.label),
                  t.fixationOffsetMs == next, phase.contains(t.cueOffsetMs - t.fixationOffsetMs),
                  phase.contains(t.cueEndOffsetMs - t.cueOffsetMs), phase.contains(t.restMs),
                  t.endOffsetMs == t.cueEndOffsetMs + t.restMs else { return "trial \(k + 1) is inconsistent" }
            next = t.endOffsetMs
        }
        return nil
    }
}
