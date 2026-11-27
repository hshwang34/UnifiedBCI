import Foundation

// Brief 004 PR 6: the live acquisition screen's copy and the preview's drawing data, the
// project window's status line, and the close-while-recording question. Pure and
// locale-independent, like the other models; the views only lay these out.

/// The preview: every channel stacked, the last 10 s, raw µV with each channel's mean
/// removed for display only. Envelopes (min/max per column) so one Canvas pass draws it.
struct LivePreviewModel {
    enum Scale: Hashable {
        case auto
        /// Lane height in µV.
        case fixed(Double)
    }

    static let fixedHeights: [Double] = [20, 50, 100, 200, 500, 1000]
    static let title = "Live preview"
    static let scaleLabel = "Lane height"
    static let autoTitle = "Auto"
    static let caption = "Raw µV, each channel's mean removed for display only. Frames may be skipped under load; the recording never is."
    static let waiting = "Waiting for samples…"
    static let segmentTag = "new segment"
    /// A lane with no label in the map (never shown for a board's own channels).
    static func fallbackLabel(_ index: Int) -> String { "Channel \(index + 1)" }

    struct Envelope: Equatable {
        let lo: Float
        let hi: Float
    }

    struct Lane: Equatable {
        let label: String
        /// One per column, oldest left; nil where the window has no sample yet.
        let columns: [Envelope?]
        /// Part of the trace runs past the lane's ± half height and is clipped.
        let clipped: Bool
    }

    let lanes: [Lane]
    /// Lane height in µV (the fixed choice, or the auto one).
    let height: Double
    /// Columns where a stream segment starts inside the window (every reconnect).
    let breakColumns: Set<Int>
    let filledSeconds: Double

    init(window w: PreviewBuffer.Window, labels: [String], columns: Int, height: Double) {
        self.height = height
        let n = max(1, columns)
        // The newest sample sits at the right edge; an unfilled window is empty on the left.
        let offset = w.capacity - w.count
        func column(_ i: Int) -> Int { min(n - 1, (offset + i) * n / max(1, w.capacity)) }
        filledSeconds = Double(w.count) / Double(max(1, w.rate))
        breakColumns = Set(w.segmentStarts.map(column))
        let half = Float(height / 2)
        lanes = w.channels.enumerated().map { c, samples in
            let label = c < labels.count ? labels[c] : Self.fallbackLabel(c)
            guard !samples.isEmpty else { return Lane(label: label, columns: Array(repeating: nil, count: n), clipped: false) }
            let mean = Float(samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count))
            var cols = [Envelope?](repeating: nil, count: n)
            var clipped = false
            for (i, v) in samples.enumerated() {
                let x = column(i), d = v - mean
                if abs(d) > half { clipped = true }
                if let e = cols[x] { cols[x] = Envelope(lo: min(e.lo, d), hi: max(e.hi, d)) } else { cols[x] = Envelope(lo: d, hi: d) }
            }
            return Lane(label: label, columns: cols, clipped: clipped)
        }
    }

    /// The auto lane height: the 1-2-5 step at or above 85 % of the median channel's
    /// 2nd–98th percentile spread, so a typical trace fills its lane (rare peaks clip at the
    /// lane edge) and one noisy or flat channel doesn't set everyone's scale.
    static func autoHeight(_ w: PreviewBuffer.Window) -> Double {
        let spans = w.channels.compactMap { samples -> Double? in
            guard samples.count > 1 else { return nil }
            let s = samples.sorted()
            let lo = s[Int(Double(s.count - 1) * 0.02)], hi = s[Int(Double(s.count - 1) * 0.98)]
            return Double(hi - lo)
        }.sorted()
        guard !spans.isEmpty else { return 100 }
        return TraceModel.nice(max(spans[spans.count / 2] * 0.85, 1))
    }

    static func heightText(_ height: Double, auto: Bool) -> String {
        "\(scaleLabel) \(TraceModel.scaleNumber(height)) µV" + (auto ? " · auto" : "")
    }

    static func pickerTitle(_ s: Scale) -> String {
        switch s {
        case .auto: return autoTitle
        case .fixed(let h): return "\(TraceModel.scaleNumber(h)) µV"
        }
    }

    /// Ticks at −10, −8 … 0 s; 0 is the newest sample.
    static let ticks: [Int] = [-10, -8, -6, -4, -2, 0]
    static func tickLabel(_ t: Int) -> String { t == 0 ? "now" : "\(t) s" }

    static func accessibilityLabel(channels: Int, height: Double, filled: Double) -> String {
        "Live preview of \(channels) channels, the last \(Fmt.fixed(min(filled, 10), 0)) seconds, lane height \(TraceModel.scaleNumber(height)) microvolts."
    }
}

