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

    public static let stagingLockFileName = ".staging.lock"

    public nonisolated let directory: URL
    public private(set) var manifest: ProjectManifest
    /// Temp files and directories deleted by `open`, by name, for the log and for tests.
    public private(set) var removedOrphans: [String] = []
    /// Temp entries `open` found but left: in use by a live evaluation (its staging lock
    /// is held), or not removable. Name and reason, for the log; never an open failure.
    public private(set) var keptOrphans: [String] = []
    /// `results/<uuid>` directories the last `results()` call could not read, with why.
    /// They are reported, not listed, and never deleted.
    public private(set) var unreadableResults: [UnreadableResult] = []
    /// Segments `open` closed as `process_terminated` ("<recording>#<segment>"), or could
    /// not close (with why), for the log and for tests.
    public private(set) var closedSegments: [String] = []

    private let fm = FileManager.default
    /// Open, `flock`ed lock files of staging directories this store handed out, by path.
    private var stagingLocks: [String: Int32] = [:]

    private init(directory: URL, manifest: ProjectManifest, sweep: OrphanSweep = .init(), closedSegments: [String] = []) {
        self.directory = directory
        self.manifest = manifest
        self.removedOrphans = sweep.removed
        self.keptOrphans = sweep.kept
        self.closedSegments = closedSegments
    }

    deinit {
        for fd in stagingLocks.values { close(fd) }
    }

    // MARK: Lifecycle

    /// Creates an empty project directory. Refuses to touch an existing path.
    /// Synchronous file I/O: call off the main actor.
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
    /// files left by a crash, closes segments a killed recorder left open, and returns. Chunk hashes are *not* verified here (that is
    /// `verify(recording:)`, on demand); opening stays cheap for large projects.
    /// Synchronous file I/O: call off the main actor.
    public static func open(at url: URL) throws -> ProjectStore {
        let fm = FileManager.default
        let manifest = try readManifest(at: url)
        for child in ["recordings", "pipelines", "results"] {
            let dir = url.appendingPathComponent(child, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        }
        let sweep = removeOrphans(in: url)
        return ProjectStore(directory: url, manifest: manifest, sweep: sweep, closedSegments: closeUnterminatedSegments(in: url, afterPrecheck: nil))
    }

    /// Copies the example project bundled with the app into `destination`, verifying
    /// every chunk against its manifest hash on the way, so a damaged bundle is refused
    /// before the user ever sees a project. Reads only from `source`; nothing else.
    ///
    /// The whole project is assembled in a `.tmp-<name>` sibling, fsynced, and renamed
    /// into place in one step, so `destination` is either absent or complete. Any
    /// failure removes the temp directory; a retry starts from scratch and can succeed.
    /// Synchronous file I/O: call off the main actor.
    public static func importBundledExample(from source: URL, into destination: URL, name: String? = nil, now: Date = Date()) throws -> ProjectStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectStoreError.alreadyExists(destination) }
        // The bundle is read-only, so open it without the orphan sweep a writable project gets.
        let bundled = try readManifest(at: source)
        let tmp = AtomicFile.tempURL(for: destination)
        // A temp left by an earlier crashed import is ours to replace (`removeItem` on a
        // symbolic link removes the link, not its target).
        if (try? fm.attributesOfItem(atPath: tmp.path)) != nil { try fm.removeItem(at: tmp) }
        do {
            _ = try create(at: tmp, name: name ?? bundled.name, now: now)
            for id in try childIDs(in: source, child: "recordings", requiring: recordingFileName) {
                let dst = recordingDirectory(in: tmp, id)
                try fm.copyItem(at: recordingDirectory(in: source, id), to: dst)
                let issues = try RecordingHandle(directory: dst).verify()
                guard issues.isEmpty else { throw ProjectStoreError.integrity(issues) }
            }
            // The README inside the example carries the license text; keep it with the copy.
            let readme = source.appendingPathComponent("README.md")
            if fm.fileExists(atPath: readme.path) {
                try fm.copyItem(at: readme, to: tmp.appendingPathComponent("README.md"))
            }
            try AtomicFile.syncTree(tmp)
            try AtomicFile.rename(tmp, to: destination)
            try AtomicFile.syncDirectory(destination.deletingLastPathComponent())
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return try open(at: destination)
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
        try makeRecording(manifest, hook: hook, fault: nil, lock: false).0
    }

    /// `createRecording` for `RecordingWriter`: the recording's `.writer.lock` is taken
    /// before its manifest exists and stays `flock`ed until the writer finishes, so no
    /// `open` (another window) closes the live segment as `process_terminated`.
    func createLiveRecording(_ manifest: RecordingManifest, hook: CommitHook?, fault: WriteFault?) throws -> (ChunkWriter, RecordingLock) {
        let (writer, lock) = try makeRecording(manifest, hook: hook, fault: fault, lock: true)
        return (writer, lock!)
    }

    private func makeRecording(_ manifest: RecordingManifest, hook: CommitHook?, fault: WriteFault?, lock: Bool) throws -> (ChunkWriter, RecordingLock?) {
        let dir = recordingDirectory(manifest.recordingID)
        guard !fm.fileExists(atPath: dir.path) else { throw ProjectStoreError.alreadyExists(dir) }
        var initial = manifest
        initial.chunks = []
        try fm.createDirectory(at: dir.appendingPathComponent("chunks", isDirectory: true), withIntermediateDirectories: true)
        let held = lock ? try RecordingLock.acquire(in: dir) : nil
        do {
            try AtomicFile.write(try ContractJSON.encoder().encode(initial), to: dir.appendingPathComponent(Self.recordingFileName))
            try AtomicFile.syncDirectory(dir)
        } catch {
            held?.release()
            throw error
        }
        return (ChunkWriter(directory: dir, manifest: initial, hook: hook, fault: fault), held)
    }

    // MARK: Pipelines and results

    /// A fresh `pipelines/.tmp-<uuid>` directory a caller (the worker, via the runner)
    /// may fill before `storeResult` consumes it. It holds a `.staging.lock` this store
    /// keeps `flock`ed until `storeResult` or `discardStagingDirectory`, so another
    /// `open` of the same project (a second window) skips it while the evaluation runs.
    /// Removed on the next `open` once abandoned (the lock dies with the process).
    public func stagingDirectory() throws -> URL {
        let url = directory.appendingPathComponent("pipelines").appendingPathComponent(AtomicFile.tempPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        let lockPath = url.appendingPathComponent(Self.stagingLockFileName).path
        let fd = Foundation.open(lockPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let code = errno
            try? fm.removeItem(at: url)
            throw ProjectStoreError.io("create staging lock", code)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            try? fm.removeItem(at: url)
            throw ProjectStoreError.io("lock staging directory", code)
        }
        stagingLocks[url.standardizedFileURL.path] = fd
        return url
    }

    /// Releases and deletes a staging directory from `stagingDirectory()` that will not
    /// be stored (the evaluation failed or was cancelled). Idempotent.
    public func discardStagingDirectory(_ url: URL) {
        try? fm.removeItem(at: url)
        releaseStagingLock(url)
    }

    private func releaseStagingLock(_ url: URL) {
        if let fd = stagingLocks.removeValue(forKey: url.standardizedFileURL.path) { close(fd) }
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
        let resultDir = resultDirectory(meta.resultID)
        let resultTmp = AtomicFile.tempURL(for: resultDir)
        do {
            try fm.createDirectory(at: pipelineTmp, withIntermediateDirectories: false)
            try AtomicFile.rename(fittedArraysFile, to: pipelineTmp.appendingPathComponent(Self.fittedFileName))
            try AtomicFile.writeAndSync(try ContractJSON.encoder().encode(pipeline), to: pipelineTmp.appendingPathComponent(Self.pipelineFileName))
            // The worker wrote `fitted.npz` and never fsynced it; `syncTree` flushes it
            // (and the record) before the directory becomes visible under its final name.
            try AtomicFile.syncTree(pipelineTmp)
            try AtomicFile.rename(pipelineTmp, to: pipelineDir)
            try AtomicFile.syncDirectory(pipelineDir.deletingLastPathComponent())

            try fm.createDirectory(at: resultTmp, withIntermediateDirectories: false)
            try AtomicFile.writeAndSync(evaluationJSON, to: resultTmp.appendingPathComponent(Self.evaluationFileName))
            try AtomicFile.writeAndSync(try ContractJSON.encoder().encode(meta), to: resultTmp.appendingPathComponent(Self.resultMetaFileName))
            try AtomicFile.syncTree(resultTmp)
            try AtomicFile.rename(resultTmp, to: resultDir)
            try AtomicFile.syncDirectory(resultDir.deletingLastPathComponent())
        } catch {
            try? fm.removeItem(at: pipelineTmp)
            try? fm.removeItem(at: resultTmp)
            throw error
        }
        // The worker's staging directory now holds only its lock; drop both.
        discardStagingDirectory(fittedArraysFile.deletingLastPathComponent())
        return meta.resultID
    }

    /// Every readable result, oldest first by `result.meta.json` creation time. A result
    /// whose meta cannot be read or decoded is skipped and reported in
    /// `unreadableResults`, so one damaged directory never hides the others.
    public func results() throws -> [ResultMeta] {
        var unreadable: [UnreadableResult] = []
        let metas = try childIDs(in: "results", requiring: Self.resultMetaFileName).compactMap { id -> ResultMeta? in
            do {
                let meta = try resultMeta(id)
                guard meta.resultID == id else {
                    throw ProjectStoreError.invalidManifest("result.meta.json names \(meta.resultID.uuidString)")
                }
                return meta
            } catch {
                unreadable.append(UnreadableResult(resultID: id, reason: "\(error)"))
                return nil
            }
        }
        unreadableResults = unreadable
        return metas.sorted { ($0.createdAt, $0.resultID.uuidString) < ($1.createdAt, $1.resultID.uuidString) }
    }

    /// One result, with `evaluation.json` checked against the SHA-256 its meta records.
    public func result(id: UUID) throws -> StoredResult {
        let meta = try resultMeta(id)
        guard let evaluation = fm.contents(atPath: resultDirectory(id).appendingPathComponent(Self.evaluationFileName).path) else {
            throw ProjectStoreError.missingResult(id)
        }
        let digest = AtomicFile.sha256Hex(evaluation)
        guard digest == meta.evaluationSHA256 else {
            throw ProjectStoreError.integrity([IntegrityIssue(kind: .hashMismatch, file: "results/\(id.uuidString)/\(Self.evaluationFileName)",
                                                              detail: "SHA-256 \(digest) ≠ result.meta.json \(meta.evaluationSHA256)")])
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
    ///
    /// Best-effort: an entry that cannot be removed is kept and reported, never a reason
    /// to refuse the project. A staging directory whose `.staging.lock` is held (an
    /// evaluation in another window of this app is filling it) is kept too. So is any
    /// `.tmp-*` directory modified within `orphanGracePeriod` unless its lock is provably
    /// free: a staging directory exists briefly before its lock file does, and the
    /// result/pipeline directories `storeResult` assembles carry no lock at all.
    /// Older ones are swept; temp files (chunks, manifests) are swept at any age.
    private static func removeOrphans(in project: URL, now: Date = Date()) -> OrphanSweep {
        let fm = FileManager.default
        let root = project.resolvingSymlinksInPath().path + "/"
        var result = OrphanSweep()
        func isSymlink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
        }
        func sweep(_ dir: URL) {
            guard !isSymlink(dir), let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() where name.hasPrefix(AtomicFile.tempPrefix) {
                let entry = dir.appendingPathComponent(name)
                let label = dir.lastPathComponent + "/" + name
                guard !isSymlink(entry), entry.resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
                var st = stat()
                guard lstat(entry.path, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    let lock = stagingLockState(in: entry)
                    if lock == .held {
                        result.kept.append(label + ": in use by a running evaluation")
                        continue
                    }
                    let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    if lock == .absent, now.timeIntervalSince(modified) < orphanGracePeriod {
                        result.kept.append(label + ": modified recently, may still be in use")
                        continue
                    }
                }
                do {
                    try fm.removeItem(at: entry)
                    result.removed.append(label)
                } catch {
                    result.kept.append(label + ": \(error.localizedDescription)")
                }
            }
        }
        sweep(project)
        for child in ["recordings", "pipelines", "results"] {
            let childDir = project.appendingPathComponent(child, isDirectory: true)
            sweep(childDir)
            guard !isSymlink(childDir) else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: childDir.path)) ?? [] where UUID(uuidString: name) != nil {
                let entry = childDir.appendingPathComponent(name, isDirectory: true)
                guard !isSymlink(entry) else { continue }
                sweep(entry)
                sweep(entry.appendingPathComponent("chunks", isDirectory: true))
            }
        }
        return result
    }

    /// Closes every segment a killed writer left open (`endReason == nil`): `endReason`
    /// `process_terminated`, `endedAtMonotonicNanos` = the last committed chunk's drain
    /// time (the last evidence the process was alive), and a `process_terminated` gap
    /// after the segment's last committed sample — whatever BrainFlow still buffered is
    /// gone, by an unknown amount. When the writer was alive but could not close the
    /// segment (disk full), its lock file carries the real reason and count, used instead.
    /// The one rewrite a committed recording ever gets; chunk entries are untouched.
    ///
    /// The recording's writer lock is taken first and held across the re-read and the
    /// rewrite, so a writer finishing concurrently is never overwritten with a stale
    /// manifest. Best-effort, like the orphan sweep: a recording that cannot be read,
    /// locked or rewritten is reported and left exactly as found. `afterPrecheck` is a
    /// test seam that runs between the unlocked first look and taking the lock.
    static func closeUnterminatedSegments(in project: URL, afterPrecheck: (() -> Void)? = nil) -> [String] {
        var report: [String] = []
        for id in (try? childIDs(in: project, child: "recordings", requiring: recordingFileName)) ?? [] {
            let dir = recordingDirectory(in: project, id)
            // Cheap first look without the lock: most recordings are closed.
            guard let first = try? RecordingHandle(directory: dir).manifest,
                  first.segments.contains(where: { $0.endReason == nil }) else { continue }
            afterPrecheck?()
            guard let lock = RecordingLock.tryAcquire(in: dir) else { continue }   // a live writer
            var keepLock = true
            defer { lock.release(keepFile: keepLock) }
            guard var manifest = try? RecordingHandle(directory: dir).manifest else { continue }
            let note = lock.readNote()
            var closed: [String] = []
            let lastOpen = manifest.segments.lastIndex { $0.endReason == nil }
            for i in manifest.segments.indices where manifest.segments[i].endReason == nil {
                let index = manifest.segments[i].index
                let last = manifest.chunks.filter { $0.segment == index }.max { $0.firstSampleIndex < $1.firstSampleIndex }
                manifest.segments[i].endedAtMonotonicNanos = last?.drainedAtMonotonicNanos ?? manifest.segments[i].startedAtMonotonicNanos
                if i == lastOpen, let note, RecordingLock.note(note, fits: manifest.segments[i], nominalRateHz: manifest.timing.nominalSampleRateHz) {
                    manifest.segments[i].endedAtMonotonicNanos = note.endedAtMonotonicNanos
                    manifest.segments[i].endReason = note.reason
                    if note.uncommitted > 0 { manifest.segments[i].uncommittedSampleCount = note.uncommitted }
                } else {
                    // `validate` guarantees firstSampleIndex + sampleCount does not overflow.
                    let after = last.map { $0.firstSampleIndex + ($0.sampleCount - 1) } ?? -1
                    manifest.segments[i].endReason = .processTerminated
                    manifest.segments[i].detectedGaps.append(.init(afterSampleIndex: after, evidence: .processTerminated,
                                                                   estimatedMissingSamples: nil, ambiguous: false))
                }
                closed.append("\(id.uuidString)#\(index)")
            }
            guard !closed.isEmpty else { keepLock = false; continue }   // its writer finished meanwhile
            do {
                try AtomicFile.write(try ContractJSON.encoder().encode(manifest), to: dir.appendingPathComponent(recordingFileName))
                keepLock = false
                report += closed
            } catch {
                report.append("\(id.uuidString): not closed: \(error)")
            }
        }
        return report
    }

    /// How long an unlocked `.tmp-*` directory is presumed to be in use by a writer.
    static let orphanGracePeriod: TimeInterval = 10 * 60

    enum StagingLock { case held, free, absent }

    /// Whether `dir` holds a `.staging.lock` and whether some open file description has
    /// it `flock`ed. `flock` locks belong to the open file, so this also sees a lock held
    /// by another `ProjectStore` in this same process. `.free` is the only proof that
    /// nobody is writing; a lock file that cannot be opened counts as absent.
    private static func stagingLockState(in dir: URL) -> StagingLock {
        lockState(dir.appendingPathComponent(stagingLockFileName))
    }

    static func lockState(_ file: URL) -> StagingLock {
        let fd = Foundation.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        return errno == EWOULDBLOCK ? .held : .absent
    }

    struct OrphanSweep {
        var removed: [String] = []
        var kept: [String] = []
    }
}

