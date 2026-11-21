import Foundation
import Synchronization

/// Durable live recording (brief 004, "Recording"): takes drained sample blocks as they
/// arrive, re-chunks them into `samplesPerChunk`-sample chunks per stream segment, and
/// commits each through `ChunkWriter`'s protocol, with the segment's gaps in the same
/// manifest rewrite.
///
/// The producer (the drain loop) calls `submit`, which never waits: it appends to an
/// in-memory queue under a lock and returns. One consumer task does all disk I/O. If the
/// queue grows past `backlogLimitChunks`, the block that did not fit is refused and
/// counted, the queue is still committed, and the segment ends `error`. Free space under
/// `minimumFreeBytes` before a commit, or `ENOSPC` from any write, ends it `disk_full`
/// and counts everything not yet committed. Samples are written exactly as received:
/// never interpolated, repeated or zero-filled.
public final class RecordingWriter: Sendable {
    public static let samplesPerChunk = 125          // ~1 s at 125 Hz
    public static let backlogLimitChunks = 30        // ≈ 30 s behind → stop (brief 004)
    public static let minimumFreeBytes: Int64 = 100 * 1024 * 1024   // decision #33

    /// One drained block: `rowCount × sampleCount` doubles, row-major, all board rows.
    public struct Block: Sendable {
        public var values: [Double]
        public var rowCount: Int
        public var sampleCount: Int
        public var drainedAtMonotonicNanos: Int64
        /// Gaps with `afterSampleIndex` relative to this block (-1 = before its first sample).
        public var gaps: [RecordingManifest.Gap]

        public init(values: [Double], rowCount: Int, sampleCount: Int, drainedAtMonotonicNanos: Int64, gaps: [RecordingManifest.Gap] = []) {
            self.values = values; self.rowCount = rowCount; self.sampleCount = sampleCount
            self.drainedAtMonotonicNanos = drainedAtMonotonicNanos; self.gaps = gaps
        }
    }

    public struct Options: Sendable {
        public var samplesPerChunk = RecordingWriter.samplesPerChunk
        public var backlogLimitChunks = RecordingWriter.backlogLimitChunks
        public var minimumFreeBytes = RecordingWriter.minimumFreeBytes
        /// BrainFlow timestamp row, for each chunk entry's first/last timestamp.
        public var timestampRow: Int?
        /// Free bytes on the recording's volume; replaced in tests.
        public var freeBytes: @Sendable (URL) -> Int64? = RecordingWriter.freeBytes(at:)
        public var hook: CommitHook?
        public var fault: WriteFault?

        public init(timestampRow: Int? = nil) { self.timestampRow = timestampRow }
    }

    /// What the writer has done so far; cheap to read from any thread (health panel).
    public struct Status: Sendable, Equatable {
        public var backlogChunks = 0
        public var committedChunks = 0
        public var committedSamples = 0
        public var lastCommitMonotonicNanos: Int64?
        /// Wall time of the most recent commits (newest last, at most 100), nanoseconds.
        public var recentCommitDurationsNanos: [Int64] = []
        public var endReason: EndReason?
        public var uncommittedSamples = 0
        /// The error that ended the recording, or that prevented closing its segment.
        public var failure: String?
    }

    public enum SubmitResult: Sendable, Equatable { case accepted, refused(EndReason) }

    public let recordingID: UUID
    private let options: Options
    private let shared: WriterShared
    private let commands: AsyncStream<WriterCommand>.Continuation
    private let consumer: Task<Void, Never>

