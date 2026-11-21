import Foundation

// Frozen models (`models/<uuid>/model.json`) and live runs and replays (`live/<uuid>/`),
// brief 006. Models and replays are written once (temp directory → fsync → rename); a live
// run's `run.json` is rewritten once at its end, and its `.jsonl` logs are append-only.
extension ProjectStore {
    public static let modelFileName = "model.json"
    public static let liveRunFileName = "run.json"
    public static let predictionsFileName = "predictions.jsonl"
    public static let feedbackFileName = "feedback.jsonl"
    /// Largest `.jsonl` log read: 8 predictions a second for hours fits comfortably.
    public static let liveLogBytes = 64 * 1024 * 1024
    /// The worker refuses a larger `fitted.npz` (project_io `MAX_MODEL_FILE_BYTES`).
    static let fittedArraysBytes = 4 * 1024 * 1024

    // MARK: Models

    /// Freezes one fit of an evaluation (decision #38: the evaluation's own fit on its
    /// training runs). `validation` is the worker's `validate_model` summary of the same
    /// file; the bytes are hashed again here and must still match it. Refused when the
    /// result doesn't name `pipeline`, the arrays don't fit the pipeline, or this fit is
    /// already frozen. Nothing is copied: the model names the arrays by hash.
    @discardableResult
    public func freeze(pipeline pipelineID: UUID, result resultID: UUID, role: ModelRole, name: String,
                       validation: ModelValidation, now: Date = Date()) throws -> ModelRecord {
        let stored = try result(id: resultID)
        guard stored.meta.pipelineID == pipelineID else { throw ProjectStoreError.invalidModel("the result was not produced by this pipeline") }
        let p = stored.pipeline
        guard let bytes = BoundedRead.data(at: fittedArraysURL(pipelineID: pipelineID), maxBytes: Self.fittedArraysBytes) else {
            throw ProjectStoreError.invalidModel("the pipeline's fitted arrays are missing or larger than 4 MB")
        }
        let digest = AtomicFile.sha256Hex(bytes)
        guard digest == validation.sha256.lowercased() else { throw ProjectStoreError.invalidModel("model file changed since it was validated") }
        if let existing = try models().models.first(where: { $0.sourcePipelineID == pipelineID && $0.role == role }) {
            throw ProjectStoreError.invalidModel("this fit is already frozen as \u{201C}\(existing.name)\u{201D}")
        }
        let c = p.configuration
        guard let offset = c["window_offset_s"].flatMap(Double.init), let length = c["window_length_s"].flatMap(Double.init),
              let low = c["bandpass_low_hz"].flatMap(Double.init), let high = c["bandpass_high_hz"].flatMap(Double.init),
              let order = c["bandpass_order"].flatMap(Int.init), let left = c["label_left"], let right = c["label_right"] else {
            throw ProjectStoreError.invalidModel("the pipeline configuration lacks its window, band-pass or labels")
        }
        guard validation.nChannels == p.expectedChannelIDs.count else {
            throw ProjectStoreError.invalidModel("the arrays expect \(validation.nChannels) channels, the pipeline \(p.expectedChannelIDs.count)")
        }
        let labels = [left, right]
        // The evaluation fits {left: 0, right: 1}; anything else is not this evaluation's model.
        guard validation.ldaClasses == [0, 1] else {
            throw ProjectStoreError.invalidModel("the arrays' classes are \(validation.ldaClasses), not the evaluation's [0, 1]")
        }
        guard validation.model == role.rawValue else {
            throw ProjectStoreError.invalidModel("the validation describes the \(validation.model) model, not the \(role.rawValue)")
        }
        let recipe = role == .reference ? p.recipe : (c["baseline"] ?? "baseline")
        // Training runs from the stored split manifest; their sessions from the recording.
        struct Split: Decodable { let training_runs: [String] }
        let runs = (try? JSONDecoder().decode(Split.self, from: Data(p.splitManifest.utf8)))?.training_runs ?? []
        let segments = try recording(id: stored.meta.recordingID).manifest.segments
        let sessions = try runs.map { run -> String? in
            guard let seg = segments.first(where: { $0.runID == run }) else {
                throw ProjectStoreError.invalidModel("training run \(run) is not in the source recording")
            }
            return seg.sessionID
        }
        let record = ModelRecord(
            modelID: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), sourcePipelineID: pipelineID, sourceResultID: resultID,
            sourceRecordingID: stored.meta.recordingID, role: role, recipe: recipe, featureKind: validation.featureKind,
            expectedChannelIDs: p.expectedChannelIDs, expectedSampleRateHz: p.expectedSampleRateHz,
            bandpass: .init(lowHz: low, highHz: high, order: order), window: .init(offsetSeconds: offset, lengthSeconds: length),
            warmupSamples: validation.filterWarmupSamples, classLabels: labels,
            trainingRunIDs: runs, trainingSessionIDs: sessions, fittedSHA256: digest, configHash: p.configHash,
            workerVersions: stored.meta.workerVersions, frozenAt: now)
        if let problem = record.problem(directoryID: record.modelID) { throw ProjectStoreError.invalidModel(problem) }
        try writeOnce(child: "models", id: record.modelID, files: [Self.modelFileName: try ContractJSON.encoder().encode(record)])
        return record
    }

    /// Stored models that pass `ModelRecord.problem`, newest first, and how many were skipped.
    public func models() throws -> (models: [ModelRecord], unreadable: Int) {
        let (records, skipped) = try readChildren("models", file: Self.modelFileName, maxBytes: ModelRecord.maxFileBytes, as: ModelRecord.self) {
            $0.problem(directoryID: $1)
        }
        return (records.sorted { ($0.frozenAt, $0.modelID.uuidString) > ($1.frozenAt, $1.modelID.uuidString) }, skipped)
    }

    /// The model's arrays: always the source pipeline's `fitted.npz`, built from its id.
    public func arraysURL(for model: ModelRecord) -> URL { fittedArraysURL(pipelineID: model.sourcePipelineID) }

    // MARK: Live runs and replays

    /// Starts a live run: writes `live/<uuid>/run.json` and returns the writer for its logs.
    public func createLiveRun(_ record: LiveRunRecord, logLimit: Int = ProjectStore.liveLogBytes) throws -> LiveRunWriter {
        guard record.kind == .live, record.endedAt == nil else { throw ProjectStoreError.invalidModel("not a live run in progress") }
        if let problem = record.problem(directoryID: record.liveRunID) { throw ProjectStoreError.invalidModel(problem) }
        let parent = try Self.ownDirectory(directory.appendingPathComponent("live", isDirectory: true))
        let dir = parent.appendingPathComponent(record.liveRunID.uuidString, isDirectory: true)
        guard !BoundedRead.exists(dir) else { throw ProjectStoreError.alreadyExists(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        // Both logs exist (empty, fsynced) before the directory entry is synced, so a crash
        // can never lose a log file whose lines were each fsynced.
        for name in [Self.predictionsFileName, Self.feedbackFileName] {
            try AtomicFile.writeAndSync(Data(), to: dir.appendingPathComponent(name), fresh: true)
        }
        try AtomicFile.write(try ContractJSON.encoder().encode(record), to: dir.appendingPathComponent(Self.liveRunFileName))
        try AtomicFile.syncDirectory(parent)
        return LiveRunWriter(directory: dir, record: record, logLimit: logLimit)
    }

    /// Stores a replay with its predictions as one immutable directory (complete or absent).
    public func storeReplay(_ record: LiveRunRecord, predictions: [PredictionRecord]) throws {
        guard record.kind == .replay else { throw ProjectStoreError.invalidModel("not a replay") }
        if let problem = record.problem(directoryID: record.liveRunID) { throw ProjectStoreError.invalidModel(problem) }
        let encoder = ContractJSON.lineEncoder()
        var lines = Data()
        for p in predictions { lines.append(try encoder.encode(p)); lines.append(0x0A) }
        try writeOnce(child: "live", id: record.liveRunID, files: [Self.liveRunFileName: try ContractJSON.encoder().encode(record),
                                                                  Self.predictionsFileName: lines])
    }

    /// Live runs and replays that pass `LiveRunRecord.problem`, newest first, and how many were skipped.
    public func liveRuns() throws -> (runs: [LiveRunRecord], unreadable: Int) {
        let (records, skipped) = try readChildren("live", file: Self.liveRunFileName, maxBytes: LiveRunRecord.maxFileBytes, as: LiveRunRecord.self) {
            $0.problem(directoryID: $1)
        }
        return (records.sorted { ($0.startedAt, $0.liveRunID.uuidString) > ($1.startedAt, $1.liveRunID.uuidString) }, skipped)
    }

    /// Live runs (not replays) that used `model`: the Pipelines list's "used in n live runs".
    public func liveRunCount(model: UUID) throws -> Int {
        try liveRuns().runs.filter { $0.kind == .live && $0.modelID == model }.count
    }

    public func predictions(liveRun id: UUID) throws -> JSONLines<PredictionRecord> {
        try JSONLines.read(liveRunDirectory(id).appendingPathComponent(Self.predictionsFileName), maxBytes: Self.liveLogBytes)
    }

    public func feedback(liveRun id: UUID) throws -> JSONLines<FeedbackRecord> {
        try JSONLines.read(liveRunDirectory(id).appendingPathComponent(Self.feedbackFileName), maxBytes: Self.liveLogBytes)
    }

    nonisolated func liveRunDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("live").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Internals

    /// `<child>/<id>/` with `files`, assembled as `.tmp-<id>`, fsynced and renamed into place.
    private func writeOnce(child: String, id: UUID, files: [String: Data]) throws {
        let parent = try Self.ownDirectory(directory.appendingPathComponent(child, isDirectory: true))
        let dir = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !BoundedRead.exists(dir) else { throw ProjectStoreError.alreadyExists(dir) }
        let tmp = AtomicFile.tempURL(for: dir)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
            for (name, data) in files.sorted(by: { $0.key < $1.key }) {
                try AtomicFile.writeAndSync(data, to: tmp.appendingPathComponent(name), fresh: true)
            }
            try AtomicFile.syncTree(tmp)
            try AtomicFile.rename(tmp, to: dir)
            try AtomicFile.syncDirectory(parent)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private func readChildren<T: Decodable>(_ child: String, file: String, maxBytes: Int, as: T.Type,
                                            problem: (T, UUID) -> String?) throws -> ([T], Int) {
        let parent = directory.appendingPathComponent(child, isDirectory: true)
        guard BoundedRead.exists(parent) else { return ([], 0) }
        let ids = try childIDs(in: child, requiring: file)
        let records = ids.compactMap { id -> T? in
            guard let data = BoundedRead.data(at: parent.appendingPathComponent(id.uuidString).appendingPathComponent(file), maxBytes: maxBytes),
                  let r = try? ContractJSON.decoder().decode(T.self, from: data), problem(r, id) == nil else { return nil }
            return r
        }
        return (records, ids.count - records.count)
    }
}

/// The worker's `validate_model` summary (worker/pipeline.py `validate_model_arrays`).
public struct ModelValidation: Decodable, Sendable, Equatable {
    public var model: String
    public var featureKind: String
    public var nChannels: Int
    public var nFeatures: Int
    public var filterWarmupSamples: Int
    public var ldaClasses: [Int]
    public var sha256: String

    public init(model: String, featureKind: String, nChannels: Int, nFeatures: Int, filterWarmupSamples: Int, ldaClasses: [Int], sha256: String) {
        self.model = model; self.featureKind = featureKind; self.nChannels = nChannels; self.nFeatures = nFeatures
        self.filterWarmupSamples = filterWarmupSamples; self.ldaClasses = ldaClasses; self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case model, sha256
        case featureKind = "feature_kind", nChannels = "n_channels", nFeatures = "n_features"
        case filterWarmupSamples = "filter_warmup_samples", ldaClasses = "lda_classes"
    }
}

/// Appends to one live run's logs. Each record is one `write` of one line, fsynced before
/// the call returns (the `events.jsonl` rule), and nothing is ever rewritten; `finish`
/// rewrites `run.json` once with the summaries. An actor, so logging never runs on the
/// main thread and two lines never interleave.
public actor LiveRunWriter {
    public nonisolated let directory: URL
    public private(set) var record: LiveRunRecord
    /// Set once a log reached `ProjectStore.liveLogBytes`: nothing more is logged (every
    /// later append throws), and `finish` stores the reason, so the logs stay readable.
    public private(set) var loggingStopped: String?
    private var nextSequence = 0
    private var bytes: [String: Int] = [:]
    /// The reader's cap (`ProjectStore.liveLogBytes`); smaller only in tests.
    private let logLimit: Int

    init(directory: URL, record: LiveRunRecord, logLimit: Int) {
        self.directory = directory
        self.record = record
        self.logLimit = logLimit
    }

    /// Appends `prediction` with the next sequence number and returns that number.
    @discardableResult
    public func append(_ prediction: PredictionRecord) throws -> Int {
        var p = prediction
        p.sequence = nextSequence
        try append(try ContractJSON.lineEncoder().encode(p), to: ProjectStore.predictionsFileName)
        nextSequence += 1
        return p.sequence!
    }

    public func append(_ feedback: FeedbackRecord) throws {
        try append(try ContractJSON.lineEncoder().encode(feedback), to: ProjectStore.feedbackFileName)
    }

    private func append(_ json: Data, to name: String) throws {
        if let loggingStopped { throw ProjectStoreError.logFull(loggingStopped) }
        let size = bytes[name, default: 0] + json.count + 1
        guard size <= logLimit else {
            let reason = "\(name) reached its size limit (\(logLimit) bytes); nothing was logged after that"
            loggingStopped = reason
            throw ProjectStoreError.logFull(reason)
        }
        try AppendOnlyFile.appendLine(json, to: directory.appendingPathComponent(name))
        bytes[name] = size
    }

    /// The one rewrite of `run.json`: the same run with `endedAt` and its summaries, and the
    /// runs it covered when they were only known at the end.
    public func finish(endedAt: Date, summary: LiveRunRecord.Summary?, latency: LiveRunRecord.LatencySummary?,
                       replayCheck: LiveRunRecord.ReplayCheck?, runIDs: [String]? = nil) throws {
        guard record.endedAt == nil else { throw ProjectStoreError.invalidModel("the live run is already finished") }
        var r = record
        r.endedAt = endedAt; r.summary = summary; r.latency = latency; r.replayCheck = replayCheck
        if let runIDs { r.runIDs = Array(runIDs.prefix(1_000)) }
        r.loggingStopped = loggingStopped
        try AtomicFile.write(try ContractJSON.encoder().encode(r), to: directory.appendingPathComponent(ProjectStore.liveRunFileName))
        record = r
    }
}

/// One `.jsonl` log read back. A last line cut off mid-write (no newline, not decodable) is
/// dropped and flagged; any other line that fails to decode is an error.
public struct JSONLines<T: Decodable & Sendable>: Sendable {
    public var records: [T]
    public var lastLineTruncated: Bool

    static func read(_ url: URL, maxBytes: Int) throws -> JSONLines<T> {
        guard BoundedRead.exists(url) else { return JSONLines(records: [], lastLineTruncated: false) }
        guard let data = BoundedRead.data(at: url, maxBytes: maxBytes) else {
            throw ProjectStoreError.invalidManifest("\(url.lastPathComponent) is not a regular file of at most \(maxBytes / 1_048_576) MB")
        }
        let decoder = ContractJSON.decoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var out: [T] = []
        var truncated = false
        for (i, line) in lines.enumerated() where !line.isEmpty {
            if let r = try? decoder.decode(T.self, from: line) {
                out.append(r)
            } else if i == lines.count - 1, data.last != 0x0A {
                truncated = true
            } else {
                throw ProjectStoreError.invalidManifest("\(url.lastPathComponent) line \(i + 1) is not a record")
            }
        }
        return JSONLines(records: out, lastLineTruncated: truncated)
    }
}

/// Append-only `.jsonl` files (`events.jsonl`, `predictions.jsonl`, `feedback.jsonl`): one
/// `write` per line with `O_APPEND`, never through a symbolic link, then a full fsync.
enum AppendOnlyFile {
    /// Test seam: write only `afterBytes` of the line, then fail with `errno`.
    struct Fault: Sendable { var afterBytes: Int; var errno: Int32 }

    /// Appends `json` plus a newline, looping over short writes. On any failure the file is
    /// truncated back to its size before the call, so a failed append leaves no partial
    /// line mid-file (only a crash can leave one, and only at the end).
    static func appendLine(_ json: Data, to url: URL, fault: Fault? = nil) throws {
        var line = json
        line.append(0x0A)
        let name = url.lastPathComponent
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProjectStoreError.io("open \(name)", errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ProjectStoreError.io("fstat \(name)", errno) }
        do {
            try line.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buf.count {
                    var want = buf.count - offset
                    if let fault { want = min(want, max(0, fault.afterBytes - offset)) }
                    if want == 0, let fault { throw ProjectStoreError.io("append \(name) (injected)", fault.errno) }
                    let n = Foundation.write(fd, buf.baseAddress! + offset, want)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw ProjectStoreError.io("append \(name)", errno)
                    }
                    offset += n
                }
            }
            try AtomicFile.fullSync(fd, name)
        } catch {
            _ = ftruncate(fd, st.st_size)
            _ = try? AtomicFile.fullSync(fd, name)
            throw error
        }
    }
}
