import Foundation

/// `live.json` in an export (brief 006 PR 9): the frozen models and live runs that belong to
/// the exported result, copied byte for byte (docs/export-format.md, "Frozen models and live
/// runs"). Written only when the project has a `models/` or `live/` entry to report.
public struct ExportedLiveEvidence: Codable, Sendable, Equatable {
    public var models: [ModelFile]
    public var liveRuns: [LiveRunFiles]
    /// `models/<uuid>/` folders in the project whose `model.json` couldn't be read or failed
    /// validation (counted project-wide: an unreadable model can't be attributed to a result).
    public var unreadableModels: Int
    /// Valid models that belong to this export but whose arrays are missing, over 4 MB, or no
    /// longer hash to `fittedSHA256` ("model file changed since it was frozen"). Not copied.
    public var unverifiedModels: [UUID]
    /// `live/<uuid>/` folders in the project whose `run.json` or logs couldn't be read or
    /// failed validation (project-wide, as for models).
    public var unreadableLiveRuns: Int
    /// Valid live runs that belong to this export but whose model couldn't be exported.
    public var unverifiedLiveRuns: [UUID]

    public struct ModelFile: Codable, Sendable, Equatable {
        public var file: String                    // models/<uuid>/model.json
        public var modelID: UUID
        public var name: String
        public var role: ModelRole
        public var sourceResultID: UUID
        public var sourceRecordingID: UUID
        /// arrays/<fittedSHA256>.npz: the source pipeline's `fitted.npz`, named by its hash.
        public var arrays: String
        public var fittedSHA256: String
        public var sha256: String                  // of the exported model.json bytes
    }

    public struct LiveRunFiles: Codable, Sendable, Equatable {
        public var liveRunID: UUID
        public var kind: LiveRunRecord.Kind
        public var modelID: UUID
        public var recordingID: UUID
        /// Whether the run's recording is this export's recording (its samples are in the
        /// `segment-*.f64` files); false for a run of a model frozen from this result on
        /// another recording, whose samples are not in the folder.
        public var recordingIncluded: Bool
        public var run: LogFile
        public var predictions: LogFile
        /// Live runs always; a replay has no feedback log.
        public var feedback: LogFile?
    }

    public struct LogFile: Codable, Sendable, Equatable {
        public var file: String
        public var sha256: String
        /// Records in a `.jsonl` log; nil for `run.json`.
        public var records: Int?
        /// The last line was cut off mid-write (a crash); readers drop it, as the app does.
        public var lastLineTruncated: Bool?
    }
}

extension ProjectStore {
    public static let liveExportFileName = "live.json"

    /// Selection rule: the models frozen from `stored` (decision #38: its own fits), the live
    /// runs and replays recorded on or replayed over the exported recording, the live runs of
    /// the models frozen here wherever they ran, and every model those runs used. Each file is
    /// read once with a size cap and validated, and those bytes are what is written. A model
    /// whose arrays changed and any run whose model can't be exported are skipped and listed.
    /// Nil when the project has no `models/` or `live/` entries at all.
    func writeLiveEvidence(for stored: StoredResult, into out: URL) throws -> ExportedLiveEvidence? {
        let models = readExportChildren("models", file: Self.modelFileName, maxBytes: ModelRecord.maxFileBytes, as: ModelRecord.self) { $0.problem(directoryID: $1) }
        let runs = readExportChildren("live", file: Self.liveRunFileName, maxBytes: LiveRunRecord.maxFileBytes, as: LiveRunRecord.self) { $0.problem(directoryID: $1) }
        guard models.found > 0 || runs.found > 0 else { return nil }
        let recordingID = stored.meta.recordingID
        let byID = Dictionary(models.valid.map { ($0.record.modelID, ($0.record, $0.bytes)) }, uniquingKeysWith: { a, _ in a })
        let frozenHere = Set(models.valid.filter { $0.record.sourceResultID == stored.meta.resultID }.map(\.record.modelID))
        let selectedRuns = runs.valid.filter { $0.record.recordingID == recordingID || frozenHere.contains($0.record.modelID) }
        let wanted = frozenHere.union(selectedRuns.map(\.record.modelID))

        var exported: [UUID: ExportedLiveEvidence.ModelFile] = [:]
        var unverifiedModels: [UUID] = []
        for id in wanted.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let (model, bytes) = byID[id] else { continue }   // missing or unreadable: its runs are unverified
            guard let arrays = verifiedArrays(model) else { unverifiedModels.append(id); continue }
            let arraysName = "arrays/\(model.fittedSHA256).npz"
            try Self.writeNew(arrays, to: out.appendingPathComponent(arraysName), skipIfPresent: true)
            let file = "models/\(id.uuidString)/\(Self.modelFileName)"
            try Self.writeNew(bytes, to: out.appendingPathComponent(file))
            exported[id] = .init(file: file, modelID: id, name: model.name, role: model.role, sourceResultID: model.sourceResultID,
                                 sourceRecordingID: model.sourceRecordingID, arrays: arraysName, fittedSHA256: model.fittedSHA256,
                                 sha256: AtomicFile.sha256Hex(bytes))
        }

