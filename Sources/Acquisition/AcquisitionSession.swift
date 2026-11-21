import Foundation
import Synchronization

/// One live board session (brief 004): the PRD §7 state machine, the drain loop, fan-out to
/// the recording, preview and health, and interruption with auto-reconnect (decision #32).
///
/// The drain loop is the only reader of the board. It never waits on its consumers: the
/// writer's `submit` returns at once (its own bounded queue reports backlog and stops the
/// recording rather than dropping), the preview is a newest-wins stream that may drop
/// frames, and health and state are published behind a lock the UI reads without touching
/// this actor.
public actor AcquisitionSession {
    public enum State: Sendable, Equatable {
        case disconnected, connecting, ready, streaming
        /// No samples for `noSampleTimeout`, or a read error; auto-retry is running.
        case interrupted(reason: String)
        case stopping
        case failed(reason: String)
    }

    public struct Options: Sendable {
        public var drainInterval: Duration = .milliseconds(50)
        public var noSampleTimeout: Duration = .seconds(3)
        public var retryWindow: Duration = .seconds(30)        // decision #32
        public var retryInterval: Duration = .seconds(1)
        public var bufferSize: Int32 = 45_000                  // 6 min at 125 Hz
        public var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        /// Writer options (fault hooks in tests); the timestamp row is set from the board.
        public var writer = RecordingWriter.Options()
        public init() {}
    }

    /// Everything the screens show, readable from any thread without an actor hop.
    public struct Snapshot: Sendable, Equatable {
        public var state: State = .disconnected
        public var health = StreamHealth()
        public var recordingID: UUID?
        public var holdsPowerAssertion = false
        /// The last recording that ended (stopped, or ended itself on disk full / error).
        public var lastRecordingEnd: RecordingWriter.Status?
    }

    /// The declared parts of a recording; the session fills in source, timing and clocks.
    public struct RecordingRequest: Sendable {
        public var channels: [ChannelSpec]
        public var reference: String
        public var montage: String
        public var boardConfiguration = RecordingManifest.BoardConfiguration(requested: [:], readback: [:])
        public var sessionID = UUID().uuidString
        public var runID = UUID().uuidString

        public init(channels: [ChannelSpec], reference: String, montage: String) {
            self.channels = channels; self.reference = reference; self.montage = montage
        }
    }

    public struct PreviewFrame: Sendable {
        public var segment: Int
        public var chunk: SampleChunk
    }

    public enum SessionError: Error, Equatable { case notStreaming, alreadyRecording, streamEnded }

    public nonisolated let source: AcquisitionSource
    /// Newest-wins: a slow preview loses frames, never the recording.
    public nonisolated let preview: AsyncStream<PreviewFrame>
    private nonisolated let previewSink: AsyncStream<PreviewFrame>.Continuation
    private nonisolated let published = Mutex(Snapshot())
    public nonisolated var snapshot: Snapshot { published.withLock { $0 } }

    private let options: Options
    private let makeBoard: @Sendable () throws -> any AcquisitionBoard
    private let projectDirectory: URL?
    private var board: (any AcquisitionBoard)?
    private var accounting: SequenceAccounting?
    private var health: HealthAccumulator?
    private var writer: RecordingWriter?
    private var power: PowerAssertion?
    private var run: Task<Void, Never>?
    private var hasStreamed = false
    private var lastSampleNanos: Int64 = 0
    private var lastPublishNanos: Int64 = 0

    /// `projectDirectory` is where free space is measured. `makeBoard` replaces the source's
    /// board (tests); it is called once per connect and once per reconnect attempt.
    public init(source: AcquisitionSource, projectDirectory: URL?, options: Options = .init(),
                makeBoard: (@Sendable () throws -> any AcquisitionBoard)? = nil) {
        self.source = source
        self.projectDirectory = projectDirectory
        self.options = options
        self.makeBoard = makeBoard ?? { try source.makeBoard() }
        (preview, previewSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    deinit { previewSink.finish() }

    public var state: State { snapshot.state }

    // MARK: Commands (the state table's buttons)

    /// disconnected / failed-before-streaming → connecting → ready, or failed.
    public func connect() async {
        guard state == .disconnected || (isFailed && !hasStreamed) else { return }
        set(.connecting)
        do {
            let b = try makeBoard()
            board = b
            try await b.prepare()
            guard state == .connecting else { return }     // disconnected meanwhile
            set(.ready)
        } catch {
            await releaseBoard()
            if state == .connecting { set(.failed(reason: Self.describe(error))) }
        }
    }

    /// ready → streaming (start preview).
    public func startStreaming() async {
        guard state == .ready, let board else { return }
        do {
            try await board.startStream(bufferSize: options.bufferSize)
        } catch {
            await releaseBoard()
            return set(.failed(reason: Self.describe(error)))
        }
        guard state == .ready else { return }
        hasStreamed = true
        beginStreamSegment(board, reconnect: false)
        set(.streaming)
        run = Task { await self.drainAndRecover() }
    }

    /// Starts recording into `store` (streaming only). Returns the recording id.
    @discardableResult
    public func startRecording(_ request: RecordingRequest, in store: ProjectStore) async throws -> UUID {
        guard state == .streaming, let board else { throw SessionError.notStreaming }
        guard writer == nil else { throw SessionError.alreadyRecording }
        let d = board.description
        let (wall, now) = (Date(), HostMonotonicClock.nowNanos())
        let manifest = RecordingManifest(
            recordingID: UUID(), sessionID: request.sessionID, runID: request.runID, createdAt: wall,
            source: source.recordingSource(d, appVersion: options.appVersion), channels: request.channels,
            reference: request.reference, montage: request.montage,
            timing: .init(nominalSampleRateHz: Double(d.samplingRate), timestampClock: .brainflowReceipt, timestampGeneratedBy: "host",
                          sequenceCounterRow: d.packageNumRow, sequenceStep: d.sequenceStep, notes: Self.timingNotes(source)),
            clockMapping: .init(anchorMonotonicNanos: now, anchorWall: wall),
            boardConfiguration: request.boardConfiguration, chunks: [], segments: [])
        var writerOptions = options.writer
        writerOptions.timestampRow = d.timestampRow
        let w = try await RecordingWriter.start(in: store, manifest: manifest, startedAtWall: wall,
                                                startedAtMonotonicNanos: now, options: writerOptions)
        guard state == .streaming, writer == nil else {
            await w.finish(state == .streaming ? .stopped : .disconnect)
            throw SessionError.streamEnded
        }
        writer = w
        power = PowerAssertion.take("Recording EEG")
        published.withLock { $0.recordingID = w.recordingID; $0.holdsPowerAssertion = power != nil }
        return w.recordingID
    }

    /// Stops the recording (segment `stopped`, partial chunk flushed); streaming continues.
    @discardableResult
    public func stopRecording() async -> RecordingWriter.Status? {
        guard let w = writer else { return nil }
        if let board, state == .streaming, let chunk = try? await board.readAll() { process(chunk, board) }
        guard writer === w else { return nil }
        writer = nil
        let status = await w.finish(.stopped)
        endRecording(status)
        return status
    }

    /// Any state → stopping → disconnected. Drains what BrainFlow still holds, closes the
    /// recording `stopped`, releases the board.
    public func disconnect() async {
        guard state != .disconnected, state != .stopping else { return }
        let wasStreaming = state == .streaming
        set(.stopping)
        run?.cancel()
        await run?.value
        run = nil
        if wasStreaming, let board, let chunk = try? await board.readAll() { process(chunk, board) }
        if let w = writer {
            writer = nil
            endRecording(await w.finish(.stopped))
        }
        await releaseBoard()
        hasStreamed = false
        set(.disconnected)
    }

    /// "Reconnect now" (interrupted) or "Retry" (failed): a fresh 30 s retry window. A
    /// failed connect retries the connect itself.
    public func reconnect() async {
        if isFailed && !hasStreamed { return await connect() }
        guard isFailed || isInterrupted else { return }
        run?.cancel()
        await run?.value
        await releaseBoard()
        run = Task {
            guard await self.reconnectWithinWindow() else { return }
            await self.drainAndRecover()
        }
    }

    // MARK: Drain loop

    /// Drains until cancelled; on an interruption closes the segment, retries, and resumes.
    private func drainAndRecover() async {
        while !Task.isCancelled {
            // A read failing because Disconnect is tearing down is not an interruption.
            guard let reason = await drainUntilInterrupted(), !Task.isCancelled else { return }
            await interrupt(reason)
            guard await reconnectWithinWindow() else { return }
        }
    }

    /// Returns the interruption reason, or nil when cancelled.
    private func drainUntilInterrupted() async -> String? {
        let timeout = Self.nanos(options.noSampleTimeout)
        while !Task.isCancelled, let board {
            let chunk: SampleChunk
            do { chunk = try await board.readAll() } catch { return "Read failed: \(Self.describe(error))" }
            // Process before looking at cancellation: drained samples always reach the writer.
            process(chunk, board)
            if chunk.count == 0, chunk.drainedAtMonotonicNanos - lastSampleNanos >= timeout {
                return "No samples for \(Self.seconds(options.noSampleTimeout)) s"
            }
            try? await Task.sleep(for: options.drainInterval)
        }
        return nil
    }

    private func process(_ chunk: SampleChunk, _ board: any AcquisitionBoard) {
        guard var accounting, var health else { return }
        let d = board.description
        var block = RecordingWriter.Block(chunk, findings: chunk.count == 0 ? [] :
            accounting.ingest(counters: chunk.row(d.packageNumRow), timestamps: chunk.row(d.timestampRow)))
        if let pause = health.ingest(chunk, gaps: block.gaps) { block.gaps.insert(pause, at: 0) }
        self.accounting = accounting
        self.health = health
        if chunk.count > 0 {
            lastSampleNanos = chunk.drainedAtMonotonicNanos
            previewSink.yield(.init(segment: health.health.segment, chunk: chunk))
            if let w = writer, case .refused = w.submit(block) {
                // The writer stopped itself (disk full, backlog, write error); preview goes on.
                writer = nil
                Task.detached { [weak self] in
                    let status = await w.finish()
                    await self?.endRecording(status)
                }
            }
        }
        publishHealth(force: false)
    }

    /// streaming → interrupted: the segment closes with a `disconnect` gap; the board goes.
    private func interrupt(_ reason: String) async {
        set(.interrupted(reason: reason))
        writer?.endSegment(.disconnect, endedAtMonotonicNanos: lastSampleNanos)
        health?.noteGap(.disconnect)
        publishHealth(force: true)
        await releaseBoard()
    }

    /// Tries a new board every `retryInterval` until `retryWindow` passes. Success starts a
    /// new segment (counters reset, nothing joined); exhaustion → failed.
    private func reconnectWithinWindow() async -> Bool {
        let deadline = HostMonotonicClock.nowNanos() + Self.nanos(options.retryWindow)
        var lastError = "no attempt made"
        if !isInterrupted { set(.interrupted(reason: "Reconnecting")) }
        while !Task.isCancelled {
            do {
                let b = try makeBoard()
                board = b
                try await b.prepare()
                try await b.startStream(bufferSize: options.bufferSize)
                guard !Task.isCancelled else { return false }
                beginStreamSegment(b, reconnect: true)
                writer?.beginSegment(startedAtWall: Date(), startedAtMonotonicNanos: HostMonotonicClock.nowNanos())
                set(.streaming)
                return true
            } catch {
                lastError = Self.describe(error)
                await releaseBoard()
            }
            guard HostMonotonicClock.nowNanos() < deadline else { break }
            try? await Task.sleep(for: options.retryInterval)
        }
        if !Task.isCancelled {
            set(.failed(reason: "Reconnect failed for \(Self.seconds(options.retryWindow)) s: \(lastError)"))
        }
        return false
    }

    // MARK: Helpers

    private func beginStreamSegment(_ board: any AcquisitionBoard, reconnect: Bool) {
        if accounting == nil || health == nil || !reconnect {
            accounting = SequenceAccounting(board: board.description)
            health = HealthAccumulator(board: board.description)
        }
        accounting?.reset()
        health?.beginSegment(reconnect: reconnect)
        lastSampleNanos = HostMonotonicClock.nowNanos()
        publishHealth(force: true)
    }

    private func releaseBoard() async {
        if let b = board { board = nil; try? await b.release() }
    }

    private func endRecording(_ status: RecordingWriter.Status) {
        power?.release()
        power = nil
        published.withLock { $0.recordingID = nil; $0.holdsPowerAssertion = false; $0.lastRecordingEnd = status }
    }

    /// At most once a second (the panel's rate), or at once on a state change.
    private func publishHealth(force: Bool) {
        let now = HostMonotonicClock.nowNanos()
        guard force || now - lastPublishNanos >= 1_000_000_000, let health else { return }
        lastPublishNanos = now
        var h = health.snapshot()
        h.writer = writer?.status
        if let dir = projectDirectory, let free = RecordingWriter.freeBytes(at: dir), let board {
            let bytesPerHour = Double(board.description.numRows * 8 * board.description.samplingRate) * 3600
            h.freeBytes = free
            h.hoursLeft = max(0, Double(free - RecordingWriter.minimumFreeBytes) / bytesPerHour)
        }
        published.withLock { $0.health = h }
    }

    private func set(_ s: State) { published.withLock { $0.state = s } }
    private var isFailed: Bool { if case .failed = state { true } else { false } }
    private var isInterrupted: Bool { if case .interrupted = state { true } else { false } }

    static func describe(_ error: Error) -> String {
        (error as? BrainFlowError)?.description ?? "\(error)"
    }

    static func timingNotes(_ source: AcquisitionSource) -> String {
        if case .playback = source { return "Playback: timestamps are the played file's own (old_timestamps), not the time of replay." }
        return "BrainFlow timestamps are host wall clock at packet parse; gaps come from package counters only."
    }

    static func nanos(_ d: Duration) -> Int64 { d.components.seconds * 1_000_000_000 + d.components.attoseconds / 1_000_000_000 }
    static func seconds(_ d: Duration) -> String { String(format: "%g", Double(nanos(d)) / 1e9) }
}
