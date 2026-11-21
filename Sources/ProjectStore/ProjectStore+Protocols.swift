import Foundation

// Protocols (`protocols/<uuid>/protocol.json`) and run plans
// (`recordings/<uuid>/runs/<runID>.plan.json`), brief 005. Both immutable once written.
extension ProjectStore {
    public static let protocolFileName = "protocol.json"
    public static let runsDirectoryName = "runs"
    public static let runPlanSuffix = ".plan.json"

    /// Saves a new protocol version from `draft` (decision #28: every value is editable, and
    /// editing makes a new version). `parent` nil starts a new lineage at v1; otherwise the
    /// version is one above the highest stored version of the parent's lineage, `basedOn`
    /// the parent. A draft identical to its parent is refused: nothing changed.
    @discardableResult
    public func createProtocolVersion(_ draft: ProtocolDraft, basedOn parent: ProtocolRecord?, now: Date = Date()) throws -> ProtocolRecord {
        if let first = ProtocolRecord.problems(draft).first { throw ProjectStoreError.invalidProtocol(first.description) }
        var version = 1
        if let parent {
            guard parent.draft != draft else { throw ProjectStoreError.invalidProtocol("nothing changed from version \(parent.version)") }
            let lineage = try protocols().protocols.filter { $0.lineageID == parent.lineageID }
            version = (lineage.map(\.version).max() ?? parent.version) + 1
            guard version <= ProtocolRecord.maxVersion else { throw ProjectStoreError.invalidProtocol("too many versions") }
        }
        let record = ProtocolRecord(draft: draft, parent: parent, version: version, createdAt: now)
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
    /// version), and how many were skipped as unreadable or invalid. One bad file hides no others.
    public func protocols() throws -> (protocols: [ProtocolRecord], unreadable: Int) {
        let parent = directory.appendingPathComponent("protocols", isDirectory: true)
        guard BoundedRead.exists(parent) else { return ([], 0) }
        let ids = try childIDs(in: "protocols", requiring: Self.protocolFileName)
        let records = ids.compactMap { id -> ProtocolRecord? in
            let url = parent.appendingPathComponent(id.uuidString).appendingPathComponent(Self.protocolFileName)
            guard let data = BoundedRead.data(at: url, maxBytes: ProtocolRecord.maxFileBytes),
                  let r = try? ContractJSON.decoder().decode(ProtocolRecord.self, from: data),
                  r.problem(directoryID: id) == nil else { return nil }
            return r
        }
        let sorted = records.sorted {
            ($0.name, $0.lineageID.uuidString, $0.version) < ($1.name, $1.lineageID.uuidString, $1.version)
        }
        return (sorted, ids.count - records.count)
    }

    /// How many stored run plans name each protocol version ("used in n runs").
    public func protocolUsage() throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for id in try recordingIDs() {
            for plan in try runPlans(recording: id).plans { counts[plan.protocolID, default: 0] += 1 }
        }
        return counts
    }

    /// Writes `plan` atomically to `recordings/<id>/runs/<runID>.plan.json` before the run's
    /// first cue. A plan is never replaced: an existing file for the run is refused.
    public func writeRunPlan(_ plan: RunPlan) throws {
        if let problem = plan.problem(recordingID: plan.recordingID, fileRunID: plan.runID) { throw ProjectStoreError.invalidRunPlan(problem) }
        let recording = recordingDirectory(plan.recordingID)
        guard BoundedRead.exists(recording.appendingPathComponent(Self.recordingFileName)) else { throw ProjectStoreError.missingRecording(plan.recordingID) }
        let runs = try Self.ownDirectory(recording.appendingPathComponent(Self.runsDirectoryName, isDirectory: true))
        let file = runs.appendingPathComponent(plan.runID + Self.runPlanSuffix)
        guard !BoundedRead.exists(file) else { throw ProjectStoreError.alreadyExists(file) }
        try AtomicFile.write(try ContractJSON.encoder().encode(plan), to: file)
    }

    /// The recording's run plans that pass `RunPlan.problem`, by run index, and how many
    /// files were skipped. A recording without `runs/` (any non-protocol recording) has none.
    public func runPlans(recording id: UUID) throws -> (plans: [RunPlan], unreadable: Int) {
        let runs = recordingDirectory(id).appendingPathComponent(Self.runsDirectoryName, isDirectory: true)
        var st = stat()
        guard lstat(runs.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return ([], 0) }
        let names = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter {
            $0.hasSuffix(Self.runPlanSuffix) && !$0.hasPrefix(AtomicFile.tempPrefix)
        }
        let plans = names.compactMap { name -> RunPlan? in
            let runID = String(name.dropLast(Self.runPlanSuffix.count))
            guard let data = BoundedRead.data(at: runs.appendingPathComponent(name), maxBytes: RunPlan.maxFileBytes),
                  let plan = try? ContractJSON.decoder().decode(RunPlan.self, from: data),
                  plan.problem(recordingID: id, fileRunID: runID) == nil else { return nil }
            return plan
        }
        return (plans.sorted { ($0.runIndex, $0.runID) < ($1.runIndex, $1.runID) }, names.count - plans.count)
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