    /// Creates the recording (its manifest with segment 0 open) and starts the writer.
    /// `manifest.segments` and `.chunks` are replaced. Holds the recording's writer lock
    /// until `finish`, so `ProjectStore.open` elsewhere never closes this live segment.
    public static func start(in store: ProjectStore, manifest: RecordingManifest, startedAtWall: Date,
                             startedAtMonotonicNanos: Int64, options: Options = .init()) async throws -> RecordingWriter {
        var m = manifest
        m.segments = [.init(index: 0, sessionID: m.sessionID, runID: m.runID, startedAtWall: startedAtWall,
                            startedAtMonotonicNanos: startedAtMonotonicNanos, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])]
        let (writer, lock) = try await store.createLiveRecording(m, hook: options.hook, fault: options.fault)
        return RecordingWriter(writer: writer, manifest: m, lock: lock, options: options)
    }

    private init(writer: ChunkWriter, manifest: RecordingManifest, lock: RecordingLock, options: Options) {
        recordingID = manifest.recordingID
        self.options = options
        let (stream, continuation) = AsyncStream<WriterCommand>.makeStream(bufferingPolicy: .unbounded)
        commands = continuation
        let shared = WriterShared()
        self.shared = shared
        let (segments, counterRow) = (manifest.segments, manifest.timing.sequenceCounterRow)
        consumer = Task.detached(priority: .userInitiated) {
            var assembler = Assembler(writer: writer, segments: segments, counterRow: counterRow, options: options, shared: shared, lock: lock)
            for await command in stream {
                if await !assembler.handle(command) { break }
            }
            // A segment the writer could not close keeps the lock file and its end note.
            lock.release(keepFile: assembler.leftOpen)
        }
    }

    /// Released without `finish`: the consumer still commits everything accepted and closes
    /// the segment `error`, so nothing buffered is dropped silently.
    deinit {
        shared.state.withLock { s in
            guard s.accepting else { return }
            s.accepting = false
            s.status.failure = "The recording writer was released without finish()"
            commands.yield(.finish(.error, endedAt: HostMonotonicClock.nowNanos()))
        }
        commands.finish()
    }

    public var status: Status { shared.state.withLock { $0.status } }

    /// Hands one drained block to the writer. Never blocks and never drops silently:
    /// `.refused` means the recording has stopped (its reason is in `status`).
    @discardableResult
    public func submit(_ block: Block) -> SubmitResult {
        precondition(block.values.count == block.rowCount * block.sampleCount, "block is not rowCount × sampleCount")
        return shared.state.withLock { s in
            guard s.accepting else { return .refused(s.status.endReason ?? .stopped) }
            let limit = options.backlogLimitChunks * options.samplesPerChunk
            if s.pendingSamples + block.sampleCount > limit {
                s.accepting = false
                s.status.endReason = .error
                s.status.failure = "The disk could not keep up: \(options.backlogLimitChunks) chunks waiting"
                s.status.uncommittedSamples += block.sampleCount
                commands.yield(.finish(.error, endedAt: block.drainedAtMonotonicNanos))
                return .refused(.error)
            }
            s.pendingSamples += block.sampleCount
            s.status.backlogChunks = s.pendingSamples / options.samplesPerChunk
            commands.yield(.block(block))
            return .accepted
        }
    }

    /// Closes the current segment (flushing its partial chunk) after a disconnect; adds a
    /// `gap` after its last committed sample. Call `beginSegment` when the stream resumes.
    public func endSegment(_ reason: EndReason, endedAtMonotonicNanos: Int64, gap: GapEvidence? = .disconnect) {
        enqueue(.endSegment(reason, endedAt: endedAtMonotonicNanos, gap: gap))
    }

    /// Opens the next segment (index + 1, sample indices from 0, same session and run).
    public func beginSegment(startedAtWall: Date, startedAtMonotonicNanos: Int64) {
        enqueue(.beginSegment(wall: startedAtWall, monotonic: startedAtMonotonicNanos))
    }

    /// Stops: commits everything accepted (partial last chunk included), closes the open
    /// segment with `reason`, and returns the final status. Idempotent.
    @discardableResult
    public func finish(_ reason: EndReason = .stopped, endedAtMonotonicNanos: Int64 = HostMonotonicClock.nowNanos()) async -> Status {
        enqueue(.finish(reason, endedAt: endedAtMonotonicNanos))
        await consumer.value
        return status
    }

    private func enqueue(_ command: WriterCommand) {
        shared.state.withLock { s in
            if s.accepting { commands.yield(command) }
            if case .finish = command { s.accepting = false }
        }
    }

    /// Available bytes for an unprivileged writer on `url`'s volume (`statfs` `f_bavail`).
    public static func freeBytes(at url: URL) -> Int64? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }
}

enum WriterCommand: Sendable {
    case block(RecordingWriter.Block)
    case endSegment(EndReason, endedAt: Int64, gap: GapEvidence?)
    case beginSegment(wall: Date, monotonic: Int64)
    case finish(EndReason, endedAt: Int64)
}

/// State the producer and the consumer share, behind one lock.
final class WriterShared: Sendable {
    struct State {
        var status = RecordingWriter.Status()
        var pendingSamples = 0        // accepted, not yet committed (queued or buffered)
        var accepting = true
    }
    let state = Mutex(State())
}

/// The consumer's state: per-row buffers of accepted, uncommitted samples of the open
/// segment, and the segment list the next manifest rewrite carries. Runs on one task.
private struct Assembler {
    let writer: ChunkWriter
    var segments: [RecordingManifest.StreamSegment]
    let counterRow: Int?
    let options: RecordingWriter.Options
    let shared: WriterShared
    let lock: RecordingLock
    /// True when the last segment could not be closed on disk (see `close`).
    var leftOpen = false
    /// Samples counted against an already-closed segment, not yet in a manifest rewrite.
    var unsavedAttribution = false
    var rows: [[Double]] = []
    var drainedAt: [Int64] = []            // per buffered sample: its block's drain time
    var committedInSegment = 0             // also the segment index of the first buffered sample
    var acceptedInSegment = 0
    var pendingGaps: [RecordingManifest.Gap] = []
    var segmentOpen = true
    var attributedLoss = 0

