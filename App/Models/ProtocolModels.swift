import Foundation
import Observation

// Brief 005 PR 4: the Protocols section. Every string the list, the detail and the
// "New version…" editor show is built here, locale-independent, so the views stay thin and
// tests check the copy without rendering.

extension Fmt {
    /// Whole milliseconds as seconds with only the digits needed: 2000 → "2 s", 1500 →
    /// "1.5 s", 2250 → "2.25 s", 1 → "0.001 s". Integer arithmetic, so no float rounding.
    static func seconds(ms: Int) -> String { secondsValue(ms: ms) + " s" }

    /// The same without the unit, as the editor's fields show it.
    static func secondsValue(ms: Int) -> String {
        let (whole, frac) = (ms / 1000, abs(ms % 1000))
        guard frac > 0 else { return String(whole) }
        var digits = String(frac)
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits)"
    }

    static func usedIn(_ runs: Int) -> String {
        switch runs {
        case 0: return "Not used yet"
        case 1: return "Used in 1 run"
        default: return "Used in \(runs) runs"
        }
    }

    /// "5 min 20 s"; under a minute "48 s".
    static func duration(ms: Int) -> String {
        let s = (ms + 500) / 1000
        return s < 60 ? "\(s) s" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s")
    }
}

extension CueSymbol {
    var title: String {
        switch self {
        case .leftArrow: return "Left arrow"
        case .rightArrow: return "Right arrow"
        case .upArrow: return "Up arrow"
        case .downArrow: return "Down arrow"
        }
    }

    var symbol: String {
        switch self {
        case .leftArrow: return "arrow.left"
        case .rightArrow: return "arrow.right"
        case .upArrow: return "arrow.up"
        case .downArrow: return "arrow.down"
        }
    }
}

enum ProtocolCopy {
    static let emptyTitle = "No Protocols"
    static let noSelection = "No Protocol Selected"
    static let emptyDescription = "This project has no protocol yet."
    static let newVersion = "New Version…"
    static let newVersionHelp = "Edit a copy of this version and save it as the next version. This version stays as it is."
    static let mislinkedRow = "Mislinked"
    static let mislinked = "This version names a parent from another lineage, so it is listed on its own and can't be edited into a new version."
    static let immutable = "Versions never change. Editing saves a new version beside this one."
    static let timingCaveat = "Cue timing is logged by the app's software, not measured on the screen."
    static let orderDescription = "Seeded shuffle: the same seed gives the same order and rests on any Mac."

    static func defaultNotSaved(_ error: Error, writable: Bool) -> String {
        writable ? "The default protocol couldn't be added: \(storeError(error))"
                 : "This project can't be written to, so the default protocol couldn't be added. Open a copy in a folder you can write to."
    }

    static func unreadableList(_ error: Error) -> String { "The protocols couldn't be read: \(storeError(error))" }

    static func notSaved(_ error: Error) -> String { "Not saved: \(storeError(error))" }

    /// A store error as a plain sentence; never a Swift enum description.
    static func storeError(_ error: Error) -> String {
        guard let e = error as? ProjectStoreError else { return "something went wrong while saving." }
        switch e {
        case .invalidProtocol(let why), .invalidRunPlan(let why): return sentence(why)
        case .io(_, let code) where [EROFS, EACCES, EPERM].contains(code): return "the project can't be written to."
        case .io(_, let code) where [ENOSPC, EDQUOT].contains(code): return "the disk is full."
        case .io(_, let code): return sentence(String(cString: strerror(code)).lowercased())
        case .alreadyExists: return "a version with that id already exists; try again."
        case .notAProject, .unsupportedFormatVersion: return "this project can't be read by this version of the app."
        default: return "the project's files are not as expected."
        }
    }

    private static func sentence(_ s: String) -> String { s.hasSuffix(".") ? s : s + "." }

    static func unreadable(_ n: Int) -> String {
        n == 1 ? "1 protocol file couldn't be read and isn't listed." : "\(n) protocol files couldn't be read and aren't listed."
    }

