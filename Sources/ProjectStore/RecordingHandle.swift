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
    /// lie inside this recording's `chunks/` directory.
    func chunkURL(_ entry: RecordingManifest.ChunkEntry) throws -> URL {
        let chunkDir = directory.appendingPathComponent("chunks", isDirectory: true).resolvingSymlinksInPath()
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
        if let issue = check(entry) { throw ProjectStoreError.integrity([issue]) }
        return try Data(contentsOf: try chunkURL(entry))
    }

    /// One chunk as `rowCount × sampleCount` doubles, row-major, host byte order (little).
    public func chunk(_ entry: RecordingManifest.ChunkEntry) throws -> [Double] {
        let data = try chunkBytes(entry)
        return data.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: UInt64.self)).map { Double(bitPattern: UInt64(littleEndian: $0)) }
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
        guard let url = try? chunkURL(entry) else {
            return IntegrityIssue(kind: .missingChunk, file: entry.fileName, detail: "resolves outside the recording directory")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return IntegrityIssue(kind: .missingChunk, file: entry.fileName, detail: "listed in the manifest but absent")
        }
        guard let expected = try? Self.expectedByteCount(entry) else {
            return IntegrityIssue(kind: .sizeMismatch, file: entry.fileName, detail: "declared size overflows")
        }
        if data.count != expected {
            return IntegrityIssue(kind: .sizeMismatch, file: entry.fileName, detail: "\(data.count) bytes, manifest says \(entry.rowCount)×\(entry.sampleCount) float64 = \(expected)")
        }
        let digest = AtomicFile.sha256Hex(data)
        if digest != entry.sha256 {
            return IntegrityIssue(kind: .hashMismatch, file: entry.fileName, detail: "SHA-256 \(digest) ≠ manifest \(entry.sha256)")
        }
        return nil
    }
}
