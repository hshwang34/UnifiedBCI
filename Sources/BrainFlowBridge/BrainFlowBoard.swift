import CBrainFlow
import Foundation

/// Error returned by the BrainFlow C ABI. `code` maps to `BrainFlowExitCodes`.
public struct BrainFlowError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let operation: String

    public var description: String {
        "BrainFlow \(operation) failed: \(Self.name(for: code)) (\(code))"
    }

    static func name(for code: Int32) -> String {
        BrainFlowExitCode(rawValue: code).map { String(describing: $0) } ?? "unknown"
    }
}

/// Static facts BrainFlow publishes about a board type, independent of any session.
/// Row indices refer to rows of the sample matrix returned by `read`.
public struct BoardDescription: Sendable, Equatable {
    public nonisolated let boardID: Int32
    public let name: String
    public let samplingRate: Int
    public let numRows: Int
    public let eegChannelRows: [Int]
    public let eegNames: [String]
    public let timestampRow: Int
    public let packageNumRow: Int
    /// Expected package-counter increment per committed sample. Cyton+Daisy commits one
    /// sample per board/Daisy packet pair and writes the even packet's counter, so valid
    /// counters step by 2 (mod 256). Everything else we support steps by 1.
    public let sequenceStep: Int

    public static func sequenceStep(forBoard boardID: Int32) -> Int {
        boardID == KnownBoard.cytonDaisy ? 2 : 1
    }
}

/// A block of samples as BrainFlow hands them back: `numRows` rows × `count` columns,
/// row-major. Row meanings come from `BoardDescription`.
public struct SampleChunk: Sendable {
    public let numRows: Int
    public let count: Int
    public let values: [Double]
    /// `HostMonotonicClock` when the drain call returned. The only app-side time a chunk has.
    public let drainedAtMonotonicNanos: Int64
    /// Samples BrainFlow reported available just before this drain.
    public let availableBeforeDrain: Int
    /// True when the ring buffer was within `SequenceAccounting.overflowMargin` of full at
    /// drain time. BrainFlow drops the oldest samples silently, so this is the only warning.
    public let overflowSuspected: Bool

    public func row(_ r: Int) -> ArraySlice<Double> {
        values[(r * count)..<((r + 1) * count)]
    }
}

/// Identity-only parameters BrainFlow needs to open a board. Every key must be present
/// in the JSON or BrainFlow rejects the session, so we mirror the full struct.
public struct BrainFlowInputParams: Codable, Sendable, Equatable {
    public var serialPort = ""
    public var macAddress = ""
    public var ipAddress = ""
    public var ipAddressAux = ""
    public var ipAddressAnc = ""
    public var ipPort = 0
    public var ipPortAux = 0
    public var ipPortAnc = 0
    public var ipProtocol = 0
    public var otherInfo = ""
    public var timeout = 0
    public var serialNumber = ""
    public var file = ""
    public var fileAux = ""
    public var fileAnc = ""
    public var masterBoard = -100

    public init() {}