    /// The warning beside a cue shorter than the evaluation window's end (brief 005 validation).
    static func windowWarning(cueMs: Int, windowEndMs: Int) -> String? {
        guard cueMs < windowEndMs else { return nil }
        return "The cue (\(Fmt.seconds(ms: cueMs))) ends before the default evaluation window does (\(Fmt.seconds(ms: windowEndMs))), so that window won't fit inside the cue."
    }

    /// A store rule in words, naming the field.
    static func problem(_ p: ProtocolProblem) -> String {
        switch p {
        case .classCount(let n): return "This recipe needs exactly two classes, not \(n)."
        case .label(let l): return "Label “\(l)” may only use a–z, 0–9 and _, 1–\(ProtocolRecord.maxLabelLength) characters."
        case .duplicateLabel(let l): return "Both classes use the label “\(l)”. Labels must differ."
        case .reservedLabel(let l): return "“\(l)” is the name of a protocol event. Choose another label."
        case .text(let what): return "\(what.prefix(1).uppercased() + what.dropFirst()) is empty, too long or has control characters."
        case .duration(let what): return "\(what.prefix(1).uppercased() + what.dropFirst()) must be more than 0 s and at most \(ProtocolRecord.maxPhaseMs / 1000) s."
        case .restRange: return "Shortest rest must not be longer than longest rest."
        case .trialsPerClass: return "Trials per class must be 1–\(ProtocolRecord.trialsPerClassRange.upperBound)."
        case .runsPerSession: return "Runs per session must be 1–\(ProtocolRecord.maxRunsPerSession)."
        case .format, .directoryMismatch, .version, .order, .contentHash: return "This protocol can't be saved: \(p)."
        }
    }
}

// MARK: - List

/// The sidebar's Protocols list: one section per lineage, versions newest first.
struct ProtocolListModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let version: String
        let name: String
        let usedIn: String
        let mislinked: Bool
        let accessibility: String
    }

    struct Group: Identifiable, Equatable {
        let id: UUID
        let title: String
        let rows: [Row]
    }

    let groups: [Group]
    let footnote: String?

    init(list: ProtocolList, usage: [UUID: Int]) {
        let lineages = Dictionary(grouping: list.protocols) { list.lineage(of: $0) }
        groups = lineages.map { lineage, versions in
            let newest = versions.sorted { $0.version > $1.version }
            return Group(id: lineage, title: newest[0].name, rows: newest.map { r in
                let mislinked = list.mislinked.contains(r.protocolID)
                let used = Fmt.usedIn(usage[r.protocolID] ?? 0)
                return Row(id: r.protocolID, version: "v\(r.version)", name: r.name, usedIn: used, mislinked: mislinked,
                           accessibility: "\(r.name), version \(r.version), \(used.lowercased())" + (mislinked ? ", mislinked" : ""))
            })
        }
        .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
        footnote = list.unreadable > 0 ? ProtocolCopy.unreadable(list.unreadable) : nil
    }

    var isEmpty: Bool { groups.isEmpty }
}

// MARK: - Detail

struct ProtocolDetailModel: Equatable {
    struct Field: Identifiable, Equatable {
        let label: String
        let value: String
        var mono = false
        var id: String { label }
    }

    struct ClassRow: Identifiable, Equatable {
        let displayName: String
        let label: String
        let cue: String
        let symbol: String
        var id: String { label }
    }

    let title: String
    let badge: String
    let lineage: String
    let usedIn: String
    let warnings: [String]
    let timing: [Field]
    let classes: [ClassRow]
    let instructions: String
    let identity: [Field]
    let canCreateVersion: Bool

