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

/// Test seam for disk faults: asked at each commit point of each chunk, it returns an
/// errno (`ENOSPC`) to fail that step as the OS would, or nil. Production installs none.
public struct WriteFault: Sendable {
    public var errnoAt: @Sendable (CommitHook.Point, Int) -> Int32?

    public init(_ errnoAt: @escaping @Sendable (CommitHook.Point, Int) -> Int32?) { self.errnoAt = errnoAt }

    func check(_ point: CommitHook.Point, _ index: Int) throws {
        if let code = errnoAt(point, index) { throw ProjectStoreError.io("injected fault at \(point.rawValue)", code) }
    }
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
    private let fault: WriteFault?
    /// The index the next chunk gets. Advanced as soon as a chunk file has been renamed
    /// into place, so a retry after a later step threw never renames over a committed
    /// file; the abandoned index stays on disk as an `unlistedChunk` for `verify`.
    private var nextIndex: Int

    init(directory: URL, manifest: RecordingManifest, hook: CommitHook?, fault: WriteFault? = nil) {
        self.directory = directory
        self.manifest = manifest
        self.hook = hook
        self.fault = fault
        self.nextIndex = (manifest.chunks.map(\.index).max() ?? -1) + 1
    }

    /// Commits one chunk. `segments`, when given, replaces the segment list in the same
    /// manifest rewrite (the recording writer adds gaps this way without a second rewrite).
    @discardableResult
    public func append(_ chunk: ChunkPayload, segments: [RecordingManifest.StreamSegment]? = nil) throws -> RecordingManifest.ChunkEntry {
        guard chunk.samples.count == chunk.rowCount * chunk.sampleCount else {
            throw ProjectStoreError.invalidChunk("\(chunk.samples.count) samples is not \(chunk.rowCount)×\(chunk.sampleCount)")
        }
        guard chunk.sampleCount > 0, chunk.rowCount > 0 else { throw ProjectStoreError.invalidChunk("empty chunk") }
        // Never reuse an index whose file exists (a chunk committed by an attempt that
        // threw after its rename, or one a hostile project planted): skip past it.
        let chunkDir = directory.appendingPathComponent("chunks")
        while FileManager.default.fileExists(atPath: chunkDir.appendingPathComponent(String(format: "%06d.f64", nextIndex)).path) {
            nextIndex += 1
        }
        let index = nextIndex
        let name = String(format: "%06d.f64", index)
        let final = chunkDir.appendingPathComponent(name)
        let tmp = chunkDir.appendingPathComponent(AtomicFile.tempPrefix + String(format: "%06d", index))

        var bytes = Data(capacity: chunk.samples.count * MemoryLayout<Double>.size)
        for v in chunk.samples {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        try AtomicFile.writeAndSync(bytes, to: tmp, fresh: true, afterWrite: { [hook, fault] in
            try fault?.check(.afterTmpWrite, index)
            hook?.handler(.afterTmpWrite, index)
        })
        do {
            try fault?.check(.afterFsync, index)
        } catch {
            unlink(tmp.path)   // not renamed yet: nothing committed, leave no temp behind
            throw error
        }
        hook?.handler(.afterFsync, index)
        try AtomicFile.rename(tmp, to: final)
        nextIndex = index + 1
        try AtomicFile.syncDirectory(final.deletingLastPathComponent())
        try fault?.check(.afterRename, index)
        hook?.handler(.afterRename, index)

        let entry = RecordingManifest.ChunkEntry(
            index: index, fileName: "chunks/\(name)", segment: chunk.segment, firstSampleIndex: chunk.firstSampleIndex,
            sampleCount: chunk.sampleCount, rowCount: chunk.rowCount, sha256: AtomicFile.sha256Hex(bytes),
            drainedAtMonotonicNanos: chunk.drainedAtMonotonicNanos,
            firstBrainflowTimestamp: chunk.firstBrainflowTimestamp, lastBrainflowTimestamp: chunk.lastBrainflowTimestamp,
            firstPackageNumber: chunk.firstPackageNumber, lastPackageNumber: chunk.lastPackageNumber)
        // In memory first: if this rewrite fails, the next one (a segment close) lists the
        // chunk, whose bytes are already durable under their final name.
        manifest.chunks.append(entry)
        if let segments { manifest.segments = segments }
        try fault?.check(.afterManifestWrite, index)
        try writeManifest()
        hook?.handler(.afterManifestWrite, index)
        return entry
    }

    /// Replaces the segment list (e.g. to close a segment with its end reason) and
    /// rewrites the manifest atomically. Chunks already committed are untouched.
    public func updateSegments(_ segments: [RecordingManifest.StreamSegment]) throws {
        manifest.segments = segments
        try fault?.check(.afterManifestWrite, -1)   // index -1: a segment-only rewrite
        try writeManifest()
    }

    /// After a failed write: makes the in-memory chunk list exactly what `recording.json` on
    /// disk lists, and deletes this recording's temp files and any chunk file the disk
    /// manifest does not list (this writer's own failed attempt), so a full disk gets that
    /// space back and `verify` finds nothing unlisted. Returns the listed chunk count.
    func reconcileWithDisk() -> Int {
        let url = directory.appendingPathComponent(ProjectStore.recordingFileName)
        if let data = BoundedRead.data(at: url, maxBytes: BoundedRead.recordingManifestBytes),
           let disk = try? ContractJSON.decoder().decode(RecordingManifest.self, from: data) {
            manifest.chunks = disk.chunks
        }
        let listed = Set(manifest.chunks.map { ($0.fileName as NSString).lastPathComponent })
        let chunkDir = directory.appendingPathComponent("chunks")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: chunkDir.path)) ?? []
        where name.hasPrefix(AtomicFile.tempPrefix) || (name.hasSuffix(".f64") && !listed.contains(name)) {
            unlink(chunkDir.appendingPathComponent(name).path)
        }
        unlink(AtomicFile.tempURL(for: url).path)
        return manifest.chunks.count
    }

    public func appendEvent(_ event: EventRecord) throws {
        try AppendOnlyFile.appendLine(try ContractJSON.lineEncoder().encode(event), to: directory.appendingPathComponent(ProjectStore.eventsFileName))
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
