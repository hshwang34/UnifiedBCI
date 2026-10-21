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
}

/// A block of samples as BrainFlow hands them back: `numRows` rows × `count` columns,
/// row-major. Row meanings come from `BoardDescription`.
public struct SampleChunk: Sendable {
    public let numRows: Int
    public let count: Int
    public let values: [Double]

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
/// device stream is never drained from two places. UI code must never hold it on the
/// main actor across a `read`.
public actor BrainFlowBoard {
    public nonisolated let boardID: Int32
    public nonisolated let description: BoardDescription
    private let paramsJSON: String
    private var prepared = false
    private var streaming = false

    public init(boardID: Int32, params: BrainFlowInputParams = .init()) throws {
        self.boardID = boardID
        self.paramsJSON = params.json()
        self.description = try Self.describe(boardID: boardID)
    }

    deinit {
        // Best effort: BrainFlow keeps global session state keyed by board id + params.
        if prepared { _ = release_session(boardID, paramsJSON) }
    }

    // MARK: Static queries

    public static func libraryVersion() throws -> String {
        var buf = [CChar](repeating: 0, count: 64)
        var len: Int32 = 0
        try check(get_version_board_controller(&buf, &len, Int32(buf.count)), "get_version")
        return String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func describe(boardID: Int32) throws -> BoardDescription {
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
            packageNumRow: Int(pkg)
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
        streaming = true
    }

    public func stopStream() throws {
        guard streaming else { return }
        try Self.check(stop_stream(boardID, paramsJSON), "stop_stream")
        streaming = false
    }

    public func release() throws {
        try stopStream()
        guard prepared else { return }
        try Self.check(release_session(boardID, paramsJSON), "release_session")
        prepared = false
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
        let n = min(count, try availableSampleCount())
        guard n > 0 else { return SampleChunk(numRows: description.numRows, count: 0, values: []) }
        var buf = [Double](repeating: 0, count: n * description.numRows)
        try Self.check(get_board_data(Int32(n), BrainFlowPreset.default.rawValue, &buf, boardID, paramsJSON), "get_board_data")
        return SampleChunk(numRows: description.numRows, count: n, values: buf)
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
