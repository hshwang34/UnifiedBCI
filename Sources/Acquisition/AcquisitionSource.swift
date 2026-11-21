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
    /// BrainFlow `insert_marker`: `value` (never 0) lands on the next sample written.
    func insertMarker(_ value: Double) async throws
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
            var files = [RecordingManifest.SourceFile(name: file.lastPathComponent, sha256: Self.sha256(file) ?? "unreadable")]
            let derived = DerivedPlayback.load(for: file, sha256: files[0].sha256)
            if let derived { files.append(.init(name: derived.sidecar.lastPathComponent, sha256: Self.sha256(derived.sidecar) ?? "unreadable")) }
            return .init(kind: "playback", boardID: KnownBoard.playbackFile, boardName: "BrainFlow playback file (\(board.name) layout)",
                         dataPath: nil, brainflowVersion: version, appVersion: appVersion,
                         dataset: derived?.dataset, license: derived?.license,
                         warning: derived?.warning ?? "Played back from a file, not a device",
                         attribution: derived?.attribution, derivations: derived?.derivations, sourceFiles: files)
        }
    }

    /// The channel map the played file declares (its sidecar's labels, montage and
    /// reference), only for a derived playback file whose sidecar names its SHA-256 and whose
    /// rows are exactly this board's EEG rows. Nil for every other source: a device's map is
    /// the operator's to declare (decision #31). Hashes the file: call it off the main actor.
    public func declaredChannelMap(for board: BoardDescription) -> ChannelMapRecord? {
        guard case .playback(let file, _) = self, let sha = Self.sha256(file),
              let derived = DerivedPlayback.load(for: file, sha256: sha), let declared = derived.channels else { return nil }
        var map = ChannelMapRecord.defaults(for: board)
        guard declared.count == map.channels.count,
              Set(declared.map(\.row)) == Set(map.channels.map(\.sourceRow)) else { return nil }
        for i in map.channels.indices {
            guard let label = declared.first(where: { $0.row == map.channels[i].sourceRow })?.label else { return nil }
            map.channels[i].label = label
        }
        if let montage = derived.montage { map.montage = montage }
        if let reference = derived.reference { map.reference = reference }
        return map.problem(directoryID: map.mapID) == nil ? map : nil
    }

    /// The bundled Demo file (decision #42), generated at build time into `Resources/Demo/`.
    public static let demoFileName = "S001R04-demo-cyton-daisy-125hz.csv"

    public static func bundledDemo(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: (demoFileName as NSString).deletingPathExtension, withExtension: "csv", subdirectory: "Demo")
    }

    static func sha256(_ file: URL) -> String? {
        (try? Data(contentsOf: file, options: .mappedIfSafe)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

/// The sidecar `worker/tools/make_demo_playback.py` writes next to a derived playback file
/// (`<name>.json`). Used only when it is `derived_playback` and names the played file's
/// SHA-256, so a recording never borrows provenance from a different file.
struct DerivedPlayback {
    let sidecar: URL
    let warning: String
    let dataset: String?
    let license: String?
    let attribution: [RecordingManifest.Citation]?
    let derivations: [String]
    /// The file's EEG rows and their electrode labels, montage and reference, as declared.
    let channels: [(row: Int, label: String)]?
    let montage: String?
    let reference: String?

    private struct Sidecar: Decodable {
        struct Channel: Decodable { let fileRow: Int; let label: String; let kind: String; let unit: String }
        struct File: Decodable { let name: String; let sha256: String }
        struct Origin: Decodable {
            let project: String?; let recordingID: String?; let dataset: String?; let license: String?
            let attribution: [RecordingManifest.Citation]?
        }
        let kind: String; let warning: String; let generator: String; let method: String
        let originalRateHz: Double; let resampledRateHz: Double
        let file: File; let source: Origin
        let channels: [Channel]?; let montage: String?; let reference: String?
    }

    static func load(for file: URL, sha256: String) -> DerivedPlayback? {
        let url = file.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20,
              let s = try? JSONDecoder().decode(Sidecar.self, from: data),
              s.kind == "derived_playback", s.file.name == file.lastPathComponent, s.file.sha256 == sha256 else { return nil }
        let origin = [s.source.project, s.source.recordingID.map { "recording \($0)" }].compactMap { $0 }.joined(separator: " ")
        let eeg = s.channels?.filter { $0.kind == "eeg" && $0.unit == "uV" }.map { (row: $0.fileRow, label: $0.label) }
        return .init(sidecar: url, warning: s.warning, dataset: s.source.dataset, license: s.source.license,
                     attribution: s.source.attribution,
                     derivations: ["derived_playback (\(s.generator))",
                                   "resampled \(Fmt.hertz(s.originalRateHz)) to \(Fmt.hertz(s.resampledRateHz)): \(s.method)",
                                   "derived from \(origin.isEmpty ? "an unnamed source" : origin)"],
                     channels: eeg, montage: s.montage, reference: s.reference)
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
