import Foundation

// Every string the live-acquisition surfaces show (brief 004): Connect sheet, identity,
// requested vs readback, channel map, health panel, state banner / status line, disk
// warning. Pure and locale-independent; the views (PRs 5–6) only lay these out.

/// What the Connect sheet lists. The Demo is a playback board, but on screen it is
/// "Demo" only (decision #42); its recording still stores `playback` and the file.
enum ConnectSource: Equatable, Identifiable {
    case serial(SerialPort)
    case synthetic
    case demo

    static let syntheticWarning = "Synthetic board — generated signal, not a device"

    var id: String {
        switch self {
        case .serial(let p): return p.path
        case .synthetic: return "synthetic"
        case .demo: return "demo"
        }
    }

    var title: String {
        switch self {
        case .serial(let p): return p.productName ?? (p.path as NSString).lastPathComponent
        case .synthetic: return "Synthetic board (no hardware)"
        case .demo: return "Demo"
        }
    }

    var caption: String {
        switch self {
        case .serial(let p): return [p.vendorName, p.path].compactMap { $0 }.joined(separator: " · ")
        case .synthetic: return Self.syntheticWarning
        case .demo: return "The bundled example EEG, streamed through the live path."
        }
    }

    /// How the status line names the source.
    var statusName: String {
        switch self {
        case .serial(let p): return p.path
        case .synthetic: return Self.syntheticWarning
        case .demo: return "Demo"
        }
    }

    /// Shown when the selected port disappears on a re-scan.
    static func gone(_ port: SerialPort) -> String {
        "\(port.path) is gone. Plug the dongle back in or pick another port."
    }
}

/// The buttons each PRD §7 state enables (brief 004's state table).
enum AcquisitionAction: String, Equatable {
    case connect = "Connect", cancel = "Cancel", startPreview = "Start preview", record = "Record"
    case stopRecording = "Stop recording", reconnectNow = "Reconnect now", retry = "Retry"
    case reconnect = "Reconnect", disconnect = "Disconnect"
}

enum AcquisitionStateModel {
    typealias State = AcquisitionSession.State

    /// `afterStreaming`: failed once the stream had run (retries exhausted) offers
    /// Reconnect (decision #32); a failed connect offers Retry.
    static func actions(_ state: State, recording: Bool, afterStreaming: Bool = false) -> [AcquisitionAction] {
        switch state {
        case .disconnected: return [.connect]
        case .connecting: return [.cancel]
        case .ready: return [.startPreview, .disconnect]
        case .streaming: return [recording ? .stopRecording : .record, .disconnect]
        case .interrupted: return [.reconnectNow, .disconnect]
        case .stopping: return []
        case .failed: return [afterStreaming ? .reconnect : .retry, .disconnect]
        }
    }

    /// The project window's status line, in words; every reconnect is named.
    static func statusLine(_ state: State, source: ConnectSource, recording: Bool, reconnects: Int) -> String {
        let name = source.statusName
        let again = reconnects == 0 ? "" : " · reconnected \(reconnects)×"
        switch state {
        case .disconnected: return "Disconnected · \(name)"
        case .connecting: return "Connecting · \(name)"
        case .ready: return "Ready · \(name)"
        case .streaming: return (recording ? "Recording · " : "Streaming · ") + name + again
        case .interrupted(let reason): return "Interrupted: \(reason) · \(name)" + again
        case .stopping: return "Stopping · \(name)"
        case .failed(let reason): return "Failed: \(reason) · \(name)"
        }
    }

    /// The state banner; nil when the state needs none.
    static func banner(_ state: State) -> String? {
        switch state {
        case .interrupted(let reason):
            return "Stream interrupted (\(reason)). Retrying for up to 30 s; the recording continues in a new segment, nothing is joined across the break."
        case .failed(let reason): return reason
        default: return nil
        }
    }
}