    init(writer: ChunkWriter, segments: [RecordingManifest.StreamSegment], counterRow: Int?, options: RecordingWriter.Options,
         shared: WriterShared, lock: RecordingLock) {
        self.writer = writer; self.segments = segments; self.counterRow = counterRow; self.options = options
        self.shared = shared; self.lock = lock
    }

    private var buffered: Int { drainedAt.count }

    /// Returns false once the recording has ended.
    mutating func handle(_ command: WriterCommand) async -> Bool {
        switch command {
        case .block(let block):
            guard segmentOpen, rows.isEmpty || rows.count == block.rowCount else {
                // No open segment, or a different board shape: received, never committed.
                let n = block.sampleCount
                shared.state.withLock { $0.pendingSamples -= n; $0.status.uncommittedSamples += n }
                if !segmentOpen {
                    // Drained after its segment closed (before `beginSegment`): it belongs to
                    // that segment's stream, so it is counted there, on the next rewrite.
                    segments[segments.count - 1].uncommittedSampleCount = (segments[segments.count - 1].uncommittedSampleCount ?? 0) + n
                    attributedLoss += n
                    unsavedAttribution = true
                }
                return true
            }
            append(block)
            while buffered >= options.samplesPerChunk {
                guard await commit(options.samplesPerChunk) else { return false }
            }
            return true
        case .endSegment(let reason, let endedAt, let gap):
            guard segmentOpen else { return true }
            return await flushAndClose(reason, endedAt: endedAt, gap: gap, final: false)
        case .beginSegment(let wall, let monotonic):
            if segmentOpen, !(await flushAndClose(.disconnect, endedAt: monotonic, gap: .disconnect, final: false)) { return false }
            let last = segments.last!
            segments.append(.init(index: last.index + 1, sessionID: last.sessionID, runID: last.runID, startedAtWall: wall,
                                  startedAtMonotonicNanos: monotonic, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: []))
            committedInSegment = 0; acceptedInSegment = 0; segmentOpen = true
            return true
        case .finish(let reason, let endedAt):
            if segmentOpen {
                _ = await flushAndClose(reason, endedAt: endedAt, gap: nil, final: true)
            } else {
                shared.state.withLock { $0.status.endReason = $0.status.endReason ?? reason }
                if unsavedAttribution { _ = await save() }
            }
            return false
        }
    }

    private mutating func append(_ block: RecordingWriter.Block) {
        if rows.isEmpty { rows = Array(repeating: [], count: block.rowCount) }
        for r in 0..<block.rowCount {
            rows[r].append(contentsOf: block.values[(r * block.sampleCount)..<((r + 1) * block.sampleCount)])
        }
        drainedAt.append(contentsOf: repeatElement(block.drainedAtMonotonicNanos, count: block.sampleCount))
        for var gap in block.gaps {
            gap.afterSampleIndex += acceptedInSegment
            pendingGaps.append(gap)
        }
        acceptedInSegment += block.sampleCount
    }

    /// Commits the first `n` buffered samples as one chunk; on failure stops the recording.
    private mutating func commit(_ n: Int) async -> Bool {
        let started = HostMonotonicClock.nowNanos()
        guard let free = options.freeBytes(writer.directory) else {
            // Fail safe: a guard that cannot see the disk is not a pass.
            return await stop(.error, "Free space on the recording volume could not be read")
        }
        if free < options.minimumFreeBytes {
            return await stop(.diskFull, "Free space \(free / 1_048_576) MB is under \(options.minimumFreeBytes / 1_048_576) MB")
        }
        let end = committedInSegment + n
        // A gap is published once the sample after it is committed: the gap is evidenced by it.
        var next = segments
        let (ready, later) = (pendingGaps.filter { $0.afterSampleIndex + 1 < end }, pendingGaps.filter { $0.afterSampleIndex + 1 >= end })
        next[next.count - 1].detectedGaps += ready
        let payload = ChunkPayload(samples: rows.flatMap { $0.prefix(n) }, rowCount: rows.count, sampleCount: n,
                                   segment: segments.last!.index, firstSampleIndex: committedInSegment,
                                   drainedAtMonotonicNanos: drainedAt[n - 1],
                                   firstBrainflowTimestamp: value(options.timestampRow, 0), lastBrainflowTimestamp: value(options.timestampRow, n - 1),
                                   firstPackageNumber: value(counterRow, 0).flatMap { Int(exactly: $0) },
                                   lastPackageNumber: value(counterRow, n - 1).flatMap { Int(exactly: $0) })
        let listedBefore = await writer.manifest.chunks.count
        do {
            try await writer.append(payload, segments: next)
        } catch {
            // The disk manifest is the truth: the chunk counts as committed only if it lists
            // it. Anything it does not list (temp file, renamed chunk) is removed, freeing space.
            if await writer.reconcileWithDisk() > listedBefore { consumed(n, ready: next, later: later, started: started) }
            return await stop(Self.isDiskFull(error) ? .diskFull : .error, "\(error)")
        }
        consumed(n, ready: next, later: later, started: started)
        return true
    }