/// `recordings/<uuid>/.writer.lock`, `flock`ed by a live `RecordingWriter` (or briefly by
/// `ProjectStore.open` closing a dead writer's segment). The lock dies with the process,
/// which is how `open` tells a killed writer from a live one. The file is created with
/// `noteSize` bytes of padding, so a writer that cannot close its segment on a full disk
/// can still overwrite them with its segment, end reason, uncommitted count and end time
/// ("3 disk_full 1234 987654321") without allocating.
struct RecordingLock: Sendable {
    static let fileName = ".writer.lock"
    static let noteSize = 64
    let fd: Int32
    let path: String

    static func acquire(in dir: URL) throws -> RecordingLock {
        let path = dir.appendingPathComponent(fileName).path
        let fd = Foundation.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProjectStoreError.io("create writer lock", errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw ProjectStoreError.io("lock recording", code)
        }
        let lock = RecordingLock(fd: fd, path: path)
        lock.write(String(repeating: " ", count: noteSize))
        return lock
    }

    /// The lock, or nil when someone else holds it (or it cannot be opened).
    static func tryAcquire(in dir: URL) -> RecordingLock? {
        let path = dir.appendingPathComponent(fileName).path
        let fd = Foundation.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return RecordingLock(fd: fd, path: path)
    }