    init(_ r: ProtocolRecord, list: ProtocolList, usage: [UUID: Int], windowEndMs: Int) {
        let t = r.timing
        let trials = 2 * r.trialsPerClass
        title = r.name
        badge = "v\(r.version)"
        let parent = r.basedOn.flatMap { id in list.protocols.first { $0.protocolID == id } }
        lineage = r.basedOn == nil ? "Version 1" : "Version \(r.version) · based on " + (parent.map { "v\($0.version)" } ?? "a version not in this project")
        usedIn = Fmt.usedIn(usage[r.protocolID] ?? 0)
        let mislinked = list.mislinked.contains(r.protocolID)
        warnings = (mislinked ? [ProtocolCopy.mislinked] : []) + [ProtocolCopy.windowWarning(cueMs: t.cueMs, windowEndMs: windowEndMs)].compactMap { $0 }
        let meanTrialMs = t.fixationMs + t.cueMs + (t.restMinMs + t.restMaxMs) / 2
        timing = [
            Field(label: "Fixation", value: Fmt.seconds(ms: t.fixationMs)),
            Field(label: "Cue", value: Fmt.seconds(ms: t.cueMs)),
            Field(label: "Rest", value: t.restMinMs == t.restMaxMs ? Fmt.seconds(ms: t.restMinMs)
                  : "\(Fmt.secondsValue(ms: t.restMinMs))–\(Fmt.seconds(ms: t.restMaxMs)), drawn per trial"),
            Field(label: "Trials per class", value: "\(r.trialsPerClass) (\(trials) per run)"),
            Field(label: "Runs per session", value: "\(r.runsPerSession)"),
            Field(label: "Run length", value: "about \(Fmt.duration(ms: trials * meanTrialMs)) of trials"),
            Field(label: "Order", value: ProtocolCopy.orderDescription),
        ]
        classes = r.classes.map { ClassRow(displayName: $0.displayName, label: $0.label, cue: $0.cue.title, symbol: $0.cue.symbol) }
        instructions = r.instructions
        identity = [
            Field(label: "Content hash", value: r.contentHash, mono: true),
            Field(label: "Protocol ID", value: r.protocolID.uuidString, mono: true),
            Field(label: "Created", value: ProtocolDetailModel.created(r.createdAt)),
        ]
        canCreateVersion = !mislinked
    }

    /// "2026-11-20 14:05 UTC": the stored time, independent of the Mac's locale.
    static func created(_ date: Date) -> String { createdFormat.format(date) }

    private static let createdFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits) UTC",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian))
}

// MARK: - Editor

/// "New version…": a copy of one version as editable fields. Durations are typed in
/// seconds and kept to the millisecond (the protocol's 1 ms grid); every rule the draft
/// breaks is named, and a draft identical to a version of the lineage is refused.
@MainActor @Observable
final class ProtocolEditor: Identifiable {
    struct ClassFields: Equatable {
        var displayName: String
        var label: String
        var cue: CueSymbol
    }

    struct Issue: Identifiable, Equatable {
        enum Kind: Equatable { case error, warning }
        let kind: Kind
        let text: String
        var id: String { text }
    }

    nonisolated let id = UUID()
    let base: ProtocolRecord
    /// The versions of the base's lineage, for "nothing changed" and the next version number.
    let lineage: [ProtocolRecord]
    let windowEndMs: Int
    var name: String
    var classes: [ClassFields]
    var fixation: String
    var cue: String
    var restMin: String
    var restMax: String
    /// Typed as text, so an empty or non-numeric entry is named rather than reverted.
    var trialsPerClass: String
    var runsPerSession: String
    var instructions: String
    var saveError: String?
    var isSaving = false

    init(base: ProtocolRecord, lineage: [ProtocolRecord], windowEndMs: Int) {
        self.base = base; self.lineage = lineage; self.windowEndMs = windowEndMs
        name = base.name
        classes = base.classes.map { ClassFields(displayName: $0.displayName, label: $0.label, cue: $0.cue) }
        fixation = Fmt.secondsValue(ms: base.timing.fixationMs)
        cue = Fmt.secondsValue(ms: base.timing.cueMs)
        restMin = Fmt.secondsValue(ms: base.timing.restMinMs)
        restMax = Fmt.secondsValue(ms: base.timing.restMaxMs)
        trialsPerClass = String(base.trialsPerClass)
        runsPerSession = String(base.runsPerSession)
        instructions = base.instructions
    }

    var nextVersion: Int { (lineage.map(\.version).max() ?? base.version) + 1 }
    var title: String { "New Version of “\(base.name)”" }
    var subtitle: String { "Saves as v\(nextVersion), based on v\(base.version). v\(base.version) stays as it is." }
    var saveTitle: String { "Save as v\(nextVersion)" }

