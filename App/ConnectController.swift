import Foundation
import Observation

/// One project's live board (brief 004 PRs 5–6): the Connect sheet's source list and
/// channel-map editor, then the acquisition screen's preview, Record / Stop and health. It
/// outlives the sheet once the stream has started. The session's snapshot is polled (a
/// lock read, no actor hop), so nothing here waits on the board. All copy comes from
/// AcquisitionModels / LiveModels.
@MainActor @Observable
final class ConnectController: Identifiable {
    private(set) var ports: [SerialPort] = []
    var selectedID: String?
    /// A selected port that a re-scan no longer finds (named, never silently swapped).
    private(set) var gonePort: SerialPort?
    private(set) var source: ConnectSource?
    private(set) var snapshot = AcquisitionSession.Snapshot()
    private(set) var hasStreamed = false
    /// When the current stream started streaming (nil while not streaming), for the guide.
    private(set) var streamingSince: Date?
    /// A Connect is in flight (its button is disabled until it returns).
    private(set) var isConnecting = false
    /// Set by `close()`; a Connect still in flight then releases what it opened.
    private(set) var isClosed = false
    var tab: ConnectSheetModel.Tab = .board

    // Channel-map editor (decision #31).
    var labels: [String] = [] { didSet { editedAfterChoice() } }
    var reference = ChannelMapModel.referenceDefault { didSet { editedAfterChoice() } }
    var montage = ChannelMapModel.montageDefault { didSet { editedAfterChoice() } }
    private(set) var savedMaps: [ChannelMapRecord] = []
    private(set) var unreadableMaps = 0
    private(set) var choice: ChannelMapChoice = .none
    private(set) var mapMessage: String?
    /// The map the played file declares (Demo), pre-filled for the operator to confirm.
    private(set) var declaredMap: ChannelMapRecord?

    // Acquisition screen (PR 6).
    /// The last 10 s, fed off the main actor from the session's newest-wins preview stream.
    private(set) var preview: PreviewBuffer?
    var scale: LivePreviewModel.Scale = .auto
    /// Wall time Record succeeded (the screen's elapsed clock).
    private(set) var recordingStartedAt: Date?
    /// Why Record was refused, or how the last recording ended (disk full, error, …).
    private(set) var recordMessage: (danger: Bool, text: String)?
    /// The last recording that ended, for "Show Recording".
    private(set) var lastRecordingID: UUID?
    private(set) var isStartingRecording = false
    /// Called once the stream starts (the sheet hands over to the acquisition screen) and
    /// whenever a recording ends (the project reloads its list).
    @ObservationIgnored var onStreamStarted: (() -> Void)?
    @ObservationIgnored var onRecordingEnded: ((UUID) -> Void)?
    /// Called each time the board enters streaming (first stream and every reconnect).
    @ObservationIgnored var onStreamingBegan: (() -> Void)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private var watchedRecordingID: UUID?
    /// `lastRecordingEnd` when the watched recording started: the writer publishes a new
    /// one only after its last commit, so the list reloads a finished recording.
    @ObservationIgnored private var endBeforeRecording: RecordingWriter.Status?

    let demoFile: URL?
    /// Read once: the identity panel shows it, and `body` must not call into BrainFlow.
    let brainflowVersion = (try? BrainFlowBoard.libraryVersion()) ?? ConnectSheetModel.unknownVersion
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let projectDirectory: URL
    @ObservationIgnored private(set) var session: AcquisitionSession?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var filling = false
    @ObservationIgnored private let scan: @Sendable () -> [SerialPort]

    init(store: ProjectStore, projectDirectory: URL, demoFile: URL? = AcquisitionSource.bundledDemo(),
         scan: @escaping @Sendable () -> [SerialPort] = SerialPortScanner.scan) {
        self.store = store
        self.projectDirectory = projectDirectory
        self.demoFile = demoFile
        self.scan = scan
    }

    var sources: [ConnectSource] { ports.map(ConnectSource.serial) + [.synthetic, .demo] }
    var selected: ConnectSource? { sources.first { $0.id == selectedID } }
    var state: AcquisitionSession.State { snapshot.state }
    var actions: [AcquisitionAction] {
        // Record belongs to the acquisition screen; the sheet stops at preview.
        screenActions.filter { $0 != .record && $0 != .stopRecording }
    }
    var screenActions: [AcquisitionAction] {
        AcquisitionStateModel.actions(state, recording: isRecording, afterStreaming: hasStreamed)
    }
    var isRecording: Bool { snapshot.recordingID != nil }
    /// Read from the session's lock now, not the 200 ms poll: ⌘W right after Record must ask.
    var isRecordingNow: Bool { (session?.snapshot.recordingID != nil) || isRecording || isStartingRecording }
    /// Stopped but not yet finished (the writer is committing its last chunk).
    var isFinishingRecording: Bool { watchedRecordingID != nil && !isRecording }
    /// Why Record is disabled; nil when it can be pressed.
    var recordDisabledReason: String? {
        guard let source else { return RecordGate.notStreaming }
        return RecordGate.disabledReason(state: state, source: source, board: snapshot.board,
                                         configuration: snapshot.configuration, map: choice,
                                         freeBytes: snapshot.health.freeBytes)
    }
    /// The board's channel labels as the preview shows them: the edited map's.
    var laneLabels: [String] { labels }
    var canPickSource: Bool { session == nil || state == .disconnected || (state.isFailed && !hasStreamed) }

