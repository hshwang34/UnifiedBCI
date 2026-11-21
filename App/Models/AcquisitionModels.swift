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

    /// A real board: its channel commands must be acknowledged (same rule as the session).
    var isDevice: Bool { if case .serial = self { true } else { false } }

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
            // The Demo is "Demo" only (decision #42); channels and rate follow below.
            ("Board", source == .demo ? "Demo" : "\(board.name) (BrainFlow board \(board.boardID))"),
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

    static let notAcknowledgedMark = "not acknowledged by the board"
    /// Lead decision: a real Cyton without register readback may record, with this warning.
    static let gainNotConfirmed = "Gain not confirmed by the board; µV scaling assumes 24."

    static func rows(_ c: RecordingManifest.BoardConfiguration) -> [ConfigurationRow] {
        (1...DefaultChannelSettings.channelCount).map { n in
            let k = DefaultChannelSettings.key(n)
            let unacked = c.requested[k + ".acknowledged"] == "no"
            let req = describe(c.requested, k).map { unacked ? "\($0) · \(notAcknowledgedMark)" : $0 }
            let back = describe(c.readback, k)
            return .init(channel: "Channel \(n)", requested: req ?? "—", readback: back ?? "—",
                         differs: unacked || (back != nil && back != describe(c.requested, k)))
        }
    }

    /// Nil when the readback has per-channel register values.
    static func readbackNote(_ c: RecordingManifest.BoardConfiguration) -> String? {
        if CytonRegisterReadback.hasRegisters(c.readback) { return nil }
        return c.readback["raw"] == nil ? noReadback : rawOnly
    }

    /// Record is disabled with this when any channel reports another gain.
    static func gainMismatch(_ c: RecordingManifest.BoardConfiguration) -> String? {
        CytonRegisterReadback.gainMismatch(c.readback).map { message(.gainMismatch(channel: $0.channel, gain: $0.gain)) }
    }

    static func message(_ p: AcquisitionSession.ConfigurationProblem) -> String {
        switch p {
        case .gainMismatch(let n, let g):
            return "Channel \(n) reports gain \(g); µV scaling assumes \(DefaultChannelSettings.gain). Reconnect to reset."
        case .notAcknowledged(let n):
            return "Channel \(n) did not acknowledge its settings, so µV scaling can't be trusted. Reconnect to retry."
        case .changedOnReconnect:
            return "The board came back from the reconnect with different settings."
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

    static func mismatch(mapChannels: Int, boardChannels: Int) -> String {
        "This channel map's \(mapChannels) channels don't match this board's \(boardChannels) EEG channels. Pick another map or Record without positions."
    }

    /// Under the picker when saved maps were skipped as unreadable or invalid; nil for none.
    static func unreadable(_ n: Int) -> String? {
        n == 0 ? nil : n == 1 ? "1 saved map couldn't be read and isn't listed." : "\(n) saved maps couldn't be read and aren't listed."
    }

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

    static func disabledReason(state: AcquisitionSession.State, source: ConnectSource, board: BoardDescription?,
                               configuration: RecordingManifest.BoardConfiguration?, map: ChannelMapChoice) -> String? {
        guard state == .streaming else { return notStreaming }
        if let c = configuration, let problem = AcquisitionSession.problem(c, isDevice: source.isDevice) { return ConfigurationModel.message(problem) }
        if case .confirmed(let m) = map, let board, !m.fits(board) {
            return ChannelMapModel.mismatch(mapChannels: m.channels.count, boardChannels: board.eegChannelRows.count)
        }
        return map == .none ? ChannelMapModel.undecided : nil
    }

    /// Shown next to an enabled Record: a real board that didn't report its registers.
    static func warning(source: ConnectSource, configuration: RecordingManifest.BoardConfiguration?) -> String? {
        guard case .serial = source, let c = configuration, !CytonRegisterReadback.hasRegisters(c.readback) else { return nil }
        return ConfigurationModel.gainNotConfirmed
    }

    /// What a refused `startRecording` says.
    static func message(_ e: AcquisitionSession.SessionError) -> String {
        switch e {
        case .notStreaming: return notStreaming
        case .alreadyRecording: return "Already recording."
        case .streamEnded: return "The stream ended while the recording was starting; nothing was recorded."
        case .configuration(let p): return ConfigurationModel.message(p)
        case .channelMapMismatch(let m, let b): return ChannelMapModel.mismatch(mapChannels: m, boardChannels: b)
        }
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
            rows.append(("Free disk", megabytes(free) + (h.hoursLeft.map { " · about \(Fmt.fixed($0, 1)) h of recording" } ?? "")))
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

    /// A recording a reconnect ended (`Snapshot.recordingEndedByReconnect`).
    static func endedByReconnect(_ p: AcquisitionSession.ConfigurationProblem) -> String {
        "Recording ended at the reconnect, so no segment is stored with the wrong scaling: " + ConfigurationModel.message(p)
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

/// The Connect sheet's own copy (brief 004 PR 5): headings, the source list, the tabs and
/// the channel-map editor's messages. State words and buttons come from the models above.
enum ConnectSheetModel {
    static let title = "Connect a Board"
    static let serialHeader = "Serial ports"
    static let noHardwareHeader = "Without hardware"
    static let noPorts = "No serial ports found. Plug in the dongle and choose Refresh."
    static let refresh = "Refresh"
    static let close = "Close"
    static let closeHelp = "Close the sheet. A board that isn't streaming yet is disconnected; a streaming one stays on the acquisition screen."
    static let demoMissing = "The Demo file isn't in this build (it is generated at build time with uv)."
    static let connecting = "Opening the board, sending the channel settings and reading them back…"
    static let pickSource = "Pick a source to connect."
    static let identityHeader = "Identity"
    static let configurationHeader = "Requested vs readback"
    static let columns = ("Channel", "Requested", "Readback")
    static let differs = "Readback differs from requested"
    static let sectionPicker = "Section"
    static let unknownVersion = "unknown"
    static func channelName(_ n: Int) -> String { "Channel \(n)" }

    enum Tab: String, CaseIterable, Identifiable {
        case board = "Board", channelMap = "Channel map"
        var id: String { rawValue }
    }

    /// The one problem or warning the configuration carries, worst first.
    static func configurationAlert(_ c: RecordingManifest.BoardConfiguration, source: ConnectSource) -> (danger: Bool, text: String)? {
        if let p = AcquisitionSession.problem(c, isDevice: source.isDevice) { return (true, ConfigurationModel.message(p)) }
        return RecordGate.warning(source: source, configuration: c).map { (false, $0) }
    }
}

/// The channel-map editor (decision #31): labels, reference, montage, saved maps.
extension ChannelMapModel {
    static let labelsHeader = "Labels"
    static let reference = "Reference"
    static let montage = "Montage"
    static let montageDefault = "undeclared"
    static let savedMaps = "Saved map"
    static let noSavedMap = "None"
    static let save = "Save Map"
    static let saved = "Saved to this project."
    static let edited = "Edited since you confirmed; confirm again to use the changes."

    static func labelField(_ channel: Int) -> String { "Label for channel \(channel)" }

    /// What the operator has decided so far, under the editor.
    static func status(_ choice: ChannelMapChoice) -> String {
        switch choice {
        case .none: return undecided
        case .confirmed(let m): return "Map confirmed: \(pickerTitle(m))."
        case .withoutPositions: return "Recording without positions: BrainFlow's names, montage stored as \"undeclared\"."
        }
    }

    /// Why the edited map can't be confirmed or saved.
    static func invalid(_ problem: String) -> String { "This map can't be used: \(problem)." }
    static func saveFailed(_ error: String) -> String { "Couldn't save the map: \(error)" }

    /// The edited map: the board's defaults with the operator's labels, reference and montage.
    static func edited(board: BoardDescription, labels: [String], reference: String, montage: String) -> ChannelMapRecord {
        var map = ChannelMapRecord.defaults(for: board)
        for i in map.channels.indices where i < labels.count { map.channels[i].label = labels[i].trimmingCharacters(in: .whitespaces) }
        map.reference = reference.trimmingCharacters(in: .whitespaces)
        map.montage = montage.trimmingCharacters(in: .whitespaces)
        return map
    }
}