    /// The draft, or nil while a duration doesn't parse.
    var draft: ProtocolDraft? { Self.validate(self).draft }
    var issues: [Issue] { Self.validate(self).issues }
    var canSave: Bool { !isSaving && draft != nil && !issues.contains { $0.kind == .error } }

    static func validate(_ e: ProtocolEditor) -> (draft: ProtocolDraft?, issues: [Issue]) {
        var issues: [Issue] = []
        func ms(_ text: String, _ what: String) -> Int? {
            switch parseMilliseconds(text) {
            case .success(let v): return v
            case .failure(let why):
                issues.append(.init(kind: .error, text: why.text(what)))
                return nil
            }
        }
        func count(_ text: String, _ what: String) -> Int? {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 6, t.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let v = Int(t) else {
                issues.append(.init(kind: .error, text: "\(what) must be a whole number."))
                return nil
            }
            return v
        }
        let trials = count(e.trialsPerClass, "Trials per class"), runs = count(e.runsPerSession, "Runs per session")
        let parsed = (ms(e.fixation, "Fixation"), ms(e.cue, "Cue"), ms(e.restMin, "Shortest rest"), ms(e.restMax, "Longest rest"))
        let parsesAll = parsed.0 != nil && parsed.1 != nil && parsed.2 != nil && parsed.3 != nil && trials != nil && runs != nil
        // A field that doesn't parse is checked as the base's value, so every other rule
        // is still named; there is no draft until all parse.
        let t = e.base.timing
        let (f, c, rMin, rMax) = (parsed.0 ?? t.fixationMs, parsed.1 ?? t.cueMs, parsed.2 ?? t.restMinMs, parsed.3 ?? t.restMaxMs)
        let draft = ProtocolDraft(name: e.name, classes: e.classes.map { ProtocolClass(label: $0.label, displayName: $0.displayName, cue: $0.cue) },
                                  timing: .init(fixationMs: f, cueMs: c, restMinMs: rMin, restMaxMs: rMax),
                                  trialsPerClass: trials ?? e.base.trialsPerClass, runsPerSession: runs ?? e.base.runsPerSession,
                                  instructions: e.instructions)
        issues += ProtocolRecord.problems(draft).map { Issue(kind: .error, text: ProtocolCopy.problem($0)) }
        if parsesAll, let same = e.lineage.first(where: { $0.draft == draft }) {
            issues.append(.init(kind: .error, text: "Nothing changed from v\(same.version). Change a value to save a new version."))
        }
        if let w = ProtocolCopy.windowWarning(cueMs: c, windowEndMs: e.windowEndMs) { issues.append(.init(kind: .warning, text: w)) }
        var seen = Set<String>()
        return (parsesAll ? draft : nil, issues.filter { seen.insert($0.text).inserted })
    }

    enum ParseProblem: Error, Equatable {
        case empty, notANumber, tooPrecise

        func text(_ what: String) -> String {
            switch self {
            case .empty: return "\(what) needs a duration in seconds."
            case .notANumber: return "\(what) must be a number of seconds, like 2 or 1.5."
            case .tooPrecise: return "\(what) can have at most 3 decimal places: durations are kept to the millisecond."
            }
        }
    }

    /// Seconds as typed ("2", "1.5", "0.250") to whole milliseconds; digits and one "." only
    /// (no sign, exponent or grouping), at most 3 decimals and 6 whole digits, so no input
    /// overflows.
    static func parseMilliseconds(_ text: String) -> Result<Int, ParseProblem> {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .failure(.empty) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }),
              !(parts[0].isEmpty && (parts.count == 1 || parts[1].isEmpty)), parts[0].count <= 6 else { return .failure(.notANumber) }
        var frac = parts.count == 2 ? String(parts[1]) : ""
        while frac.count > 3, frac.hasSuffix("0") { frac.removeLast() }
        guard frac.count <= 3 else { return .failure(.tooPrecise) }
        return .success((Int(parts[0]) ?? 0) * 1000 + (Int(frac.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0))
    }
}
