import Foundation

/// One open `.bciproj` directory (docs/data-contracts.md, "Project directory").
///
/// The directory scan is the truth: recordings, pipelines and results are whatever
/// `recordings/<uuid>/recording.json`, `pipelines/<uuid>/pipeline.json` and
/// `results/<uuid>/result.meta.json` exist on disk. There is no index file in this
/// version (the `index.sqlite` the contract reserves is not written), so nothing can
/// disagree with the files. Everything under those directories is immutable once its
/// directory has been renamed into place; new versions are new directories.
///
/// An actor so concurrent callers (the evaluation runner storing a result while the UI
/// lists recordings) serialize on one directory. All file I/O is synchronous inside.
public actor ProjectStore {
    public static let projectFileName = "project.json"
    public static let recordingFileName = "recording.json"
    public static let eventsFileName = "events.jsonl"
    public static let pipelineFileName = "pipeline.json"
    public static let fittedFileName = "fitted.npz"
    public static let evaluationFileName = "evaluation.json"
    public static let resultMetaFileName = "result.meta.json"

    public nonisolated let directory: URL
    public private(set) var manifest: ProjectManifest
    /// Temp files and directories deleted by `open`, by name, for the log and for tests.
    public private(set) var removedOrphans: [String] = []

    private let fm = FileManager.default

    private init(directory: URL, manifest: ProjectManifest, removedOrphans: [String] = []) {
        self.directory = directory
        self.manifest = manifest
        self.removedOrphans = removedOrphans
    }

    // MARK: Lifecycle

    /// Creates an empty project directory. Refuses to touch an existing path.
    public static func create(at url: URL, name: String, now: Date = Date()) throws -> ProjectStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw ProjectStoreError.alreadyExists(url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for child in ["recordings", "pipelines", "results"] {
            try fm.createDirectory(at: url.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: false)
        }
        let manifest = ProjectManifest(name: name, created: now)
        try AtomicFile.write(try ContractJSON.encoder().encode(manifest), to: url.appendingPathComponent(projectFileName))
        return ProjectStore(directory: url, manifest: manifest)
    }

    /// Opens an existing project: validates the format version, deletes orphaned temp
    /// files left by a crash, and returns. Chunk hashes are *not* verified here (that is
    /// `verify(recording:)`, on demand); opening stays cheap for large projects.
    public static func open(at url: URL) throws -> ProjectStore {
        let fm = FileManager.default
        let manifest = try readManifest(at: url)
        for child in ["recordings", "pipelines", "results"] {
            let dir = url.appendingPathComponent(child, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        }
        return ProjectStore(directory: url, manifest: manifest, removedOrphans: try removeOrphans(in: url))
    }

    /// Copies the example project bundled with the app into `destination`, verifying
    /// every chunk against its manifest hash on the way, so a damaged bundle is refused
    /// before the user ever sees a project. Reads only from `source`; nothing else.
    public static func importBundledExample(from source: URL, into destination: URL, name: String? = nil, now: Date = Date()) throws -> ProjectStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectStoreError.alreadyExists(destination) }
        // The bundle is read-only, so open it without the orphan sweep a writable project gets.
        let bundled = try readManifest(at: source)
        let store = try create(at: destination, name: name ?? bundled.name, now: now)
        for id in try childIDs(in: source, child: "recordings", requiring: recordingFileName) {
            let src = recordingDirectory(in: source, id)
            let dst = recordingDirectory(in: destination, id)
            let staging = AtomicFile.tempURL(for: dst)
            try fm.copyItem(at: src, to: staging)
            let handle = try RecordingHandle(directory: staging)
            let issues = handle.verify()
            guard issues.isEmpty else {
                try? fm.removeItem(at: staging)
                throw ProjectStoreError.integrity(issues)
            }
            try AtomicFile.rename(staging, to: dst)
        }
        try AtomicFile.syncDirectory(destination.appendingPathComponent("recordings"))
        // The README inside the example carries the license text; keep it with the copy.
        let readme = source.appendingPathComponent("README.md")
        if fm.fileExists(atPath: readme.path) {
            try fm.copyItem(at: readme, to: destination.appendingPathComponent("README.md"))
        }
        return store
    }

    // MARK: Recordings

    public func recordingIDs() throws -> [UUID] {
        try childIDs(in: "recordings", requiring: Self.recordingFileName)
    }

    public func recording(id: UUID) throws -> RecordingHandle {
        let dir = recordingDirectory(id)
        guard fm.fileExists(atPath: dir.appendingPathComponent(Self.recordingFileName).path) else { throw ProjectStoreError.missingRecording(id) }
        return try RecordingHandle(directory: dir)
    }

    public func events(for id: UUID) throws -> [EventRecord] {
        try recording(id: id).events()
    }

    /// Reads every chunk of the recording and checks its hash and size. Reports; never repairs.
    public func verify(recording id: UUID) throws -> [IntegrityIssue] {
        try recording(id: id).verify()
    }

    /// Starts a new recording: writes its directory and manifest (with no chunks yet) and
    /// returns the writer that appends chunks and events. `hook` is the crash-test seam.
    public func createRecording(_ manifest: RecordingManifest, hook: CommitHook? = nil) throws -> ChunkWriter {
        let dir = recordingDirectory(manifest.recordingID)
        guard !fm.fileExists(atPath: dir.path) else { throw ProjectStoreError.alreadyExists(dir) }
        var initial = manifest
        initial.chunks = []
        try fm.createDirectory(at: dir.appendingPathComponent("chunks", isDirectory: true), withIntermediateDirectories: true)
        try AtomicFile.write(try ContractJSON.encoder().encode(initial), to: dir.appendingPathComponent(Self.recordingFileName))
        try AtomicFile.syncDirectory(dir)
        return ChunkWriter(directory: dir, manifest: initial, hook: hook)
    }

    // MARK: Pipelines and results

    /// A fresh `pipelines/.tmp-<uuid>` directory a caller (the worker, via the runner)
    /// may fill before `storeResult` renames it into place. Removed on the next `open`
    /// if abandoned.
    public func stagingDirectory() throws -> URL {
        let url = directory.appendingPathComponent("pipelines").appendingPathComponent(AtomicFile.tempPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Commits one evaluation: the pipeline record and its fitted arrays under
    /// `pipelines/<pipelineID>/`, then `evaluation.json` (bytes untouched) and
    /// `result.meta.json` under `results/<resultID>/`. Each directory is assembled as
    /// `.tmp-<uuid>` and renamed into place, so a crash leaves a temp directory (deleted on
    /// open) or a complete result, never a half-written one. `fittedArraysFile` is moved.
    public func storeResult(evaluationJSON: Data, meta: ResultMeta, pipeline: PipelineRecord, fittedArraysFile: URL) throws -> UUID {
        precondition(meta.pipelineID == pipeline.pipelineID, "result meta must name its pipeline")
        precondition(meta.evaluationSHA256 == AtomicFile.sha256Hex(evaluationJSON), "meta must hash the bytes being stored")
        var pipeline = pipeline
        pipeline.fittedParametersFile = Self.fittedFileName

        let pipelineDir = directory.appendingPathComponent("pipelines").appendingPathComponent(pipeline.pipelineID.uuidString, isDirectory: true)
        let pipelineTmp = AtomicFile.tempURL(for: pipelineDir)
        try fm.createDirectory(at: pipelineTmp, withIntermediateDirectories: false)
        try AtomicFile.rename(fittedArraysFile, to: pipelineTmp.appendingPathComponent(Self.fittedFileName))
        try AtomicFile.writeAndSync(try ContractJSON.encoder().encode(pipeline), to: pipelineTmp.appendingPathComponent(Self.pipelineFileName))
        try AtomicFile.syncDirectory(pipelineTmp)
        try AtomicFile.rename(pipelineTmp, to: pipelineDir)
        try AtomicFile.syncDirectory(pipelineDir.deletingLastPathComponent())
        // The worker's staging directory is now empty; drop it.
        try? fm.removeItem(at: fittedArraysFile.deletingLastPathComponent())

        let resultDir = resultDirectory(meta.resultID)
        let resultTmp = AtomicFile.tempURL(for: resultDir)
        try fm.createDirectory(at: resultTmp, withIntermediateDirectories: false)
        try AtomicFile.writeAndSync(evaluationJSON, to: resultTmp.appendingPathComponent(Self.evaluationFileName))
        try AtomicFile.writeAndSync(try ContractJSON.encoder().encode(meta), to: resultTmp.appendingPathComponent(Self.resultMetaFileName))
        try AtomicFile.syncDirectory(resultTmp)
        try AtomicFile.rename(resultTmp, to: resultDir)
        try AtomicFile.syncDirectory(resultDir.deletingLastPathComponent())
        return meta.resultID
    }

    /// Every complete result, oldest first by `result.meta.json` creation time.
    public func results() throws -> [ResultMeta] {
        try childIDs(in: "results", requiring: Self.resultMetaFileName)
            .map { try resultMeta($0) }
            .sorted { ($0.createdAt, $0.resultID.uuidString) < ($1.createdAt, $1.resultID.uuidString) }
    }

    public func result(id: UUID) throws -> StoredResult {
        let meta = try resultMeta(id)
        guard let evaluation = fm.contents(atPath: resultDirectory(id).appendingPathComponent(Self.evaluationFileName).path) else {
            throw ProjectStoreError.missingResult(id)
        }
        return StoredResult(meta: meta, evaluationJSON: evaluation, pipeline: try pipeline(id: meta.pipelineID))
    }

    public func pipelineIDs() throws -> [UUID] {
        try childIDs(in: "pipelines", requiring: Self.pipelineFileName)
    }

    public func pipeline(id: UUID) throws -> PipelineRecord {
        let url = directory.appendingPathComponent("pipelines").appendingPathComponent(id.uuidString).appendingPathComponent(Self.pipelineFileName)
        guard let data = fm.contents(atPath: url.path) else { throw ProjectStoreError.missingPipeline(id) }
        return try ContractJSON.decoder().decode(PipelineRecord.self, from: data)
    }

    public func fittedArraysURL(pipelineID: UUID) -> URL {
        directory.appendingPathComponent("pipelines").appendingPathComponent(pipelineID.uuidString).appendingPathComponent(Self.fittedFileName)
    }

    // MARK: Paths

    nonisolated func recordingDirectory(_ id: UUID) -> URL { Self.recordingDirectory(in: directory, id) }

    nonisolated func resultDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("results").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func recordingDirectory(in project: URL, _ id: UUID) -> URL {
        project.appendingPathComponent("recordings").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Internals

    private static func readManifest(at url: URL) throws -> ProjectManifest {
        let projectFile = url.appendingPathComponent(projectFileName)
        guard let data = FileManager.default.contents(atPath: projectFile.path) else { throw ProjectStoreError.notAProject(url) }
        let manifest: ProjectManifest
        do {
            manifest = try ContractJSON.decoder().decode(ProjectManifest.self, from: data)
        } catch {
            // A newer writer may have added fields we cannot decode; say so by version
            // when we can read that much, rather than reporting a generic decode failure.
            struct VersionOnly: Decodable { let formatVersion: Int }
            if let v = try? ContractJSON.decoder().decode(VersionOnly.self, from: data), v.formatVersion > ContractVersion.format {
                throw ProjectStoreError.unsupportedFormatVersion(found: v.formatVersion, supported: ContractVersion.format)
            }
            throw ProjectStoreError.notAProject(url)
        }
        guard manifest.formatVersion <= ContractVersion.format else {
            throw ProjectStoreError.unsupportedFormatVersion(found: manifest.formatVersion, supported: ContractVersion.format)
        }
        return manifest
    }

    private func resultMeta(_ id: UUID) throws -> ResultMeta {
        guard let data = fm.contents(atPath: resultDirectory(id).appendingPathComponent(Self.resultMetaFileName).path) else {
            throw ProjectStoreError.missingResult(id)
        }
        return try ContractJSON.decoder().decode(ResultMeta.self, from: data)
    }

    private func childIDs(in child: String, requiring file: String) throws -> [UUID] {
        try Self.childIDs(in: directory, child: child, requiring: file)
    }

    /// Child directories named by a UUID that contain `file`. Temp directories, stray
    /// files and directories missing the file are not children, whatever else they hold.
    private static func childIDs(in project: URL, child: String, requiring file: String) throws -> [UUID] {
        let fm = FileManager.default
        let dir = project.appendingPathComponent(child, isDirectory: true)
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        return names.compactMap { name -> UUID? in
            guard let id = UUID(uuidString: name),
                  fm.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent(file).path) else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Deletes every `.tmp-*` entry a crash could have left: temp manifests, temp chunks,
    /// and temp pipeline/result directories. Committed files are never touched. The walk
    /// never follows a symbolic link (lstat semantics) and refuses to delete anything
    /// whose resolved path is not inside the project, so a hostile `.bciproj` cannot aim
    /// the sweep at the user's files.
    private static func removeOrphans(in project: URL) throws -> [String] {
        let fm = FileManager.default
        let root = project.resolvingSymlinksInPath().path + "/"
        var removed: [String] = []
        func isSymlink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
        }
        func sweep(_ dir: URL) throws {
            guard !isSymlink(dir), let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where name.hasPrefix(AtomicFile.tempPrefix) {
                let entry = dir.appendingPathComponent(name)
                guard !isSymlink(entry), entry.resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
                try fm.removeItem(at: entry)
                removed.append(dir.lastPathComponent + "/" + name)
            }
        }
        try sweep(project)
        for child in ["recordings", "pipelines", "results"] {
            let childDir = project.appendingPathComponent(child, isDirectory: true)
            try sweep(childDir)
            guard !isSymlink(childDir) else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: childDir.path)) ?? [] where UUID(uuidString: name) != nil {
                let entry = childDir.appendingPathComponent(name, isDirectory: true)
                guard !isSymlink(entry) else { continue }
                try sweep(entry)
                try sweep(entry.appendingPathComponent("chunks", isDirectory: true))
            }
        }
        return removed
    }
}

/// A committed result as read back from disk.
public struct StoredResult: Sendable {
    public var meta: ResultMeta
    public var evaluationJSON: Data
    public var pipeline: PipelineRecord
}

/// Where the app's bundled example project lives. The one injection point for the
/// "Explore an example" path: it reads from this URL and nowhere else.
public enum BundledExample {
    public static let name = "S001-motor-imagery"

    public static func locate(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "bciproj")
    }
}
