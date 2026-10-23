import Foundation

/// A recording's manifest plus lazy, verified access to its chunk files. Nothing is read
/// until asked; every chunk read is checked against the manifest's SHA-256 and size.
///
/// A `.bciproj` can come from anywhere, so the manifest is hostile input: it is
/// validated once here (`validate`) and chunk paths are derived from the entry's index,
/// never taken from `fileName`, so a manifest cannot point outside its own directory.
public struct RecordingHandle: Sendable {
    public let directory: URL
    public let manifest: RecordingManifest

    init(directory: URL) throws {
        let url = directory.appendingPathComponent(ProjectStore.recordingFileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ProjectStoreError.notAProject(directory)
        }
        self.directory = directory
        self.manifest = try ContractJSON.decoder().decode(RecordingManifest.self, from: data)
        try Self.validate(manifest)
    }

    public var id: UUID { manifest.recordingID }

    /// The canonical chunk file name for an index; the only form the store writes or reads.
    public static func chunkFileName(index: Int) -> String {
        "chunks/" + String(format: "%06d", index) + ".f64"
    }

    /// Structural checks a decoder cannot make: every chunk's dimensions are positive and
    /// their byte size fits an `Int`, its `fileName` is exactly the canonical name for its
    /// index, indices are unique, and every channel's `sourceRow` is a row of every chunk.
    static func validate(_ manifest: RecordingManifest) throws {
        var seen = Set<Int>()
        for entry in manifest.chunks {
            guard entry.index >= 0, seen.insert(entry.index).inserted else {
                throw ProjectStoreError.invalidManifest("chunk index \(entry.index) is negative or duplicated")
            }
            guard entry.fileName == chunkFileName(index: entry.index) else {
                throw ProjectStoreError.invalidManifest("chunk \(entry.index) names '\(entry.fileName)', not '\(chunkFileName(index: entry.index))'")
            }
            guard entry.rowCount > 0, entry.sampleCount > 0, entry.firstSampleIndex >= 0, entry.segment >= 0 else {
                throw ProjectStoreError.invalidManifest("chunk \(entry.index) has non-positive dimensions")
            }
            _ = try expectedByteCount(entry)
            for channel in manifest.channels where !(0..<entry.rowCount).contains(channel.sourceRow) {
                throw ProjectStoreError.invalidManifest("channel \(channel.id) reads row \(channel.sourceRow), but chunk \(entry.index) has \(entry.rowCount) rows")
            }
        }
    }

    /// `rowCount × sampleCount × 8` without silent overflow.
    static func expectedByteCount(_ entry: RecordingManifest.ChunkEntry) throws -> Int {
        let (cells, o1) = entry.rowCount.multipliedReportingOverflow(by: entry.sampleCount)
        let (bytes, o2) = cells.multipliedReportingOverflow(by: MemoryLayout<Double>.size)
        guard !o1, !o2 else { throw ProjectStoreError.invalidChunk("chunk \(entry.index): \(entry.rowCount)×\(entry.sampleCount) float64 overflows") }
        return bytes
    }

    /// The chunk's path, built from its index and confirmed (after resolving symlinks) to
    /// lie inside this recording's `chunks/` directory. `chunks` itself is not resolved,
    /// so a `chunks` symlink pointing elsewhere fails the check too.
    func chunkURL(_ entry: RecordingManifest.ChunkEntry) throws -> URL {
        let chunkDir = directory.resolvingSymlinksInPath().appendingPathComponent("chunks", isDirectory: true)
        let url = directory.appendingPathComponent(Self.chunkFileName(index: entry.index))
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(chunkDir.path + "/") else {
            throw ProjectStoreError.integrity([IntegrityIssue(kind: .missingChunk, file: entry.fileName, detail: "resolves outside the recording directory")])
        }
        return resolved
    }

