import Foundation
import Observation

/// The Connect sheet's state (brief 004 PR 5): the source list, one `AcquisitionSession`,
/// and the channel-map editor. The session's snapshot is polled (it is a lock read, no
/// actor hop), so nothing here waits on the board. All copy comes from AcquisitionModels.
@MainActor @Observable
final class ConnectController: Identifiable {
    private(set) var ports: [SerialPort] = []
    var selectedID: String?
    /// A selected port that a re-scan no longer finds (named, never silently swapped).
    private(set) var gonePort: SerialPort?
    private(set) var source: ConnectSource?
    private(set) var snapshot = AcquisitionSession.Snapshot()
    private(set) var hasStreamed = false
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
        // Record belongs to the acquisition screen (PR 6); the sheet stops at preview.
        AcquisitionStateModel.actions(state, recording: false, afterStreaming: hasStreamed).filter { $0 != .record && $0 != .stopRecording }
    }
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
        case .record, .stopRecording: break
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
        startPolling()
        await s.connect()
        // Closed while the board was opening: `close()` may have run before `s` existed
        // or while it prepared, so release it here too (disconnect is idempotent).
        if isClosed {
            poll?.cancel()
            await s.disconnect()
            return
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

    /// Disconnects (stopping a stream) and stops polling; the sheet calls it on dismiss.
    func close() async {
        isClosed = true
        poll?.cancel()
        await session?.disconnect()
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
        snapshot = next
        if next.state == .streaming { hasStreamed = true }
        if boardArrived, let board = next.board { resetMap(to: .defaults(for: board)) }
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
