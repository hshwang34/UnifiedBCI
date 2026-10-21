import Foundation

/// A recording's manifest plus lazy, verified access to its chunk files. Nothing is read
/// until asked; every chunk read is checked against the manifest's SHA-256 and size.
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
    }

    public var id: UUID { manifest.recordingID }

    /// Raw little-endian float64 bytes of one chunk, verified. Throws `.integrity` on
    /// any disagreement with the manifest; the file is left exactly as found.
    public func chunkBytes(_ entry: RecordingManifest.ChunkEntry) throws -> Data {
        if let issue = check(entry) { throw ProjectStoreError.integrity([issue]) }
        return try Data(contentsOf: directory.appendingPathComponent(entry.fileName))
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
        let url = directory.appendingPathComponent(entry.fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return IntegrityIssue(kind: .missingChunk, file: entry.fileName, detail: "listed in the manifest but absent")
        }
        let expected = entry.rowCount * entry.sampleCount * MemoryLayout<Double>.size
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