    /// Raw little-endian float64 bytes of one chunk, verified. Throws `.integrity` on
    /// any disagreement with the manifest; the file is left exactly as found.
    public func chunkBytes(_ entry: RecordingManifest.ChunkEntry) throws -> Data {
        switch verifiedBytes(entry) {
        case .success(let data): return data
        case .failure(let issue): throw ProjectStoreError.integrity([issue])
        }
    }

    /// One chunk as `rowCount × sampleCount` doubles, row-major, host byte order (little).
    public func chunk(_ entry: RecordingManifest.ChunkEntry) throws -> [Double] {
        let data = try chunkBytes(entry)
        return data.withUnsafeBytes { buf in
            // `Data` makes no alignment promise, so read each value unaligned.
            (0..<(buf.count / 8)).map { Double(bitPattern: UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) }
        }
    }

    /// Chunk entries of one stream segment in sample order.
    public func chunks(inSegment segment: Int) -> [RecordingManifest.ChunkEntry] {
        manifest.chunks.filter { $0.segment == segment }.sorted { $0.firstSampleIndex < $1.firstSampleIndex }
    }

    public func events() throws -> [EventRecord] {
        let url = directory.appendingPathComponent(ProjectStore.eventsFileName)
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = ContractJSON.decoder()
        return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            line.isEmpty ? nil : try decoder.decode(EventRecord.self, from: line)
        }
    }

    /// Checks every listed chunk and reports committed chunk files the manifest does not
    /// list (a crash between rename and manifest rewrite leaves exactly that). Nothing is
    /// modified. An empty array means every byte the manifest claims is present and matches.
    public func verify() -> [IntegrityIssue] {
        var issues = manifest.chunks.compactMap(check)
        let listed = Set(manifest.chunks.map { ($0.fileName as NSString).lastPathComponent })
        let chunkDir = directory.appendingPathComponent("chunks", isDirectory: true)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: chunkDir.path)) ?? []).sorted()
        where !name.hasPrefix(AtomicFile.tempPrefix) && !listed.contains(name) {
            issues.append(IntegrityIssue(kind: .unlistedChunk, file: "chunks/\(name)", detail: "committed chunk file the manifest does not list"))
        }
        return issues
    }

    private func check(_ entry: RecordingManifest.ChunkEntry) -> IntegrityIssue? {
        if case .failure(let issue) = verifiedBytes(entry) { return issue }
        return nil
    }

    /// The chunk's bytes if the file is a regular file of exactly the declared size
    /// (checked with `fstat` before anything is read) whose SHA-256 matches; otherwise
    /// the first disagreement. Opened with `O_NOFOLLOW` and non-blocking, so a symbolic
    /// link or a FIFO in place of a chunk is refused rather than followed or waited on.
    private func verifiedBytes(_ entry: RecordingManifest.ChunkEntry) -> Result<Data, IntegrityIssue> {
        func issue(_ kind: IntegrityIssue.Kind, _ detail: String) -> Result<Data, IntegrityIssue> {
            .failure(IntegrityIssue(kind: kind, file: entry.fileName, detail: detail))
        }
        guard (try? chunkURL(entry)) != nil else { return issue(.missingChunk, "resolves outside the recording directory") }
        guard let expected = try? Self.expectedByteCount(entry) else { return issue(.sizeMismatch, "declared size overflows") }
        let path = directory.appendingPathComponent(Self.chunkFileName(index: entry.index)).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return issue(.missingChunk, errno == ENOENT ? "listed in the manifest but absent" : "cannot be opened: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return issue(.missingChunk, "not a regular file") }
        guard st.st_size == off_t(expected) else {
            return issue(.sizeMismatch, "\(st.st_size) bytes, manifest says \(entry.rowCount)×\(entry.sampleCount) float64 = \(expected)")
        }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data(), data.count == expected else {
            return issue(.sizeMismatch, "file changed size while being read")
        }
        let digest = AtomicFile.sha256Hex(data)
        if digest != entry.sha256 {
            return issue(.hashMismatch, "SHA-256 \(digest) ≠ manifest \(entry.sha256)")
        }
        return .success(data)
    }
}