    /// What a writer that could not close a segment on disk leaves for the next `open`.
    /// It names its segment, so it can never be applied to a later one.
    struct Note: Equatable {
        var segment: Int
        var reason: EndReason
        var uncommitted: Int
        var endedAtMonotonicNanos: Int64
    }

    /// Only the reasons a failed writer close produces; never `stopped`, so a damaged or
    /// stale note can't make a crashed segment look like a clean stop.
    static let noteReasons: Set<EndReason> = [.disconnect, .diskFull, .error]

    func note(_ note: Note) {
        let text = "\(note.segment) \(note.reason.rawValue) \(note.uncommitted) \(note.endedAtMonotonicNanos)"
        write(text + String(repeating: " ", count: max(0, Self.noteSize - text.utf8.count)))
    }

    /// Blanks the note once the segment it described is closed on disk.
    func clearNote() { write(String(repeating: " ", count: Self.noteSize)) }

    func readNote() -> Note? {
        var buf = [UInt8](repeating: 0, count: Self.noteSize)
        let n = pread(fd, &buf, Self.noteSize, 0)
        guard n > 0 else { return nil }
        let parts = String(decoding: buf.prefix(n), as: UTF8.self).split(separator: " ")
        guard parts.count == 4, let segment = Int(parts[0]), segment >= 0,
              let reason = EndReason(rawValue: String(parts[1])), Self.noteReasons.contains(reason),
              let count = Int(parts[2]), count >= 0, let endedAt = Int64(parts[3]), endedAt >= 0 else { return nil }
        return Note(segment: segment, reason: reason, uncommitted: count, endedAtMonotonicNanos: endedAt)
    }