    enum CodingKeys: String, CodingKey {
        case serialPort = "serial_port", macAddress = "mac_address"
        case ipAddress = "ip_address", ipAddressAux = "ip_address_aux", ipAddressAnc = "ip_address_anc"
        case ipPort = "ip_port", ipPortAux = "ip_port_aux", ipPortAnc = "ip_port_anc"
        case ipProtocol = "ip_protocol", otherInfo = "other_info", timeout
        case serialNumber = "serial_number", file, fileAux = "file_aux", fileAnc = "file_anc"
        case masterBoard = "master_board"
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// Single owner of one BrainFlow session. All C calls funnel through this actor so the
/// device stream is never drained from two places. The actor runs on its own serial
/// dispatch queue: BrainFlow calls block (`prepare_session` on a Cyton can take seconds)
/// and must not occupy a cooperative-pool thread. UI code must never hold it on the main
/// actor across a `read`.
public actor BrainFlowBoard {
    public nonisolated let boardID: Int32
    public nonisolated let description: BoardDescription
    private let paramsJSON: String
    private var prepared = false
    private var streaming = false
    private var bufferSize: Int32 = 0

    private let queue = DispatchSerialQueue(label: "com.hshwang34.BCIWorkspace.brainflow", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// True when called on the actor's own queue (tests verify the executor is in effect).
    public func isOnOwnQueue() -> Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == true
    }

    /// BrainFlow's spdlog writes to stderr and echoes the params JSON at INFO; keep
    /// warnings and above. Runs once per process, before the first C call.
    private static let configureLogging: Void = {
        _ = set_log_level_board_controller(BrainFlowLogLevel.warn.rawValue)
    }()

    public init(boardID: Int32, params: BrainFlowInputParams = .init()) throws {
        _ = Self.configureLogging
        self.boardID = boardID
        self.paramsJSON = params.json()
        self.description = try Self.describe(boardID: boardID)
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        // Best effort: BrainFlow keeps global session state keyed by board id + params.
        // Stop first; releasing a streaming session leaves the stream thread running.
        if streaming { _ = stop_stream(boardID, paramsJSON) }
        if prepared { _ = release_session(boardID, paramsJSON) }
    }

    // MARK: Static queries

    public static func libraryVersion() throws -> String {
        _ = configureLogging
        var buf = [CChar](repeating: 0, count: 64)
        var len: Int32 = 0
        try check(get_version_board_controller(&buf, &len, Int32(buf.count)), "get_version")
        return String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func describe(boardID: Int32) throws -> BoardDescription {
        _ = configureLogging
        let preset = BrainFlowPreset.default.rawValue
        var rate: Int32 = 0, rows: Int32 = 0, ts: Int32 = 0, pkg: Int32 = 0
        try check(get_sampling_rate(boardID, preset, &rate), "get_sampling_rate")
        try check(get_num_rows(boardID, preset, &rows), "get_num_rows")
        try check(get_timestamp_channel(boardID, preset, &ts), "get_timestamp_channel")
        try check(get_package_num_channel(boardID, preset, &pkg), "get_package_num_channel")

        var eeg = [Int32](repeating: 0, count: 512)
        var eegLen: Int32 = 0
        try check(get_eeg_channels(boardID, preset, &eeg, &eegLen), "get_eeg_channels")

        var nameBuf = [CChar](repeating: 0, count: 256)
        var nameLen: Int32 = 0
        try check(get_device_name(boardID, preset, &nameBuf, &nameLen, Int32(nameBuf.count)), "get_device_name")
        var namesBuf = [CChar](repeating: 0, count: 4096)
        var namesLen: Int32 = 0
        try check(get_eeg_names(boardID, preset, &namesBuf, &namesLen, Int32(namesBuf.count)), "get_eeg_names")

        return BoardDescription(
            boardID: boardID,
            name: cString(nameBuf, nameLen),
            samplingRate: Int(rate),
            numRows: Int(rows),
            eegChannelRows: eeg.prefix(Int(eegLen)).map(Int.init),
            eegNames: cString(namesBuf, namesLen).split(separator: ",").map(String.init),
            timestampRow: Int(ts),
            packageNumRow: Int(pkg),
            sequenceStep: BoardDescription.sequenceStep(forBoard: boardID)
        )
    }

    // MARK: Session lifecycle

    public func prepare() throws {
        guard !prepared else { return }
        try Self.check(prepare_session(boardID, paramsJSON), "prepare_session")
        prepared = true
    }

    /// `bufferSize` is BrainFlow's ring buffer in samples; the caller must drain faster
    /// than it fills or BrainFlow drops silently. Default ≈ 6 minutes at 125 Hz.
    public func startStream(bufferSize: Int32 = 45_000) throws {
        try prepare()
        try Self.check(start_stream(bufferSize, "", boardID, paramsJSON), "start_stream")
        self.bufferSize = bufferSize
        streaming = true
    }

    public func stopStream() throws {
        guard streaming else { return }
        // Whatever BrainFlow says, we no longer consider the stream ours to stop twice.
        streaming = false
        try Self.check(stop_stream(boardID, paramsJSON), "stop_stream")
    }

    /// Releases the session even when stopping the stream fails; the stop error is
    /// rethrown afterwards so nothing is hidden and nothing is leaked.
    public func release() throws {
        var stopError: Error?
        do { try stopStream() } catch { stopError = error }
        if prepared {
            prepared = false
            try Self.check(release_session(boardID, paramsJSON), "release_session")
        }
        if let stopError { throw stopError }
    }

    // MARK: Data

    public func availableSampleCount() throws -> Int {
        var n: Int32 = 0
        try Self.check(get_board_data_count(BrainFlowPreset.default.rawValue, &n, boardID, paramsJSON), "get_board_data_count")
        return Int(n)
    }

    /// Removes up to `count` samples from BrainFlow's buffer (oldest first). This is the
    /// only consuming read; preview code must use the chunks this returns, not re-read.
    public func read(count: Int) throws -> SampleChunk {
        let available = try availableSampleCount()
        let overflow = SequenceAccounting.overflowSuspected(available: available, bufferSize: Int(bufferSize))
        let n = min(count, available)
        guard n > 0 else {
            return SampleChunk(numRows: description.numRows, count: 0, values: [],
                               drainedAtMonotonicNanos: HostMonotonicClock.nowNanos(),
                               availableBeforeDrain: available, overflowSuspected: overflow)
        }
        var buf = [Double](repeating: 0, count: n * description.numRows)
        try Self.check(get_board_data(Int32(n), BrainFlowPreset.default.rawValue, &buf, boardID, paramsJSON), "get_board_data")
        return SampleChunk(numRows: description.numRows, count: n, values: buf,
                           drainedAtMonotonicNanos: HostMonotonicClock.nowNanos(),
                           availableBeforeDrain: available, overflowSuspected: overflow)
    }

    public func readAll() throws -> SampleChunk {
        try read(count: availableSampleCount())
    }

    // MARK: Helpers

    private static func check(_ code: Int32, _ op: String) throws {
        guard code == BrainFlowExitCode.statusOK.rawValue else {
            throw BrainFlowError(code: code, operation: op)
        }
    }

    private static func cString(_ buf: [CChar], _ len: Int32) -> String {
        String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Stateful sequence-counter and timestamp bookkeeping across drained chunks. Lives in
/// the bridge so the recorder, the preview, and the tests share one definition of "gap".
///
/// Counters wrap mod 256 and advance by `expectedStep` per committed sample. A delta of
/// `expectedStep` is normal; `0` on a step-2 board means one half of the packet pair was
/// lost and the sample mixes halves (`staleHalf`); anything else is a gap whose size is
/// `(delta − step) / step` — ambiguous, because a loss of `256/step` samples or more looks
/// like a smaller one. BrainFlow timestamps are wall-clock seconds and are never used for
/// gap detection; a backward step is reported as `clockAnomaly` for provenance.
public struct SequenceAccounting: Sendable, Equatable {
    public static let modulus = 256
    /// Samples of headroom below `bufferSize` at which a drain is flagged as a possible
    /// overflow. One second at 125 Hz; the drain loop polls far more often than that.
    public static let overflowMargin = 125

    public enum Kind: Sendable, Equatable {
        case gap(estimatedMissing: Int, ambiguous: Bool, parityViolation: Bool)
        case staleHalf
        case duplicateCounter
        case clockAnomaly(backwardSeconds: Double)
    }

    public struct Finding: Sendable, Equatable {
        /// Index (within the chunk passed to `ingest`) of the sample *after* which the
        /// finding applies; -1 when the first sample of the chunk is the culprit.
        public let afterSampleIndex: Int
        public let kind: Kind
    }

    public let expectedStep: Int
    public private(set) var lastCounter: Int?
    public private(set) var lastTimestamp: Double?
    public private(set) var samplesSeen = 0

    public init(expectedStep: Int) {
        precondition(expectedStep == 1 || expectedStep == 2, "only step 1 and step 2 boards are supported")
        self.expectedStep = expectedStep
    }

    public init(board: BoardDescription) {
        self.init(expectedStep: board.sequenceStep)
    }

    public static func overflowSuspected(available: Int, bufferSize: Int, margin: Int = overflowMargin) -> Bool {
        bufferSize > 0 && available >= bufferSize - margin
    }

    /// Feeds one drained chunk's counter row and timestamp row (same length) and returns
    /// every finding in sample order. State carries across calls; call `reset()` at the
    /// start of each stream segment.
    public mutating func ingest(counters: ArraySlice<Double>, timestamps: ArraySlice<Double>) -> [Finding] {
        precondition(counters.count == timestamps.count)
        var findings: [Finding] = []
        for (offset, (c, t)) in zip(counters, timestamps).enumerated() {
            let counter = Int(c)
            if let prev = lastCounter {
                let delta = ((counter - prev) % Self.modulus + Self.modulus) % Self.modulus
                if delta == expectedStep {
                    // normal
                } else if delta == 0 {
                    findings.append(Finding(afterSampleIndex: offset - 1, kind: expectedStep == 2 ? .staleHalf : .duplicateCounter))
                } else {
                    let missingCounts = delta - expectedStep
                    let parityViolation = missingCounts % expectedStep != 0
                    let estimated = max(0, missingCounts) / expectedStep
                    findings.append(Finding(afterSampleIndex: offset - 1,
                                            kind: .gap(estimatedMissing: estimated, ambiguous: true, parityViolation: parityViolation)))
                }
            }
            if let prevT = lastTimestamp, t < prevT {
                findings.append(Finding(afterSampleIndex: offset - 1, kind: .clockAnomaly(backwardSeconds: prevT - t)))
            }
            lastCounter = counter
            lastTimestamp = t
            samplesSeen += 1
        }
        return findings
    }

    public mutating func reset() {
        lastCounter = nil
        lastTimestamp = nil
        samplesSeen = 0
    }
}
