import Foundation

// Protocols (`protocols/<uuid>/protocol.json`) and run plans
// (`recordings/<uuid>/runs/<runID>.plan.json`), brief 005. Both immutable once written.
extension ProjectStore {
    public static let protocolFileName = "protocol.json"
    public static let runsDirectoryName = "runs"
    public static let runPlanSuffix = ".plan.json"

    /// Saves a new protocol version from `draft` (decision #28: every value is editable, and
    /// editing makes a new version). `parent` nil starts a new lineage at v1. Otherwise the
    /// parent is re-read from the store by id (the caller's copy is not trusted), and the new
    /// version is one above the highest version of the parent's lineage, `basedOn` the parent.
    /// A draft identical to any version already in that lineage is refused. (Equality is over
    /// the whole draft: the content hash leaves out instructions and display names, which are
    /// still real edits.)
    @discardableResult
    public func createProtocolVersion(_ draft: ProtocolDraft, basedOn parent: ProtocolRecord?, now: Date = Date()) throws -> ProtocolRecord {
        if let first = ProtocolRecord.problems(draft).first { throw ProjectStoreError.invalidProtocol(first.description) }
        guard let parent else {
            let record = ProtocolRecord(draft: draft, parent: nil, createdAt: now)
            try Self.writeProtocol(record, in: directory)
            return record
        }
        let list = try protocols()
        guard let stored = list.protocols.first(where: { $0.protocolID == parent.protocolID }) else {
            throw ProjectStoreError.invalidProtocol("the version it was edited from is not in this project")
        }
        guard !list.mislinked.contains(stored.protocolID) else {
            throw ProjectStoreError.invalidProtocol("version \(stored.version) does not belong to the lineage it names")
        }
        let lineage = list.protocols.filter { list.lineage(of: $0) == list.lineage(of: stored) }
        if let same = lineage.first(where: { $0.draft == draft }) {
            throw ProjectStoreError.invalidProtocol("nothing changed from version \(same.version)")
        }
        let version = (lineage.map(\.version).max() ?? stored.version) + 1
        guard version <= ProtocolRecord.maxVersion else { throw ProjectStoreError.invalidProtocol("too many versions") }
        let record = ProtocolRecord(draft: draft, parent: stored, version: version, createdAt: now)
        try Self.writeProtocol(record, in: directory)
        return record
    }