    func isAvailable(_ s: ConnectSource) -> Bool { s != .demo || demoFile != nil }

    // MARK: Sources

    func refresh() async {
        let scan = scan
        let found = await Task.detached(priority: .userInitiated) { scan() }.value
        // A port a session is using stays selected; the session reports its own loss.
        let inUse = session != nil && !canPickSource
        if !inUse, case .serial(let p)? = selected, !found.contains(where: { $0.path == p.path }) {
            gonePort = p
            selectedID = nil
        } else if let gone = gonePort, found.contains(where: { $0.path == gone.path }) {
            gonePort = nil
        }
        ports = found
    }

    /// Re-scans every 2 s while a source can be picked, so an unplugged port is named.
    func watchPorts() async {
        while !Task.isCancelled {
            if canPickSource { await refresh() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: State-table actions

    func perform(_ action: AcquisitionAction) async {
        switch action {
        case .connect: await connect()
        case .cancel, .disconnect: await session?.disconnect()
        case .retry, .reconnect, .reconnectNow: await session?.reconnect()
        case .startPreview: await session?.startStreaming()
        case .record: await record()
        case .stopRecording: await stopRecording()
        }
        sync()
    }

    func connect() async {
        guard !isClosed, !isConnecting, let picked = selected, isAvailable(picked), let acquisition = acquisitionSource(picked) else { return }
        isConnecting = true
        defer { isConnecting = false }
        await session?.disconnect()
        guard !isClosed else { return }
        let s = AcquisitionSession(source: acquisition, projectDirectory: projectDirectory)
        session = s
        source = picked
        hasStreamed = false
        choice = .none
        declaredMap = nil
        recordMessage = nil
        stopPreview()
        startPolling()
        await s.connect()
        // Closed while the board was opening: `close()` may have run before `s` existed
        // or while it prepared, so release it here too (disconnect is idempotent).
        if isClosed {
            poll?.cancel()
            await s.disconnect()
            return
        }
        // The Demo file declares its electrodes (FC3, FC1, … on a 10-10 montage): pre-fill
        // them, still to be confirmed. Hashing the file happens off the main actor.
        if let board = s.snapshot.board {
            let declared = await Task.detached(priority: .userInitiated) { acquisition.declaredChannelMap(for: board) }.value
            declaredMap = declared
            if let declared, choice == .none, !isClosed {
                resetMap(to: declared)
                mapMessage = ChannelMapModel.declaredByFile
            }
        }
        sync()
    }

    func acquisitionSource(_ s: ConnectSource) -> AcquisitionSource? {
        switch s {
        case .serial(let p): return .serial(port: p.path)
        case .synthetic: return .synthetic
        case .demo: return demoFile.map { .playback(file: $0, loop: true) }
        }
    }

    /// Disconnects (a recording ends `stopped`, the board is released) and stops polling.
    /// Window close and quit come here through `ProjectSession.shutdown`.
    func close() async {
        isClosed = true
        poll?.cancel()
        await session?.disconnect()
        sync()
        stopPreview()
    }

    /// The sheet's Close: before the stream has run it disconnects; once the acquisition
    /// screen has taken over it only closes the sheet.
    func closeSheet() async {
        if !hasStreamed || session == nil { await close() }
    }

    // MARK: Recording

    func record() async {
        guard let session, let board = snapshot.board, !isStartingRecording, !isFinishingRecording, recordDisabledReason == nil,
              let request = ChannelMapModel.request(for: choice, board: board) else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        recordMessage = nil
        endBeforeRecording = snapshot.lastRecordingEnd
        do {
            let id = try await session.startRecording(request, in: store)
            watchedRecordingID = id
            recordingStartedAt = Date()
        } catch let e as AcquisitionSession.SessionError {
            recordMessage = (true, RecordGate.message(e))
        } catch {
            recordMessage = (true, RecordGate.startFailed(error))
        }
        sync()
    }

    // MARK: Protocol runs (brief 005)

    /// Where a protocol run records: this stream, with the confirmed map. Nil while Record
    /// would be disabled, or while a plain recording is in progress.
    func runHost() -> AcquisitionRunHost? {
        guard let session, let board = snapshot.board, recordDisabledReason == nil, !isRecordingNow,
              let request = ChannelMapModel.request(for: choice, board: board) else { return nil }
        return AcquisitionRunHost(session: session, request: request, store: store)
    }

    /// A protocol run started the recording: watch it as Record would, so its end is
    /// reported and the list reloads.
    func adoptRecording(_ id: UUID) {
        guard watchedRecordingID == nil else { return }
        recordMessage = nil
        endBeforeRecording = snapshot.lastRecordingEnd
        watchedRecordingID = id
        recordingStartedAt = Date()
        sync()
    }

    func stopRecording() async {
        guard let session else { return }
        _ = await session.stopRecording()
        sync()
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func sync() {
        guard let session else { return }
        let next = session.snapshot
        guard next != snapshot else { return }
        let boardArrived = next.board != nil && next.board != snapshot.board
        let firstStream = next.state == .streaming && !hasStreamed
        snapshot = next
        if next.state == .streaming { hasStreamed = true }
        let beganStreaming = next.state == .streaming && streamingSince == nil
        if next.state != .streaming { streamingSince = nil } else if beganStreaming { streamingSince = Date() }
        if boardArrived, let board = next.board {
            resetMap(to: declaredMap ?? .defaults(for: board))
            startPreview(session, board: board)
        }
        // Detached first, finished (last chunk committed, segment closed) later.
        if let id = watchedRecordingID, next.recordingID != id, next.lastRecordingEnd != endBeforeRecording {
            recordingEnded(id, status: next.lastRecordingEnd)
        }
        if firstStream { onStreamStarted?() }
        if beganStreaming { onStreamingBegan?() }
    }

    /// A recording ended: by Stop, by Disconnect, or by itself (disk full, error, retries out).
    private func recordingEnded(_ id: UUID, status: RecordingWriter.Status?) {
        watchedRecordingID = nil
        recordingStartedAt = nil
        lastRecordingID = id
        let rate = Double(snapshot.board?.samplingRate ?? 125)
        if let reconnect = snapshot.recordingEndedByReconnect {
            recordMessage = (true, RecordingEndModel.endedByReconnect(reconnect))
        } else if let status, let text = RecordingEndModel.message(status, rateHz: rate) {
            recordMessage = (true, text)
        } else {
            recordMessage = (false, LiveScreenModel.saved(seconds: Double(status?.committedSamples ?? 0) / rate))
        }
        onRecordingEnded?(id)
    }

    // MARK: Preview

    /// One buffer per connect (a reconnect keeps it, with a break at the new segment).
    private func startPreview(_ session: AcquisitionSession, board: BoardDescription) {
        guard preview == nil || preview?.rows != board.eegChannelRows || preview?.rate != board.samplingRate else { return }
        previewTask?.cancel()
        let buffer = PreviewBuffer(rows: board.eegChannelRows, rate: board.samplingRate)
        preview = buffer
        let stream = session.preview
        previewTask = Task.detached(priority: .userInitiated) { await buffer.consume(stream) }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
    }

    // MARK: Channel map

    func loadSavedMaps() async {
        guard let (maps, unreadable) = try? await store.channelMaps() else { return }
        savedMaps = maps
        unreadableMaps = unreadable
    }

    func pick(savedMap id: UUID?) {
        guard let id, let map = savedMaps.first(where: { $0.mapID == id }) else { return }
        resetMap(to: map)
        choice = .none
    }

    /// The edited map, or nil with the reason in `mapMessage`.
    private func validMap() -> ChannelMapRecord? {
        guard let board = snapshot.board else { return nil }
        let map = ChannelMapModel.edited(board: board, labels: labels, reference: reference, montage: montage)
        if let problem = map.problem(directoryID: map.mapID) {
            mapMessage = ChannelMapModel.invalid(problem)
            return nil
        }
        return map
    }

    func confirmMap() {
        guard let map = validMap() else { return }
        choice = .confirmed(map)
        mapMessage = nil
    }

    func recordWithoutPositions() {
        guard let board = snapshot.board else { return }
        resetMap(to: .defaults(for: board))
        choice = .withoutPositions
    }

    func saveMap() async {
        guard let map = validMap() else { return }
        do {
            try await store.saveChannelMap(map)
            await loadSavedMaps()
            mapMessage = ChannelMapModel.saved
        } catch {
            mapMessage = ChannelMapModel.saveFailed("\(error)")
        }
    }

    private func resetMap(to map: ChannelMapRecord) {
        filling = true
        labels = map.channels.map(\.label)
        reference = map.reference
        montage = map.montage
        filling = false
        mapMessage = nil
    }

    private func editedAfterChoice() {
        guard !filling else { return }
        if choice != .none { mapMessage = ChannelMapModel.edited }
        choice = .none
    }
}

extension AcquisitionSession.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
