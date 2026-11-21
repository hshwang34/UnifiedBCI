import CryptoKit
import Foundation
import IOKit.pwr_mgt

/// What `AcquisitionSession` needs from a board. `BrainFlowBoard` is the real one; tests
/// use a fault-injecting fake. Every call may block on the board's own queue, never on
/// the session's.
public protocol AcquisitionBoard: Sendable {
    var description: BoardDescription { get }
    func prepare() async throws
    func startStream(bufferSize: Int32) async throws
    func readAll() async throws -> SampleChunk
    /// BrainFlow `config_board`: sends `command`, returns the board's reply ("" if none).
    func configure(_ command: String) async throws -> String
    func release() async throws
}

extension BrainFlowBoard: AcquisitionBoard {}

/// Where samples come from. Every source runs the same live path (drain, health, preview,
/// record); only the board and what the recording says about its origin differ.
public enum AcquisitionSource: Sendable, Equatable {
    /// BrainFlow's synthetic board: generated signal, not a device.
    case synthetic
    /// Cyton+Daisy on the dongle's `/dev/cu.*` port, radio path.
    case serial(port: String)
    /// A BrainFlow CSV through the playback-file board, Cyton+Daisy layout. The "Demo"
    /// source (decision #42) is this with the bundled example file and `loop: true`.
    case playback(file: URL, loop: Bool)

    public func makeBoard() throws -> any AcquisitionBoard {
        switch self {
        case .synthetic: try BrainFlowBoard(boardID: KnownBoard.synthetic)
        case .serial(let port): try BrainFlowBoard(boardID: KnownBoard.cytonDaisy, params: .serial(port))
        case .playback(let file, let loop): try BrainFlowBoard.playback(file: file, masterBoard: KnownBoard.cytonDaisy, loop: loop)
        }
    }

    /// The recording's source block. A playback recording names the played file and never
    /// claims a device; a synthetic one never claims a data path.
    func recordingSource(_ board: BoardDescription, appVersion: String) -> RecordingManifest.Source {
        let version = (try? BrainFlowBoard.libraryVersion()) ?? "unknown"
        switch self {
        case .synthetic:
            return .init(kind: "synthetic", boardID: KnownBoard.synthetic, boardName: board.name, dataPath: nil,
                         brainflowVersion: version, appVersion: appVersion,
                         warning: "Synthetic board — generated signal, not a device")
        case .serial:
            return .init(kind: "brainflow", boardID: board.boardID, boardName: board.name, dataPath: .radio125,
                         brainflowVersion: version, appVersion: appVersion)
        case .playback(let file, _):
            let sha = (try? Data(contentsOf: file, options: .mappedIfSafe)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            return .init(kind: "playback", boardID: KnownBoard.playbackFile, boardName: "BrainFlow playback file (\(board.name) layout)",
                         dataPath: nil, brainflowVersion: version, appVersion: appVersion,
                         warning: "Played back from a file, not a device",
                         sourceFiles: [.init(name: file.lastPathComponent, sha256: sha ?? "unreadable")])
        }
    }
}

/// Prevents idle system sleep while recording (brief 004). Lid close is not covered.
struct PowerAssertion {
    private(set) var id: IOPMAssertionID = 0

    static func take(_ reason: String) -> PowerAssertion? {
        var a = PowerAssertion()
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &a.id)
        return ok == kIOReturnSuccess ? a : nil
    }

    func release() { IOPMAssertionRelease(id) }
}