    private func value(_ row: Int?, _ column: Int) -> Double? {
        guard let row, rows.indices.contains(row) else { return nil }
        return rows[row][column]
    }

    private mutating func consumed(_ n: Int, ready: [RecordingManifest.StreamSegment], later: [RecordingManifest.Gap], started: Int64) {
        segments = ready
        pendingGaps = later
        for r in rows.indices { rows[r].removeFirst(n) }
        drainedAt.removeFirst(n)
        committedInSegment += n
        let now = HostMonotonicClock.nowNanos()
        shared.state.withLock { s in
            s.pendingSamples -= n
            s.status.backlogChunks = s.pendingSamples / options.samplesPerChunk
            s.status.committedChunks += 1
            s.status.committedSamples += n
            s.status.lastCommitMonotonicNanos = now
            s.status.recentCommitDurationsNanos.append(now - started)
            if s.status.recentCommitDurationsNanos.count > 100 { s.status.recentCommitDurationsNanos.removeFirst() }
        }
    }

    /// Commits every buffered sample (the partial last chunk too), then closes the segment.
    private mutating func flushAndClose(_ reason: EndReason, endedAt: Int64, gap: GapEvidence?, final: Bool) async -> Bool {
        while buffered > 0 {
            guard await commit(min(buffered, options.samplesPerChunk)) else { return false }
        }
        if final { shared.state.withLock { $0.status.endReason = reason; $0.accepting = false } }
        return await close(reason, endedAt: endedAt, gap: gap) || !final
    }

    /// Disk full or a write error: nothing more is written; everything accepted but not
    /// committed is counted, and the segment is closed with the reason.
    private mutating func stop(_ reason: EndReason, _ why: String) async -> Bool {
        shared.state.withLock { s in
            s.accepting = false
            s.status.endReason = reason
            s.status.failure = why
            s.status.uncommittedSamples += s.pendingSamples
            s.pendingSamples = 0
            s.status.backlogChunks = 0
        }
        rows = []; drainedAt = []
        _ = await close(reason, endedAt: HostMonotonicClock.nowNanos(), gap: nil)
        return false
    }

    private mutating func close(_ reason: EndReason, endedAt: Int64, gap: GapEvidence?) async -> Bool {
        var seg = segments[segments.count - 1]
        seg.endReason = reason
        seg.endedAtMonotonicNanos = endedAt
        seg.detectedGaps += pendingGaps.filter { $0.afterSampleIndex < committedInSegment }
        if let gap {
            seg.detectedGaps.append(.init(afterSampleIndex: committedInSegment - 1, evidence: gap, estimatedMissingSamples: nil, ambiguous: false))
        }
        let lost = shared.state.withLock { $0.status.uncommittedSamples } - attributedLoss
        if lost > 0 { seg.uncommittedSampleCount = (seg.uncommittedSampleCount ?? 0) + lost; attributedLoss += lost }
        segments[segments.count - 1] = seg
        pendingGaps = []
        segmentOpen = false
        if await save() { return true }
        // Still open on disk. Leave the reason in the lock file, so the next
        // `ProjectStore.open` closes it with this reason rather than process_terminated.
        leftOpen = true
        lock.note(reason, uncommitted: seg.uncommittedSampleCount ?? 0)
        return false
    }

    /// Rewrites the segment list; on failure frees what the disk manifest does not list and
    /// retries once (a full disk usually has room again once the failed chunk is gone).
    private mutating func save() async -> Bool {
        for attempt in 0..<2 {
            do {
                try await writer.updateSegments(segments)
                unsavedAttribution = false
                return true
            } catch {
                if attempt == 0 { _ = await writer.reconcileWithDisk(); continue }
                shared.state.withLock { $0.status.failure = ($0.status.failure.map { $0 + "; " } ?? "") + "segment \(segments.last!.index) not closed: \(error)" }
            }
        }
        return false
    }

    static func isDiskFull(_ error: Error) -> Bool {
        if case ProjectStoreError.io(_, let code) = error { return code == ENOSPC || code == EDQUOT }
        return false
    }
}
