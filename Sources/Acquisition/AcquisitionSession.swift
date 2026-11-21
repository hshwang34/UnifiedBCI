import Foundation
import OSLog
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
        /// The connected board's layout and what was sent / read back on the last
        /// connect or reconnect (brief 004, "Configuration").
        public var board: BoardDescription?
        public var configuration: RecordingManifest.BoardConfiguration?
        /// Set when a reconnect found the board configured differently from what the
        /// recording describes, so the recording was ended rather than continued.
        public var recordingEndedByReconnect: ConfigurationProblem?
        /// A protocol run's segment is open (brief 005); false between runs and outside them.
        public var runSegmentOpen = false
    }

    /// Why a board configuration can't carry a recording (µV scaling would be wrong or
    /// unconfirmed), or how it changed across a reconnect.
    public enum ConfigurationProblem: Sendable, Equatable {
        case gainMismatch(channel: Int, gain: String)
        case notAcknowledged(channel: Int)
        case changedOnReconnect
    }

    /// The declared parts of a recording; the session fills in source, timing, clocks and
    /// board configuration.
    public struct RecordingRequest: Sendable {
        public var channels: [ChannelSpec]
        public var reference: String
        public var montage: String
        public var sessionID = UUID().uuidString
        public var runID = UUID().uuidString

        public init(channels: [ChannelSpec], reference: String, montage: String) {
            self.channels = channels; self.reference = reference; self.montage = montage
        }

        /// From a confirmed map, or the defaults for "Record without positions" (decision #31).
        public init(map: ChannelMapRecord) {
            self.init(channels: map.channels, reference: map.reference, montage: map.montage)
        }
    }

    public struct PreviewFrame: Sendable {
        public var segment: Int
        public var chunk: SampleChunk
    }

    /// One drained chunk for live inference (brief 006): the fourth consumer of the drain.
    /// `firstSample` counts from the stream segment's start, so a consumer that lost frames
    /// (its buffer is newest-wins) sees the jump and treats it as a discontinuity.
    public struct InferenceFrame: Sendable {
        public var segment: Int
        public var firstSample: Int
        public var chunk: SampleChunk
        /// Detected gaps, `afterSampleIndex` relative to this chunk (-1 = before its first sample).
        public var gaps: [RecordingManifest.Gap]
        /// Monotonic and wall clock read together at drain (BrainFlow buffer wait).
        public var clockPair: RecordingWriter.ClockPair?
    }

    public enum SessionError: Error, Equatable {
        case notStreaming, alreadyRecording, streamEnded
        case configuration(ConfigurationProblem)
        /// The map's channels aren't exactly this board's EEG rows.
        case channelMapMismatch(mapChannels: Int, boardChannels: Int)
    }

    public nonisolated let source: AcquisitionSource
    /// Newest-wins: a slow preview loses frames, never the recording.
    public nonisolated let preview: AsyncStream<PreviewFrame>
    private nonisolated let previewSink: AsyncStream<PreviewFrame>.Continuation
    private nonisolated let published = Mutex(Snapshot())
    public nonisolated var snapshot: Snapshot { published.withLock { $0 } }
    private nonisolated let inferenceSinks = Mutex<[UUID: AsyncStream<InferenceFrame>.Continuation]>([:])
    /// Samples drained in the current stream segment (the next frame's `firstSample`).
    private var segmentSamples = 0

    /// Subscribes a live-inference consumer. Never blocks the drain: each subscriber has its
    /// own buffer of `buffer` frames (≈ 50 ms each) that drops the oldest when full.
    public nonisolated func inferenceFrames(buffer: Int = 64) -> (id: UUID, frames: AsyncStream<InferenceFrame>) {
        let (stream, sink) = AsyncStream.makeStream(of: InferenceFrame.self, bufferingPolicy: .bufferingNewest(max(1, buffer)))
        let id = UUID()
        inferenceSinks.withLock { $0[id] = sink }
        return (id, stream)
    }

    public nonisolated func removeInferenceConsumer(_ id: UUID) {
        inferenceSinks.withLock { $0.removeValue(forKey: id) }?.finish()
    }

    private let options: Options
    private let makeBoard: @Sendable () throws -> any AcquisitionBoard
    private let projectDirectory: URL?
    /// Set only once a board is prepared (and, after a reconnect, streaming).
    private var board: (any AcquisitionBoard)?
    /// The last board's layout, kept while interrupted for the free-space figures.
    private var lastDescription: BoardDescription?
    private var accounting: SequenceAccounting?
    private var health: HealthAccumulator?
    private var writer: RecordingWriter?
    private var power: PowerAssertion?
    private var run: Task<Void, Never>?
    private var hasStreamed = false
    /// Bumped by every lifecycle command; a call resuming from an await under an older
    /// generation was overtaken (Cancel, Disconnect, Retry) and must undo, not apply.
    private var generation = 0
    /// Set synchronously before the first await of `startStreaming` / `reconnect`, so a
    /// second press while the first is in flight is ignored.
    private var starting = false
    private var reconnecting = false
    private var recordingStarting = false
    /// Bumped whenever streaming ends or restarts, so a recording that finishes starting
    /// after an interruption is not attached to a different segment.
    private var recordingStarts = 0
    /// The newest recording started; only its end is published (a late finish of an older
    /// one never overwrites it).
    private var latestRecordingID: UUID?
    /// The configuration the current recording's manifest stores; every segment must match it.
    private var recordingConfiguration: RecordingManifest.BoardConfiguration?
    /// Recordings detached from the session whose writer is still committing its last
    /// chunk and closing the segment. Disconnect (window close, quit) waits for all of them.
    private var finishing: [UUID: Task<RecordingWriter.Status, Never>] = [:]
    /// The Disconnect in progress; a second one waits for it instead of returning early.
    private var disconnecting: Task<Void, Never>?
    private var lastSampleNanos: Int64 = 0
    private var lastPublishNanos: Int64 = 0
    /// The recording is kept between protocol runs with its segment closed: drained blocks
    /// are not recorded until the next run's segment opens (brief 005).
    private var betweenRuns = false

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

    deinit {
        previewSink.finish()
        inferenceSinks.withLock { $0.values.forEach { $0.finish() } }
        power?.release()
    }

    public var state: State { snapshot.state }

    // MARK: Commands (the state table's buttons)

    /// disconnected / failed-before-streaming → connecting → ready, or failed.
    public func connect() async {
        guard state == .disconnected || (isFailed && !hasStreamed) else { return }
        generation += 1
        let gen = generation
        set(.connecting)
        var attempt: (any AcquisitionBoard)?
        let configuration: RecordingManifest.BoardConfiguration
        do {
            let b = try makeBoard()
            attempt = b
            try await b.prepare()
            configuration = try await source.applyDefaultConfiguration(to: b)
        } catch {
            if let attempt { await Self.release(attempt) }
            if gen == generation { set(.failed(reason: Self.describe(error))) }
            return
        }
        guard gen == generation, let b = attempt else {             // cancelled meanwhile
            if let attempt { await Self.release(attempt) }
            return
        }
        board = b
        lastDescription = b.description
        published.withLock { $0.board = b.description; $0.configuration = configuration }
        set(.ready)
    }

    /// ready → streaming (start preview).
    public func startStreaming() async {
        guard state == .ready, !starting, let board else { return }
        starting = true
        defer { starting = false }
        let gen = generation
        do {
            try await board.startStream(bufferSize: options.bufferSize)
        } catch {
            guard gen == generation else { return }
            await releaseBoard()
            guard gen == generation else { return }     // Disconnect during the release
            return set(.failed(reason: Self.describe(error)))
        }
        guard gen == generation, state == .ready else { return }
        hasStreamed = true
        beginStreamSegment(board, reconnect: false)
        set(.streaming)
        run = Task { await self.drainAndRecover() }
    }

    /// Starts recording into `store` (streaming only). Returns the recording id.
    @discardableResult
    public func startRecording(_ request: RecordingRequest, in store: ProjectStore) async throws -> UUID {
        guard state == .streaming, let board else { throw SessionError.notStreaming }
        guard writer == nil, !recordingStarting else { throw SessionError.alreadyRecording }
        let configuration = snapshot.configuration ?? .init(requested: [:], readback: [:])
        if let problem = Self.problem(configuration, isDevice: source.readsBackRegisters) { throw SessionError.configuration(problem) }
        let map = ChannelMapRecord(montage: request.montage, reference: request.reference, channels: request.channels)
        guard map.fits(board.description), Set(request.channels.map(\.id)).count == request.channels.count else {
            throw SessionError.channelMapMismatch(mapChannels: request.channels.count, boardChannels: board.description.eegChannelRows.count)
        }
        recordingStarting = true
        defer { recordingStarting = false }
        let starts = recordingStarts
        let d = board.description
        let (wall, now) = (Date(), HostMonotonicClock.nowNanos())
        let manifest = RecordingManifest(
            recordingID: UUID(), sessionID: request.sessionID, runID: request.runID, createdAt: wall,
            source: source.recordingSource(d, appVersion: options.appVersion), channels: request.channels,
            reference: request.reference, montage: request.montage,
            timing: .init(nominalSampleRateHz: Double(d.samplingRate), timestampClock: .brainflowReceipt, timestampGeneratedBy: "host",
                          sequenceCounterRow: d.packageNumRow, sequenceStep: d.sequenceStep, notes: Self.timingNotes(source),
                          markerRow: d.markerRow),
            clockMapping: .init(anchorMonotonicNanos: now, anchorWall: wall),
            boardConfiguration: configuration, chunks: [], segments: [])
        var writerOptions = options.writer
        writerOptions.timestampRow = d.timestampRow
        writerOptions.markerRow = d.markerRow
        let w = try await RecordingWriter.start(in: store, manifest: manifest, startedAtWall: wall,
                                                startedAtMonotonicNanos: now, options: writerOptions)
        latestRecordingID = w.recordingID
        guard state == .streaming, writer == nil, recordingStarts == starts else {
            _ = await finish(w, state == .streaming ? .stopped : .disconnect).value
            throw SessionError.streamEnded
        }
        writer = w
        recordingConfiguration = configuration
        published.withLock { $0.recordingEndedByReconnect = nil }
        power?.release()
        power = PowerAssertion.take("Recording EEG")
        published.withLock { $0.recordingID = w.recordingID; $0.holdsPowerAssertion = power != nil }
        return w.recordingID
    }

    /// Stops the recording (segment `stopped`, partial chunk flushed); streaming continues.
    /// It ends at the last drain (≤ `drainInterval` ago): only the drain loop reads the
    /// board, so counters are never seen out of order.
    @discardableResult
    public func stopRecording() async -> RecordingWriter.Status? {
        guard let w = detachRecording() else { return nil }
        return await finish(w, .stopped).value
    }

    /// Any state → stopping → disconnected. Drains what BrainFlow still holds, closes the
    /// recording `stopped`, releases the board.
    /// Returns only once every recording has finished (last chunk committed, segment
    /// closed), including one a Stop detached just before; a second call waits for the first.
    public func disconnect() async {
        if let running = disconnecting { return await running.value }
        let t = Task { await self.performDisconnect() }
        disconnecting = t
        await t.value
        disconnecting = nil
    }

    private func performDisconnect() async {
        guard state != .disconnected, state != .stopping else { return await awaitFinishing() }
        generation += 1
        recordingStarts += 1
        let wasStreaming = state == .streaming
        set(.stopping)
        let task = run
        run = nil
        task?.cancel()
        await task?.value
        // The drain loop has ended, so this is the only reader now: take what BrainFlow holds.
        if wasStreaming, let board, let chunk = try? await board.readAll() { process(chunk, board) }
        if let w = detachRecording() { _ = await finish(w, .stopped).value }
        await awaitFinishing()
        await releaseBoard()
        hasStreamed = false
        reconnecting = false
        published.withLock { $0.board = nil; $0.configuration = nil }
        set(.disconnected)
    }

    /// "Reconnect now" (interrupted) or "Retry" (failed): a fresh 30 s retry window. A
    /// failed connect retries the connect itself.
    ///
    /// A press while the previous loop is being handed over (cancelled, not yet finished) is
    /// ignored. A press once the new attempt loop runs replaces that loop with a fresh one,
    /// which restarts the window: "Reconnect now" means "start the 30 s again".
    public func reconnect() async {
        if isFailed && !hasStreamed { return await connect() }
        guard isFailed || isInterrupted, !reconnecting else { return }
        reconnecting = true
        generation += 1
        let gen = generation
        set(.interrupted(reason: "Reconnecting"))
        // `run` stays set until the old loop has finished, so a Disconnect arriving now
        // waits for it too, and no Connect can open a second session while it still prepares.
        let task = run
        task?.cancel()
        await task?.value
        // Disconnect meanwhile: it already cleared `reconnecting`, which may now belong to
        // a newer press, so leave it alone.
        guard gen == generation else { return }
        await releaseBoard()
        guard gen == generation else { return }
        reconnecting = false
        run = Task {
            guard await self.reconnectWithinWindow() else { return }
            await self.drainAndRecover()
        }
    }

    // MARK: Protocol runs (brief 005)

    /// Opens a protocol run's segment: the first run starts the recording (`request` with
    /// this run and session id), a later one opens the next segment of it, under its own run
    /// id. Streaming only. Returns the recording id.
    public func beginRunSegment(runID: String, sessionID: String, request: RecordingRequest, in store: ProjectStore) async throws -> UUID {
        guard state == .streaming else { throw SessionError.notStreaming }
        if let w = writer {
            guard betweenRuns else { throw SessionError.alreadyRecording }
            betweenRuns = false
            w.beginSegment(startedAtWall: Date(), startedAtMonotonicNanos: HostMonotonicClock.nowNanos(), runID: runID)
            published.withLock { $0.runSegmentOpen = true }
            return w.recordingID
        }
        var r = request
        r.runID = runID
        r.sessionID = sessionID
        let id = try await startRecording(r, in: store)
        published.withLock { $0.runSegmentOpen = true }
        return id
    }

    /// Closes the run's segment `stopped` at the last drain; the stream, the preview and the
    /// recording go on (decision: "one contiguous recorded span" per run).
    public func endRunSegment() {
        guard let w = writer, !betweenRuns else { return }
        betweenRuns = true
        w.endSegment(.stopped, endedAtMonotonicNanos: lastSampleNanos, gap: nil)
        published.withLock { $0.runSegmentOpen = false }
    }

    /// Queues protocol events on the recording; with `marker`, then inserts that BrainFlow
    /// marker, so the writer finds the sample it lands on (queued first, so no drain can
    /// commit the marked sample before the writer waits for it). False without a recording.
    @discardableResult
    public func recordProtocolEvents(_ events: [EventRecord], marker: Double?, associateAt: Int64?) async -> Bool {
        guard let w = writer, !betweenRuns, w.submitEvents(events, marker: marker, associateAt: associateAt) else { return false }
        guard let marker, let id = events.first?.eventID else { return true }
        do {
            guard let board, state == .streaming else { throw SessionError.notStreaming }
            try await board.insertMarker(marker)
        } catch {
            w.markerFailed(id)
        }
        return true
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
        block.clockPair = .now()
        if let pause = health.ingest(chunk, gaps: block.gaps) { block.gaps.insert(pause, at: 0) }
        self.accounting = accounting
        self.health = health
        if chunk.count > 0 {
            lastSampleNanos = chunk.drainedAtMonotonicNanos
            previewSink.yield(.init(segment: health.health.segment, chunk: chunk))
            let frame = InferenceFrame(segment: health.health.segment, firstSample: segmentSamples, chunk: chunk, gaps: block.gaps, clockPair: block.clockPair)
            segmentSamples += chunk.count
            inferenceSinks.withLock { sinks in for sink in sinks.values { sink.yield(frame) } }
            if let w = writer, !betweenRuns, case .refused = w.submit(block) {
                // The writer stopped itself (disk full, backlog, write error); preview goes on.
                // Detached synchronously: a new recording may start before this finishes.
                _ = detachRecording()
                // The writer already ended itself; its own end reason stands.
                _ = finish(w, .stopped)
            }
        }
        publishHealth(force: false)
    }

    /// streaming → interrupted: the segment closes with a `disconnect` gap; the board goes.
    private func interrupt(_ reason: String) async {
        set(.interrupted(reason: reason))
        recordingStarts += 1
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
        if !isInterrupted, !Task.isCancelled { set(.interrupted(reason: "Reconnecting")) }
        while !Task.isCancelled {
            // The attempt's board is local until it streams: a cancelled or failed attempt
            // releases its own session and never overwrites `board`.
            var attempt: (any AcquisitionBoard)?
            do {
                let b = try makeBoard()
                attempt = b
                try await b.prepare()
                // "Reconnect to reset": every new session gets the defaults again.
                let configuration = try await source.applyDefaultConfiguration(to: b)
                try await b.startStream(bufferSize: options.bufferSize)
                guard !Task.isCancelled else { await Self.release(b); return false }
                board = b
                lastDescription = b.description
                published.withLock { $0.configuration = configuration }
                recordingStarts += 1
                beginStreamSegment(b, reconnect: true)
                // The manifest holds one configuration: a reconnect that finds the board set
                // differently (or wrongly) ends the recording instead of mis-scaling a segment.
                if let w = writer, let stored = recordingConfiguration {
                    let change = Self.problem(configuration, isDevice: source.readsBackRegisters)
                        ?? (CytonRegisterReadback.settings(configuration) == CytonRegisterReadback.settings(stored) ? nil : .changedOnReconnect)
                    if let change {
                        _ = detachRecording()
                        published.withLock { $0.recordingEndedByReconnect = change }
                        // Its last segment already ended `disconnect`.
                        _ = finish(w, .disconnect)
                    } else if !betweenRuns {
                        w.beginSegment(startedAtWall: Date(), startedAtMonotonicNanos: HostMonotonicClock.nowNanos())
                    }
                }
                set(.streaming)
                return true
            } catch {
                lastError = Self.describe(error)
                if let attempt { await Self.release(attempt) }
            }
            guard HostMonotonicClock.nowNanos() < deadline else { break }
            try? await Task.sleep(for: options.retryInterval)
        }
        guard !Task.isCancelled else { return false }
        set(.failed(reason: "Reconnect failed for \(Self.seconds(options.retryWindow)) s: \(lastError)"))
        // Nothing is being recorded any more: end the recording with its last segment's real
        // reason, which also lets the Mac sleep again. Retry streams; Record starts anew.
        if let w = detachRecording() { _ = await finish(w, .disconnect).value }
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
        segmentSamples = 0
        lastSampleNanos = HostMonotonicClock.nowNanos()
        publishHealth(force: true)
    }

    private func releaseBoard() async {
        if let b = board { board = nil; await Self.release(b) }
    }

    private static func release(_ b: any AcquisitionBoard) async {
        do { try await b.release() } catch { log.error("board release failed: \(describe(error), privacy: .public)") }
    }

    private static let log = Logger(subsystem: "com.hshwang34.BCIWorkspace", category: "acquisition")

    /// Takes the current writer out of the session and releases its power assertion, all
    /// before any await, so nothing that finishes later can touch a newer recording.
    private func detachRecording() -> RecordingWriter? {
        guard let w = writer else { return nil }
        writer = nil
        recordingConfiguration = nil
        betweenRuns = false
        published.withLock { $0.runSegmentOpen = false }
        power?.release()
        power = nil
        published.withLock { $0.recordingID = nil; $0.holdsPowerAssertion = false }
        return w
    }

    /// Finishes a detached writer as a tracked task, publishes its end, and forgets it once
    /// done. A writer that already stopped itself keeps its own end reason.
    private func finish(_ w: RecordingWriter, _ reason: EndReason) -> Task<RecordingWriter.Status, Never> {
        let id = w.recordingID
        let t = Task {
            let status = await w.finish(reason)
            self.noteEnded(status, of: w)
            self.finishing[id] = nil
            return status
        }
        finishing[id] = t
        return t
    }

    private func awaitFinishing() async {
        while let t = finishing.values.first { _ = await t.value }
    }

    /// Publishes `w`'s end unless a newer recording has started since (a late detached finish).
    private func noteEnded(_ status: RecordingWriter.Status, of w: RecordingWriter) {
        guard w.recordingID == latestRecordingID else { return }
        published.withLock { $0.lastRecordingEnd = status }
    }

    /// At most once a second (the panel's rate), or at once on a state change.
    private func publishHealth(force: Bool) {
        let now = HostMonotonicClock.nowNanos()
        guard force || now - lastPublishNanos >= 1_000_000_000, let health else { return }
        lastPublishNanos = now
        var h = health.snapshot()
        h.writer = writer?.status
        if let dir = projectDirectory, let free = RecordingWriter.freeBytes(at: dir), let d = lastDescription {
            let bytesPerHour = Double(d.numRows * 8 * d.samplingRate) * 3600
            h.freeBytes = free
            h.hoursLeft = max(0, Double(free - RecordingWriter.minimumFreeBytes) / bytesPerHour)
        }
        published.withLock { $0.health = h }
    }

    private func set(_ s: State) { published.withLock { $0.state = s } }
    private var isFailed: Bool { if case .failed = state { true } else { false } }
    private var isInterrupted: Bool { if case .interrupted = state { true } else { false } }

    /// Gain other than 24 in the readback, or (on the Cyton) a channel command without a
    /// success reply: either way the stored µV would not be what the manifest claims.
    static func problem(_ c: RecordingManifest.BoardConfiguration, isDevice: Bool) -> ConfigurationProblem? {
        if let m = CytonRegisterReadback.gainMismatch(c.readback) { return .gainMismatch(channel: m.channel, gain: m.gain) }
        if isDevice, let n = CytonRegisterReadback.unacknowledged(c.requested) { return .notAcknowledged(channel: n) }
        return nil
    }

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