    /// Whether `note` can describe `segment`: same index, ended after it started, and no more
    /// uncommitted samples than could have arrived by then (2× nominal rate, plus one second).
    static func note(_ note: Note, fits segment: RecordingManifest.StreamSegment, nominalRateHz: Double) -> Bool {
        // Both values are untrusted (lock file, manifest): subtract without trapping.
        let (elapsed, overflow) = note.endedAtMonotonicNanos.subtractingReportingOverflow(segment.startedAtMonotonicNanos)
        guard note.segment == segment.index, segment.startedAtMonotonicNanos >= 0, !overflow, elapsed >= 0,
              nominalRateHz.isFinite, nominalRateHz > 0 else { return false }
        let bound = (Double(elapsed) / 1e9 + 1) * nominalRateHz * 2
        return bound.isFinite && Double(note.uncommitted) <= bound
    }

    private func write(_ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        try? AtomicFile.fullSync(fd, Self.fileName)
    }

    /// Drops the lock; removes the file unless it must keep a note for the next `open`.
    func release(keepFile: Bool = false) {
        if !keepFile { unlink(path) }
        close(fd)
    }
}

/// A `results/<uuid>` directory whose `result.meta.json` could not be read.
public struct UnreadableResult: Sendable, Equatable {
    public var resultID: UUID
    public var reason: String
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
