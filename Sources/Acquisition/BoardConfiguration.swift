import Foundation

/// The fixed per-channel settings the app asks every board for on connect (brief 004):
/// gain 24, normal input, bias included, SRB2 connected, SRB1 off, powered on. Editing them
/// is a later brief. Keys are `chNN.<setting>`, shared with `CytonRegisterReadback`.
public enum DefaultChannelSettings {
    public static let channelCount = 16
    public static let gain = "24"
    /// OpenBCI's channel letters: 1–8 on the Cyton, Q W E R T Y U I for Daisy's 9–16.
    static let letters = Array("12345678QWERTYUI")

    /// `x (CHANNEL, POWER_DOWN 0, GAIN 6 = 24, INPUT 0 = normal, BIAS 1, SRB2 1, SRB1 0) X`,
    /// one command per channel (OpenBCI Cyton SDK, "Channel Setting Commands").
    public static var commands: [String] { letters.map { "x\($0)060110X" } }

    public static var requested: [String: String] {
        var out: [String: String] = [:]
        for n in 1...channelCount {
            let k = key(n)
            out[k + ".gain"] = gain; out[k + ".input"] = "normal"; out[k + ".bias"] = "included"
            out[k + ".srb2"] = "connected"; out[k + ".power"] = "on"
        }
        return out
    }

    static func key(_ channel: Int) -> String { String(format: "ch%02d", channel) }
}

/// Parses the Cyton firmware's `?` reply (its ADS1299 register dump, the Daisy's after the
/// board's) into readback keys like `ch01.gain = "24"`, keeping the reply under `raw`.
///
/// Line format from the firmware source (`RREGS`): `NAME, AA, VV, b7, …, b0` with
/// two-digit hex address and value, under exactly the headers "Board ADS Registers" then
/// "Daisy ADS Registers". Anything else yields `raw` only, never a guess (brief 004).
public enum CytonRegisterReadback {
    static let gains = [0: "1", 1: "2", 2: "4", 3: "6", 4: "8", 5: "12", 6: "24"]
    static let inputs = ["normal", "shorted", "bias_meas", "mvdd", "temp", "testsig", "bias_drp", "bias_drn"]

    public static func parse(_ reply: String) -> [String: String] {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        var out = ["raw": reply]
        // One register map per ADS1299 block; the Daisy's block starts at its header.
        var maps: [[String: UInt8]] = []
        var headers: [String] = []
        for line in reply.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("Registers") {
                headers.append(text)
                if text.hasSuffix("ADS Registers") { maps.append([:]) } else { break }   // LIS3DH ends the ADS part
                continue
            }
            let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 11, !maps.isEmpty, let value = UInt8(fields[2], radix: 16) else { continue }
            maps[maps.count - 1][fields[0].uppercased()] = value
        }
        guard headers.prefix(2) == ["Board ADS Registers", "Daisy ADS Registers"], maps.count == 2 else { return out }
        var parsed: [String: String] = [:]
        for (block, map) in maps.enumerated() {
            guard let sensP = map["BIAS_SENSP"] else { return out }
            for i in 1...8 {
                guard let set = map["CH\(i)SET"], let gain = gains[Int(set >> 4) & 0x7] else { return out }
                let k = DefaultChannelSettings.key(block * 8 + i)
                parsed[k + ".power"] = set & 0x80 == 0 ? "on" : "off"
                parsed[k + ".gain"] = gain
                parsed[k + ".srb2"] = set & 0x08 == 0 ? "disconnected" : "connected"
                parsed[k + ".input"] = inputs[Int(set & 0x7)]
                parsed[k + ".bias"] = sensP & (1 << (i - 1)) == 0 ? "excluded" : "included"
            }
        }
        out.merge(parsed) { a, _ in a }
        return out
    }

    /// Whether the readback holds per-channel register values (not just `raw` / replies).
    public static func hasRegisters(_ readback: [String: String]) -> Bool { readback["ch01.gain"] != nil }

    /// The firmware's answer to a channel command when not streaming (Cyton SDK docs).
    static func isSuccess(_ reply: String) -> Bool { reply.hasPrefix("Success") }

    /// The first channel whose settings command was not acknowledged with a success reply.
    /// Fails closed: on a real device a missing `acknowledged` key counts as not acknowledged.
    public static func unacknowledged(_ requested: [String: String]) -> Int? {
        (1...DefaultChannelSettings.channelCount).first { requested[DefaultChannelSettings.key($0) + ".acknowledged"] != "yes" }
    }

    /// Per-channel values (registers and acknowledgements) without the raw texts, to tell
    /// whether a reconnect left the board as the recording describes it.
    static func settings(_ c: RecordingManifest.BoardConfiguration) -> [String: String] {
        let keep = { (k: String, _: String) in k != "raw" && !k.hasSuffix(".reply") }
        return c.requested.filter(keep).merging(c.readback.filter(keep)) { a, b in a + "|" + b }
    }

    /// The first EEG channel whose reported gain differs from the requested 24, if any.
    public static func gainMismatch(_ readback: [String: String]) -> (channel: Int, gain: String)? {
        for n in 1...DefaultChannelSettings.channelCount {
            if let g = readback[DefaultChannelSettings.key(n) + ".gain"], g != DefaultChannelSettings.gain { return (n, g) }
        }
        return nil
    }
}

extension ChannelMapRecord {
    /// A map fits a board only with exactly its EEG rows, in order (never accel or aux rows
    /// scaled as µV), every channel EEG in µV.
    public func fits(_ board: BoardDescription) -> Bool {
        channels.map(\.sourceRow) == board.eegChannelRows && channels.allSatisfy { $0.kind == "eeg" && $0.unit == "uV" }
    }

    /// The default map: BrainFlow's names, reference SRB2, montage "undeclared" (decision #31).
    public static func defaults(for board: BoardDescription) -> ChannelMapRecord {
        let channels = zip(board.eegChannelRows, board.eegNames).enumerated().map { i, pair in
            ChannelSpec(id: DefaultChannelSettings.key(i + 1), label: pair.1, kind: "eeg", unit: "uV", sourceRow: pair.0)
        }
        return .init(montage: "undeclared", reference: "SRB2", channels: channels)
    }
}

extension AcquisitionSource {
    /// Only the Cyton answers `?` with registers; synthetic echoes and playback is silent,
    /// so their readback stays empty and is never filled from `requested`.
    var readsBackRegisters: Bool { if case .serial = self { true } else { false } }

    /// Sends the default settings and, when the board can, reads its registers back. Each
    /// channel's reply is kept: on the Cyton, `chNN.acknowledged` is "yes" only for a
    /// "Success" reply; boards without a device record "not applicable", never "yes".
    func applyDefaultConfiguration(to board: any AcquisitionBoard) async throws -> RecordingManifest.BoardConfiguration {
        var requested = DefaultChannelSettings.requested
        var readback: [String: String] = [:]
        for (i, command) in DefaultChannelSettings.commands.enumerated() {
            let reply = try await board.configure(command)
            let k = DefaultChannelSettings.key(i + 1)
            requested[k + ".command"] = command
            guard readsBackRegisters else { requested[k + ".acknowledged"] = "not applicable"; continue }
            requested[k + ".acknowledged"] = CytonRegisterReadback.isSuccess(reply) ? "yes" : "no"
            readback[k + ".reply"] = reply
        }
        if readsBackRegisters { readback.merge(CytonRegisterReadback.parse(try await board.configure("?"))) { a, _ in a } }
        return .init(requested: requested, readback: readback)
    }
}