/// The identity panel on Ready (brief 004, "On Ready the sheet shows identity").
enum IdentityModel {
    static func rows(board: BoardDescription, source: ConnectSource, brainflowVersion: String, firmware: String?) -> [(String, String)] {
        let port: String, path: String
        switch source {
        case .serial(let p): (port, path) = (p.path, DataPath.radio125.rawValue)
        case .synthetic: (port, path) = ("none (synthetic board)", "none (synthetic board)")
        case .demo: (port, path) = ("none (Demo)", "none (Demo)")
        }
        return [
            ("Board", "\(board.name) (BrainFlow board \(board.boardID))"),
            ("BrainFlow", brainflowVersion),
            ("Serial port", port),
            ("Firmware", firmware.flatMap { $0.isEmpty ? nil : $0 } ?? "not reported"),
            ("EEG channels", "\(board.eegChannelRows.count)"),
            ("Nominal rate", Fmt.hertz(Double(board.samplingRate))),
            ("Data path", path),
            ("Unit", "µV"),
            ("Sequence step", "\(board.sequenceStep)"),
        ]
    }
}

/// Requested next to readback, one row per channel.
struct ConfigurationRow: Equatable {
    let channel: String
    let requested: String
    let readback: String
    /// Readback differs from requested on this row.
    let differs: Bool
}

enum ConfigurationModel {
    static let noReadback = "No readback from this board"
    static let rawOnly = "The board replied, but not as a register map; its raw reply is kept."

    static func rows(_ c: RecordingManifest.BoardConfiguration) -> [ConfigurationRow] {
        (1...DefaultChannelSettings.channelCount).map { n in
            let k = DefaultChannelSettings.key(n)
            let req = describe(c.requested, k), back = describe(c.readback, k)
            return .init(channel: "Channel \(n)", requested: req ?? "—", readback: back ?? "—",
                         differs: back != nil && back != req)
        }
    }

    /// Nil when the readback has per-channel values.
    static func readbackNote(_ c: RecordingManifest.BoardConfiguration) -> String? {
        if c.readback.isEmpty { return noReadback }
        return c.readback["ch01.gain"] == nil ? rawOnly : nil
    }

    /// Record is disabled with this when any channel reports another gain.
    static func gainMismatch(_ c: RecordingManifest.BoardConfiguration) -> String? {
        CytonRegisterReadback.gainMismatch(c.readback).map {
            "Channel \($0.channel) reports gain \($0.gain); µV scaling assumes \(DefaultChannelSettings.gain). Reconnect to reset."
        }
    }

    private static func describe(_ values: [String: String], _ k: String) -> String? {
        guard let gain = values[k + ".gain"] else { return nil }
        var parts = ["gain \(gain)", values[k + ".input"] ?? "?", "bias \(values[k + ".bias"] ?? "?")", "SRB2 \(values[k + ".srb2"] ?? "?")"]
        if values[k + ".power"] == "off" { parts.append("powered down") }
        return parts.joined(separator: " · ")
    }
}

/// The operator's channel-map decision; Record needs one (decision #31).
enum ChannelMapChoice: Equatable {
    case none
    case confirmed(ChannelMapRecord)
    /// Default names, montage stored as "undeclared".
    case withoutPositions
}

enum ChannelMapModel {
    static let referenceDefault = "SRB2"
    static let confirm = "Confirm map"
    static let withoutPositions = "Record without positions"
    static let withoutPositionsCaption = "Labels stay BrainFlow's names and the montage is stored as \"undeclared\"; no electrode positions are shown."
    static let undecided = "Confirm a channel map, or choose Record without positions."

    /// A row of the saved-map picker.
    static func pickerTitle(_ m: ChannelMapRecord) -> String {
        "\(m.montage) · \(m.channels.count) channels · reference \(m.reference)"
    }

    static func request(for choice: ChannelMapChoice, board: BoardDescription) -> AcquisitionSession.RecordingRequest? {
        switch choice {
        case .none: return nil
        case .confirmed(let m): return .init(map: m)
        case .withoutPositions: return .init(map: .defaults(for: board))
        }
    }
}

/// Whether Record is enabled, and why not, in the order the operator can fix things.
enum RecordGate {
    static let notStreaming = "Start the preview to record."