    /// Writes `record` as a new immutable directory (temp → fsync → rename). Refuses a record
    /// that fails validation or whose directory already exists.
    static func writeProtocol(_ record: ProtocolRecord, in project: URL) throws {
        if let problem = record.problem(directoryID: record.protocolID) { throw ProjectStoreError.invalidProtocol(problem.description) }
        let fm = FileManager.default
        let parent = try ownDirectory(project.appendingPathComponent("protocols", isDirectory: true))
        let dir = parent.appendingPathComponent(record.protocolID.uuidString, isDirectory: true)
        guard !BoundedRead.exists(dir) else { throw ProjectStoreError.alreadyExists(dir) }
        let tmp = AtomicFile.tempURL(for: dir)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
            try AtomicFile.writeAndSync(try ContractJSON.encoder().encode(record), to: tmp.appendingPathComponent(Self.protocolFileName), fresh: true)
            try AtomicFile.syncTree(tmp)
            try AtomicFile.rename(tmp, to: dir)
            try AtomicFile.syncDirectory(parent)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Gives a project with no readable protocol the default one (decision #28) as v1. New
    /// projects get it from `create`; an older project gets it when the Protocols section asks.
    @discardableResult
    public func ensureDefaultProtocol(now: Date = Date()) throws -> ProtocolRecord? {
        guard try protocols().protocols.isEmpty else { return nil }
        return try createProtocolVersion(.grazDefault, basedOn: nil, now: now)
    }

    /// Stored versions that pass `ProtocolRecord.problem` (by name, then lineage, then
    /// version), how many were skipped as unreadable or invalid (one bad file hides no
    /// others), and which versions are mislinked: their `lineageID` differs from their
    /// stored parent's. A mislinked version is listed as a lineage of its own, never merged.
    public func protocols() throws -> ProtocolList {
        let parent = directory.appendingPathComponent("protocols", isDirectory: true)
        guard BoundedRead.exists(parent) else { return ProtocolList(protocols: [], unreadable: 0, mislinked: [], lineages: [:]) }
        let ids = try childIDs(in: "protocols", requiring: Self.protocolFileName)
        let records = ids.compactMap { id -> ProtocolRecord? in
            let url = parent.appendingPathComponent(id.uuidString).appendingPathComponent(Self.protocolFileName)
            guard let data = BoundedRead.data(at: url, maxBytes: ProtocolRecord.maxFileBytes),
                  let r = try? ContractJSON.decoder().decode(ProtocolRecord.self, from: data),
                  r.problem(directoryID: id) == nil else { return nil }
            return r
        }
        let byID = Dictionary(records.map { ($0.protocolID, $0) }, uniquingKeysWith: { a, _ in a })
        let mislinked = Set(records.filter { r in r.basedOn.flatMap { byID[$0] }.map { $0.lineageID != r.lineageID } ?? false }.map(\.protocolID))
        // Effective lineage: a mislinked version starts its own; others follow their parent chain.
        var lineages: [UUID: UUID] = [:]
        func lineage(_ r: ProtocolRecord, depth: Int = 0) -> UUID {
            if let known = lineages[r.protocolID] { return known }
            let value: UUID
            if mislinked.contains(r.protocolID) { value = r.protocolID }
            else if depth < ProtocolRecord.maxVersion, let p = r.basedOn.flatMap({ byID[$0] }), p.protocolID != r.protocolID { value = lineage(p, depth: depth + 1) }
            else { value = r.lineageID }
            lineages[r.protocolID] = value
            return value
        }
        for r in records { _ = lineage(r) }
        let sorted = records.sorted {
            ($0.name, lineages[$0.protocolID]!.uuidString, $0.version) < ($1.name, lineages[$1.protocolID]!.uuidString, $1.version)
        }
        return ProtocolList(protocols: sorted, unreadable: ids.count - records.count, mislinked: mislinked, lineages: lineages)
    }

    /// How many stored run plans name each protocol version ("used in n runs"). Plans whose
    /// protocol reference doesn't match a stored version don't count.
    public func protocolUsage() throws -> [UUID: Int] {
        let known = try protocols().protocols
        var counts: [UUID: Int] = [:]
        for id in try recordingIDs() {
            for plan in try runPlans(recording: id, protocols: known).plans { counts[plan.protocolID, default: 0] += 1 }
        }
        return counts
    }

    /// Writes `plan` atomically to `recordings/<id>/runs/<runID>.plan.json` before the run's
    /// first cue. A plan is never replaced, must name a stored protocol version with its
    /// content hash, and is only written into a real recording directory of this project.
    public func writeRunPlan(_ plan: RunPlan) throws {
        if let problem = plan.problem(recordingID: plan.recordingID, fileRunID: plan.runID) { throw ProjectStoreError.invalidRunPlan(problem) }
        guard Self.matches(plan, try protocols().protocols) else { throw ProjectStoreError.invalidRunPlan("protocol version or content hash is not in this project") }
        let recording = recordingDirectory(plan.recordingID)
        guard Self.isRealDirectory(recording), BoundedRead.exists(recording.appendingPathComponent(Self.recordingFileName)) else {
            throw ProjectStoreError.missingRecording(plan.recordingID)
        }
        let runs = try Self.ownDirectory(recording.appendingPathComponent(Self.runsDirectoryName, isDirectory: true))
        let file = runs.appendingPathComponent(plan.runID + Self.runPlanSuffix)
        guard !BoundedRead.exists(file) else { throw ProjectStoreError.alreadyExists(file) }
        try AtomicFile.write(try ContractJSON.encoder().encode(plan), to: file)
    }

    /// The recording's run plans that pass `RunPlan.problem` and name a stored protocol
    /// version with a matching content hash, by run index. Files that fail to read or
    /// validate are counted; plans whose protocol reference doesn't match are listed by run
    /// id and not used. A recording without `runs/` (any non-protocol recording) has none.
    public func runPlans(recording id: UUID) throws -> RunPlanList {
        try runPlans(recording: id, protocols: try protocols().protocols)
    }

    func runPlans(recording id: UUID, protocols known: [ProtocolRecord]) throws -> RunPlanList {
        let recording = recordingDirectory(id)
        let runs = recording.appendingPathComponent(Self.runsDirectoryName, isDirectory: true)
        guard Self.isRealDirectory(recording), Self.isRealDirectory(runs) else { return RunPlanList(plans: [], unreadable: 0, protocolMismatch: []) }
        let names = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter {
            $0.hasSuffix(Self.runPlanSuffix) && !$0.hasPrefix(AtomicFile.tempPrefix)
        }
        let valid = names.compactMap { name -> RunPlan? in
            let runID = String(name.dropLast(Self.runPlanSuffix.count))
            guard let data = BoundedRead.data(at: runs.appendingPathComponent(name), maxBytes: RunPlan.maxFileBytes),
                  let plan = try? ContractJSON.decoder().decode(RunPlan.self, from: data),
                  plan.problem(recordingID: id, fileRunID: runID) == nil else { return nil }
            return plan
        }
        let (plans, mismatched) = (valid.filter { Self.matches($0, known) }, valid.filter { !Self.matches($0, known) })
        return RunPlanList(plans: plans.sorted { ($0.runIndex, $0.runID) < ($1.runIndex, $1.runID) },
                           unreadable: names.count - valid.count, protocolMismatch: mismatched.map(\.runID).sorted())
    }

    static func matches(_ plan: RunPlan, _ known: [ProtocolRecord]) -> Bool {
        known.contains { $0.protocolID == plan.protocolID && $0.version == plan.protocolVersion && $0.contentHash == plan.protocolContentHash }
    }

    /// A directory itself, not a symbolic link to one.
    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Creates `url` if missing and returns it, refusing a symbolic link or non-directory
    /// planted there, so a hostile project can't aim a write outside itself.
    static func ownDirectory(_ url: URL) throws -> URL {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else if st.st_mode & S_IFMT != S_IFDIR {
            throw ProjectStoreError.invalidManifest("\(url.lastPathComponent) is not a directory")
        }
        return url
    }
}

/// `ProjectStore.protocols()`: the readable versions and what was wrong with the rest.
public struct ProtocolList: Sendable, Equatable {
    public var protocols: [ProtocolRecord]
    public var unreadable: Int
    /// Versions whose `lineageID` differs from their stored parent's.
    public var mislinked: Set<UUID>
    var lineages: [UUID: UUID]

    /// The lineage a version is grouped in: its own id when mislinked (or below one).
    public func lineage(of r: ProtocolRecord) -> UUID { lineages[r.protocolID] ?? r.lineageID }
}

/// `ProjectStore.runPlans(recording:)`.
public struct RunPlanList: Sendable, Equatable {
    public var plans: [RunPlan]
    public var unreadable: Int
    /// Run ids of plans that validate but name a protocol version or hash this project lacks.
    public var protocolMismatch: [String]
}
