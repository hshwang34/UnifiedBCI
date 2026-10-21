import Foundation

/// Named points inside one chunk commit, in order. The crash-test helper exits the
/// process at one of them; production never installs a hook. The names are the test
/// plan's: after the temp file is written, after it is fsynced, after it is renamed to
/// its final name, and after the manifest listing it has been rewritten.
public struct CommitHook: Sendable {
    public enum Point: String, CaseIterable, Sendable {
        case afterTmpWrite, afterFsync, afterRename, afterManifestWrite
    }

    public var handler: @Sendable (Point, Int) -> Void

    public init(_ handler: @escaping @Sendable (Point, Int) -> Void) { self.handler = handler }
}

/// One chunk to commit: `samples` is `rowCount × sampleCount` doubles, row-major, in the
/// row order the manifest's channel map (plus counter/timestamp rows) describes.
public struct ChunkPayload: Sendable {
    public var samples: [Double]
    public var rowCount: Int
    public var sampleCount: Int
    public var segment: Int
    public var firstSampleIndex: Int
    public var drainedAtMonotonicNanos: Int64
    public var firstBrainflowTimestamp: Double?
    public var lastBrainflowTimestamp: Double?
    public var firstPackageNumber: Int?
    public var lastPackageNumber: Int?

    public init(samples: [Double], rowCount: Int, sampleCount: Int, segment: Int, firstSampleIndex: Int,
                drainedAtMonotonicNanos: Int64, firstBrainflowTimestamp: Double? = nil, lastBrainflowTimestamp: Double? = nil,
                firstPackageNumber: Int? = nil, lastPackageNumber: Int? = nil) {
        self.samples = samples; self.rowCount = rowCount; self.sampleCount = sampleCount
        self.segment = segment; self.firstSampleIndex = firstSampleIndex
        self.drainedAtMonotonicNanos = drainedAtMonotonicNanos
        self.firstBrainflowTimestamp = firstBrainflowTimestamp; self.lastBrainflowTimestamp = lastBrainflowTimestamp
        self.firstPackageNumber = firstPackageNumber; self.lastPackageNumber = lastPackageNumber
    }
}

/// Appends chunks and events to one recording (docs/data-contracts.md, "Sample chunks").
///
/// Commit protocol per chunk: write `chunks/.tmp-NNNNNN`, fsync, rename to
/// `chunks/NNNNNN.f64`, fsync the directory, then rewrite `recording.json` atomically
/// with the new `ChunkEntry`. A crash leaves at most one temp file (deleted on open) or
/// one committed-but-unlisted chunk (reported on verify); the listed prefix is always
/// readable. Events are appended to `events.jsonl` one `write` per line.
public actor ChunkWriter {
    public let directory: URL
    public private(set) var manifest: RecordingManifest
    private let hook: CommitHook?

    init(directory: URL, manifest: RecordingManifest, hook: CommitHook?) {
        self.directory = directory
        self.manifest = manifest
        self.hook = hook
    }

    @discardableResult
    public func append(_ chunk: ChunkPayload) throws -> RecordingManifest.ChunkEntry {
        guard chunk.samples.count == chunk.rowCount * chunk.sampleCount else {
            throw ProjectStoreError.invalidChunk("\(chunk.samples.count) samples is not \(chunk.rowCount)×\(chunk.sampleCount)")
        }
        guard chunk.sampleCount > 0, chunk.rowCount > 0 else { throw ProjectStoreError.invalidChunk("empty chunk") }
        let index = manifest.chunks.count
        let name = String(format: "%06d.f64", index)
        let final = directory.appendingPathComponent("chunks").appendingPathComponent(name)
        let tmp = directory.appendingPathComponent("chunks").appendingPathComponent(AtomicFile.tempPrefix + String(format: "%06d", index))

        var bytes = Data(capacity: chunk.samples.count * MemoryLayout<Double>.size)
        for v in chunk.samples {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        try AtomicFile.writeAndSync(bytes, to: tmp, afterWrite: { [hook] in hook?.handler(.afterTmpWrite, index) })
        hook?.handler(.afterFsync, index)
        try AtomicFile.rename(tmp, to: final)
        try AtomicFile.syncDirectory(final.deletingLastPathComponent())
        hook?.handler(.afterRename, index)

        let entry = RecordingManifest.ChunkEntry(
            index: index, fileName: "chunks/\(name)", segment: chunk.segment, firstSampleIndex: chunk.firstSampleIndex,
            sampleCount: chunk.sampleCount, rowCount: chunk.rowCount, sha256: AtomicFile.sha256Hex(bytes),
            drainedAtMonotonicNanos: chunk.drainedAtMonotonicNanos,
            firstBrainflowTimestamp: chunk.firstBrainflowTimestamp, lastBrainflowTimestamp: chunk.lastBrainflowTimestamp,
            firstPackageNumber: chunk.firstPackageNumber, lastPackageNumber: chunk.lastPackageNumber)
        manifest.chunks.append(entry)
        try writeManifest()
        hook?.handler(.afterManifestWrite, index)
        return entry
    }

    /// Replaces the segment list (e.g. to close a segment with its end reason) and
    /// rewrites the manifest atomically. Chunks already committed are untouched.
    public func updateSegments(_ segments: [RecordingManifest.StreamSegment]) throws {
        manifest.segments = segments
        try writeManifest()
    }

    public func appendEvent(_ event: EventRecord) throws {
        var line = try ContractJSON.lineEncoder().encode(event)
        line.append(0x0A)
        let url = directory.appendingPathComponent(ProjectStore.eventsFileName)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProjectStoreError.io("open events.jsonl", errno) }
        defer { close(fd) }
        try line.withUnsafeBytes { buf in
            guard Foundation.write(fd, buf.baseAddress!, buf.count) == buf.count else {
                throw ProjectStoreError.io("append events.jsonl", errno)
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw ProjectStoreError.io("fsync events.jsonl", errno) }
    }

    private func writeManifest() throws {
        try AtomicFile.write(try ContractJSON.encoder().encode(manifest), to: directory.appendingPathComponent(ProjectStore.recordingFileName))
    }
}

extension ContractJSON {
    /// Single-line variant for append-only `.jsonl` files: same date and key rules as
    /// `encoder()`, no pretty-printing.
    public static func lineEncoder() -> JSONEncoder {
        let e = encoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