    static func disabledReason(state: AcquisitionSession.State, configuration: RecordingManifest.BoardConfiguration?,
                               map: ChannelMapChoice) -> String? {
        guard state == .streaming else { return notStreaming }
        if let c = configuration, let mismatch = ConfigurationModel.gainMismatch(c) { return mismatch }
        return map == .none ? ChannelMapModel.undecided : nil
    }
}

/// The health panel (brief 004, "Preview and health"); updated once a second.
enum HealthModel {
    static let footer = "Stream health is about delivery, not signal quality."
    static let order: [(GapEvidence, String)] = [
        (.sequenceSkip, "Counter skips"), (.staleHalf, "Stale halves"), (.invalidCounter, "Unreadable counters"),
        (.overflowSuspected, "Suspected buffer overflows"), (.disconnect, "Disconnects"),
    ]

    static func rows(_ h: StreamHealth, nowNanos: Int64) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Samples this segment", "\(h.samplesThisSegment)"),
            ("Effective rate", h.effectiveRateHz.map { "\(Fmt.fixed($0, 1)) Hz" } ?? "measuring…"),
        ]
        for (evidence, title) in order {
            let t = h.gaps[evidence] ?? .init()
            var text = t.events == 0 ? "none" : "\(t.events) · about \(t.estimatedMissingSamples) samples missing"
            if t.ambiguous > 0 { text += " (\(t.ambiguous) ambiguous)" }
            rows.append((title, text))
        }
        rows.append(("Arrival pauses", h.arrivalPauses == 0 ? "none" : "\(h.arrivalPauses) · arrival pause, no samples lost by counter"))
        rows.append(("Drain interval", spread(h.drainInterval)))
        rows.append(("Timestamp interval", spread(h.timestampInterval)))
        if let w = h.writer {
            rows.append(("Writer backlog", w.backlogChunks == 1 ? "1 chunk" : "\(w.backlogChunks) chunks"))
            rows.append(("Last commit", w.lastCommitMonotonicNanos.map { "\(Fmt.fixed(Double(nowNanos - $0) / 1e9, 1)) s ago" } ?? "none yet"))
        }
        if let free = h.freeBytes {
            rows.append(("Free disk", "\(megabytes(free)) · " + (h.hoursLeft.map { "about \(Fmt.fixed($0, 1)) h of recording" } ?? "")))
        }
        return rows
    }

    /// "Ambiguous": a counter skip of 256/step samples or more looks like a smaller one.
    static func ambiguousNote(step: Int) -> String {
        "Counter estimates are ambiguous: a loss of \(256 / max(step, 1)) samples or more looks like a smaller one."
    }

    static func spread(_ s: StreamHealth.Spread?) -> String {
        guard let s else { return "—" }
        return "p50 \(ms(s.p50)) · p95 \(ms(s.p95)) · max \(ms(s.max))"
    }

    static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }
    static func megabytes(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB free" }
}

/// The disk-space warning before Record (decision #33) and the end-of-recording messages.
enum RecordingEndModel {
    static func diskWarning(hoursLeft: Double?, freeBytes: Int64?) -> String? {
        guard let hoursLeft, let freeBytes, hoursLeft < 1 else { return nil }
        return "Less than 1 hour of recording space left (\(HealthModel.megabytes(freeBytes))). Recording stops at 100 MB free."
    }

    /// Nil for a plain Stop.
    static func message(_ s: RecordingWriter.Status, rateHz: Double) -> String? {
        let saved = Int((Double(s.committedSamples) / max(rateHz, 1)).rounded())
        switch s.endReason {
        case .diskFull?: return "Recording stopped: disk full. \(saved) s recorded and saved."
        case .error?:
            let lost = Int((Double(s.uncommittedSamples) / max(rateHz, 1)).rounded())
            let failure = s.failure ?? "a write failed"
            let head = failure.hasPrefix("The disk could not keep up") ? "The disk could not keep up. Recording stopped" : "Recording stopped (\(failure))"
            return "\(head): \(saved) s recorded and saved" + (lost > 0 ? ", \(lost) s could not be saved." : ".")
        case .disconnect?: return "Recording ended: the board stayed disconnected. \(saved) s recorded and saved."
        default: return nil
        }
    }
}