/// The acquisition screen's own copy (health rows, banners and buttons come from AcquisitionModels).
enum LiveScreenModel {
    /// The inspector while the live view is shown (brief 009: it stays open instead of collapsing).
    static let inspectorNoteTitle = "Evaluate"
    static let inspectorNote = "Evaluate works on a saved recording. Stop recording, then select the recording in the list to evaluate it."
    static let rowTitle = "Live"
    static let healthHeader = "Stream health"
    static let channelMap = "Channel Map…"
    static let channelMapHelp = "Open the Connect sheet to see the board and declare the channel map."
    static let newRecording = "New Recording…"
    static let newRecordingHelp = "Connect a board, the synthetic board or the Demo, and record into this project."
    static let recordHelp = "Record into this project; samples are committed about once a second."
    static let stopHelp = "Stop recording; the stream and preview keep running."
    static let disconnectHelp = "Stop streaming and release the board."
    static let showRecording = "Show Recording"
    static let recordingBadge = "Recording"
    static let emptyRecordings = "No recordings yet. Choose New Recording… (⌥⌘N) to record from a board, the synthetic board or the Demo."
    static let disconnectQuestion = "Stop recording and disconnect?"
    static let disconnectInfo = "Everything recorded so far is saved; the recording ends here as stopped and the board is released."
    static let disconnectConfirm = "Stop Recording and Disconnect"
    static let disconnectKeep = "Keep Recording"
    /// The Live row's selection tag in the Recordings list (never a recording's id).
    static let rowID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func title(_ source: ConnectSource) -> String { "\(rowTitle) · \(source.title)" }

    /// Under the title while recording: elapsed wall time and what is committed so far.
    static func recordingLine(elapsedS: Double, committedSamples: Int, rateHz: Double) -> String {
        let saved = Double(committedSamples) / max(rateHz, 1)
        return "Recording · \(clock(elapsedS)) · \(Fmt.fixed(saved, 0)) s saved"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// After a plain Stop: where the recording went.
    static func saved(seconds: Double) -> String { "Recording saved: \(Fmt.fixed(seconds, 0)) s. It is listed under Recordings." }

    static func mapLine(_ choice: ChannelMapChoice) -> String {
        switch choice {
        case .none: return "Channel map: not declared"
        case .confirmed(let m): return "Channel map: \(ChannelMapModel.pickerTitle(m))"
        case .withoutPositions: return "Channel map: without positions (montage \"undeclared\")"
        }
    }
}

extension AcquisitionStateModel {
    /// The sidebar's two lines: the state in words (with every reconnect named), then the source.
    static func statusLines(_ state: State, source: ConnectSource, recording: Bool, reconnects: Int) -> (state: String, source: String) {
        let again = reconnects == 0 ? "" : " · reconnected \(reconnects)×"
        let words: String
        switch state {
        case .disconnected: words = "Disconnected"
        case .connecting: words = "Connecting"
        case .ready: words = "Ready"
        case .streaming: words = (recording ? "Recording" : "Streaming") + again
        case .interrupted(let reason): words = "Interrupted: \(reason)" + again
        case .stopping: words = "Stopping"
        case .failed(let reason): words = "Failed: \(reason)"
        }
        return (words, source.statusName)
    }

    /// The status symbol: shape differs by state, never colour alone.
    static func symbol(_ state: State, recording: Bool) -> String {
        switch state {
        case .disconnected: return "cable.connector.slash"
        case .connecting, .ready, .stopping: return "cable.connector"
        case .streaming: return recording ? "record.circle.fill" : "waveform"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }
}

/// What closing a project window asks first.
enum CloseConfirmation: Equatable {
    case evaluation, recording

    var message: String {
        switch self {
        case .evaluation: return "Stop the evaluation and close?"
        case .recording: return "Stop recording and close?"
        }
    }

    var info: String {
        switch self {
        case .evaluation: return "Nothing will be saved."
        case .recording: return "Everything recorded so far is saved; the recording ends here as stopped and the board is released."
        }
    }

    var confirm: String {
        switch self {
        case .evaluation: return "Stop and Close"
        case .recording: return "Stop Recording and Close"
        }
    }

    var keep: String {
        switch self {
        case .evaluation: return "Keep Running"
        case .recording: return "Keep Recording"
        }
    }
}

extension RecordingDetailModel {
    /// A recording made in this app has no subject; it is named by its source and start time.
    static func liveTitle(for m: RecordingManifest, timeZone: TimeZone = .current) -> String? {
        let kind: String
        switch m.source.kind {
        case "brainflow": kind = "Recording"
        case "synthetic": kind = "Synthetic recording"
        // Decision #42: the bundled Demo file is "Demo" on screen; other playback files aren't.
        case "playback": kind = m.source.sourceFiles?.first?.name == AcquisitionSource.demoFileName ? "Demo recording" : "Playback recording"
        default: return nil
        }
        return "\(kind) · \(Fmt.dateTime(m.createdAt, timeZone: timeZone))"
    }
}

/// Welcome ▸ Connect hardware with no project open (decision #30).
enum ConnectHardwareModel {
    static let needsProject = "Recordings are saved in a project"
    static let needsProjectInfo = "Create a project or open one, then connect a board, the synthetic board or the Demo."
    static let newProject = "New Project…"
    static let openProject = "Open Project…"
    static let cancel = "Cancel"
}