        var liveRuns: [ExportedLiveEvidence.LiveRunFiles] = []
        var unverifiedRuns: [UUID] = []
        var unreadableRuns = runs.found - runs.valid.count
        for (run, runBytes, dir) in selectedRuns.sorted(by: { $0.record.liveRunID.uuidString < $1.record.liveRunID.uuidString }) {
            guard exported[run.modelID] != nil else { unverifiedRuns.append(run.liveRunID); continue }
            // The logs are read from the exact folder whose run.json was checked, and only if it
            // is still a real directory inside a real `live/` (not swapped for a link since).
            guard Self.isRealDirectory(dir.deletingLastPathComponent()), Self.isRealDirectory(dir) else { unreadableRuns += 1; continue }
            guard case .read(let predictions) = Self.readLog(dir, Self.predictionsFileName, as: PredictionRecord.self) else { unreadableRuns += 1; continue }
            let feedback = Self.readLog(dir, Self.feedbackFileName, as: FeedbackRecord.self)
            if case .unreadable = feedback { unreadableRuns += 1; continue }
            if case .absent = feedback, run.kind == .live { unreadableRuns += 1; continue }
            let base = "live/\(run.liveRunID.uuidString)"
            func copy(_ name: String, _ log: Log?) throws -> ExportedLiveEvidence.LogFile {
                let bytes = log?.bytes ?? runBytes
                try Self.writeNew(bytes, to: out.appendingPathComponent("\(base)/\(name)"))
                return .init(file: "\(base)/\(name)", sha256: AtomicFile.sha256Hex(bytes), records: log?.records, lastLineTruncated: log?.truncated)
            }
            var feedbackFile: ExportedLiveEvidence.LogFile?
            if case .read(let log) = feedback { feedbackFile = try copy(Self.feedbackFileName, log) }
            liveRuns.append(.init(liveRunID: run.liveRunID, kind: run.kind, modelID: run.modelID, recordingID: run.recordingID,
                                  recordingIncluded: run.recordingID == recordingID, run: try copy(Self.liveRunFileName, nil),
                                  predictions: try copy(Self.predictionsFileName, predictions), feedback: feedbackFile))
        }
        let evidence = ExportedLiveEvidence(models: exported.values.sorted { $0.modelID.uuidString < $1.modelID.uuidString }, liveRuns: liveRuns,
                                            unreadableModels: models.found - models.valid.count, unverifiedModels: unverifiedModels,
                                            unreadableLiveRuns: unreadableRuns, unverifiedLiveRuns: unverifiedRuns)
        try ContractJSON.encoder().encode(evidence).write(to: out.appendingPathComponent(Self.liveExportFileName))
        return evidence
    }

    /// The model's arrays read once (4 MB cap, never through a link, the pipeline directory a
    /// real one), or nil when they're missing or no longer hash to what was frozen.
    private func verifiedArrays(_ model: ModelRecord) -> Data? {
        let pipelines = directory.appendingPathComponent("pipelines", isDirectory: true)
        guard Self.isRealDirectory(pipelines), Self.isRealDirectory(pipelines.appendingPathComponent(model.sourcePipelineID.uuidString)),
              let bytes = BoundedRead.data(at: fittedArraysURL(pipelineID: model.sourcePipelineID), maxBytes: Self.fittedArraysBytes),
              AtomicFile.sha256Hex(bytes) == model.fittedSHA256 else { return nil }
        return bytes
    }

    /// Valid children of `models/` or `live/` with their exact bytes, and how many child
    /// entries there were. A parent that is a link or not a directory counts as one entry,
    /// so it is reported rather than followed. Only UUID-named entries count (temp folders and
    /// stray files are not children); a linked child is counted and never read.
    private func readExportChildren<T: Decodable>(_ child: String, file: String, maxBytes: Int, as: T.Type,
                                                  problem: (T, UUID) -> String?) -> (valid: [(record: T, bytes: Data, dir: URL)], found: Int) {
        let parent = directory.appendingPathComponent(child, isDirectory: true)
        guard BoundedRead.exists(parent) else { return ([], 0) }
        guard Self.isRealDirectory(parent), let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return ([], 1) }
        var valid: [(record: T, bytes: Data, dir: URL)] = []
        var found = 0
        for name in names.sorted() {
            guard let id = UUID(uuidString: name) else { continue }   // temp folders and stray files are not entries
            found += 1
            // Only the canonical (upper-case) spelling the store writes: any other spelling is
            // counted as unreadable, so every later read uses exactly this checked folder.
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            guard name == id.uuidString, Self.isRealDirectory(dir),
                  let data = BoundedRead.data(at: dir.appendingPathComponent(file), maxBytes: maxBytes),
                  let record = try? ContractJSON.decoder().decode(T.self, from: data), problem(record, id) == nil else { continue }
            valid.append((record, data, dir))
        }
        return (valid, found)
    }

    struct Log { var bytes: Data; var records: Int; var truncated: Bool }
    enum LogRead { case absent, unreadable, read(Log) }

    /// One `.jsonl` log read once (64 MB cap, never through a link) and checked line by line:
    /// unreadable when it isn't a regular file within the cap or has a bad line anywhere but a
    /// cut-off last one.
    private static func readLog<R: Decodable & Sendable>(_ dir: URL, _ name: String, as: R.Type) -> LogRead {
        let url = dir.appendingPathComponent(name)
        guard BoundedRead.exists(url) else { return .absent }
        guard let bytes = BoundedRead.data(at: url, maxBytes: liveLogBytes),
              let lines = try? JSONLines<R>.parse(bytes, name: name) else { return .unreadable }
        return .read(Log(bytes: bytes, records: lines.records.count, truncated: lines.lastLineTruncated))
    }

    /// Writes `data` at `url`, creating its folder; never overwrites (two ids that differ only
    /// in case would collide on APFS, and the export refuses rather than drop one).
    private static func writeNew(_ data: Data, to url: URL, skipIfPresent: Bool = false) throws {
        if skipIfPresent, BoundedRead.exists(url) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
    }
}
