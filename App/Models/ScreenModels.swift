import Foundation

// Small, synchronous view models for the brief 001 screens (docs/product/briefs/001-ui-spec.md).
// Views stay thin: every string a screen shows about the data is built here, from the
// stored records, so tests can check it without rendering anything.

/// Fixed-point formatting that never depends on the user's locale, so a stored number
/// reads the same in every screenshot, test and export.
enum Fmt {
    static func fixed(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
    static func signed(_ value: Double, _ digits: Int = 2) -> String { String(format: "%+.\(digits)f", value) }
    static func interval(_ ci: [Double], _ digits: Int = 2) -> String? {
        guard ci.count == 2 else { return nil }
        return "\(fixed(ci[0], digits))–\(fixed(ci[1], digits))"
    }
    static func hertz(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) Hz" : "\(fixed(value, 3)) Hz"
    }

    /// "2026-11-21 13:17": local wall-clock time in one fixed, locale-independent shape. Every
    /// screen names a stored time this way (model and run names, lists, created dates).
    static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                                locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
    }

    /// "Today, 7:58 AM", "Yesterday, 7:58 AM", else "Nov 27, 2026, 7:58 AM": a stored time as
    /// people read it (decision #67). Tests pin `now`, `locale`, `timeZone` and `calendar`.
    static func relativeDateTime(_ date: Date, now: Date = Date(), locale: Locale = .current,
                                 timeZone: TimeZone = .current, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        cal.locale = locale
        let time = shortTime(date, locale: locale, timeZone: timeZone, calendar: cal)
        if cal.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday, \(time)" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: cal, timeZone: timeZone)
        style.capitalizationContext = .standalone
        return "\(date.formatted(style)), \(time)"
    }

    /// "7:58 AM" (or "07:58" where the locale uses a 24-hour clock).
    static func shortTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))
    }

    /// "13:17", local, for lists whose rows are already grouped by day.
    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                                locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
    }
}

// MARK: - Welcome

/// The three entry points of the welcome window (decision #7: nothing auto-opens).
struct WelcomeAction: Identifiable, Equatable {
    enum Kind: String, Equatable { case example, open, hardware }

    let kind: Kind
    let title: String
    let caption: String
    let symbol: String
    /// Nil when the action is available; otherwise why not, shown as caption, help and
    /// accessibility hint so the disabled state never relies on dimming alone.
    let disabledReason: String?

    var id: Kind { kind }
    var isEnabled: Bool { disabledReason == nil }
}

enum WelcomeModel {
    /// Order per the UI spec §2: example first (the no-hardware path), then open, then hardware.
    static let actions: [WelcomeAction] = [
        WelcomeAction(kind: .example, title: "Explore an example",
                      caption: "A public motor-imagery recording (PhysioNet, subject S001). Creates a project in Documents.",
                      symbol: "sparkles.rectangle.stack", disabledReason: nil),
        WelcomeAction(kind: .open, title: "Open project…",
                      caption: "Open a .bciproj folder.",
                      symbol: "folder", disabledReason: nil),
        WelcomeAction(kind: .hardware, title: "Connect hardware",
                      caption: "Record from an OpenBCI Cyton + Daisy, or try the Demo with no kit. Opens a project first.",
                      symbol: "cable.connector", disabledReason: nil),
    ]

    static let emptyRecents = "No recent projects yet"
    static let emptyRecentsDetail = "Projects you open or create appear here. Start with the example: a public recording you can evaluate in a minute."
    static let emptyRecentsAction = "Explore an example"
}

/// One row of the welcome window's recent-projects list.
struct RecentProject: Identifiable, Equatable {
    let url: URL
    let name: String
    let abbreviatedPath: String
    let modified: Date?
    let exists: Bool

    var id: URL { url }

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        abbreviatedPath = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        exists = fileManager.fileExists(atPath: url.appendingPathComponent(ProjectStore.projectFileName).path)
        modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - Sidebar

/// The project window's sidebar, in the spec's order. Every section is real since brief 006.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case recordings, protocols, pipelines, results, liveTest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .protocols: return "Protocols"
        case .pipelines: return "Models"
        case .results: return "Results"
        case .liveTest: return "Live Test"
        }
    }

    var symbol: String {
        switch self {
        case .recordings: return "waveform"
        case .protocols: return "list.bullet.clipboard"
        case .pipelines: return "cube.transparent"
        case .results: return "chart.bar.doc.horizontal"
        case .liveTest: return "bolt.horizontal.circle"
        }
    }

    /// Whether the row carries a count badge (recordings, results).
    var showsCount: Bool { self == .recordings || self == .results }

    /// The `ContentUnavailableView` copy for sections that arrive in later phases (none now).
    var placeholder: String? { nil }

    static let statusLine = "No hardware connected · Replay mode"
}

// MARK: - Recording detail

/// Which table the recording detail shows.
enum RecordingTab: String, CaseIterable, Identifiable {
    case channels = "Channels", segments = "Segments", events = "Events", quality = "Quality"
    var id: String { rawValue }
}

/// Everything the recording detail shows, taken verbatim from the manifest. A value the
/// manifest leaves empty shows as "undeclared": labels, units and montage are never
/// guessed, least of all from the channel count.
struct RecordingDetailModel {
    static let undeclared = "undeclared"

    struct Field: Identifiable, Equatable {
        let label: String
        let value: String
        /// IDs (runs, seeds) read in monospace.
        var mono = false
        var id: String { label }
    }

    struct Citation: Identifiable, Equatable {
        let text: String
        let doi: String
        var id: String { doi + text }
        var url: URL? { doi.isEmpty ? nil : URL(string: "https://doi.org/" + doi) }
    }

    struct ChannelRow: Identifiable, Equatable {
        let id: String
        /// nil when the manifest declares nothing (empty or whitespace); never filled in.
        let label: String?
        let unit: String?
        let kind: String?
        var labelSortKey: String { label ?? "" }
        var unitSortKey: String { unit ?? "" }
        var kindSortKey: String { kind ?? "" }
    }

    /// A channel table row. `id` is the channel id, except for a repeat of an id the manifest
    /// already used, which gets a suffix so the table's identity never collides; selecting
    /// such a row highlights nothing (MontageLayout lists the repeat as unplaced).
    struct ChannelTableRow: Identifiable, Equatable {
        let row: ChannelRow
        let id: String

        static func rows(_ channels: [ChannelRow]) -> [ChannelTableRow] {
            var used = Set(channels.map(\.id)), seen = Set<String>()
            return channels.map { ch in
                guard seen.insert(ch.id).inserted else {
                    var n = 2, key = "\(ch.id) (\(n))"
                    while used.contains(key) { n += 1; key = "\(ch.id) (\(n))" }
                    used.insert(key)
                    return ChannelTableRow(row: ch, id: key)
                }
                return ChannelTableRow(row: ch, id: ch.id)
            }
        }
    }

    struct SegmentRow: Identifiable, Equatable {
        let index: Int
        let runID: String
        let session: String          // "—" when the source defines none
        let samples: Int
        let duration: String
        let gaps: Int
        let endReason: String
        /// "Run 1" for a run whose stored id is a UUID (live recordings), else the stored id
        /// (decision #63); the stored id stays in the row's tooltip.
        var runName: String = ""
        var sessionName: String = ""
        var id: Int { index }
    }

    struct EventRow: Identifiable, Equatable {
        let id: UUID
        let label: String
        /// Seconds from the start of the event's segment: `sampleIndex / rate`. nil when
        /// the event has no sample association (it is then not placed on the timeline).
        let onsetSeconds: Double?
        let runID: String
        let trial: String
        let segment: Int
        /// "Run 1" when the stored run id is a UUID (see `runName(_:ordinal:)`).
        var runName: String = ""
        var onsetText: String { onsetSeconds.map { Fmt.fixed($0, 3) } ?? "—" }
        var onsetSortKey: Double { onsetSeconds ?? -1 }
    }

    let title: String
    let warning: String?
    /// A neutral chip beside the title: "Demo" for a Demo recording (decision #42), else nil.
    let badge: String?
    let sourceFields: [Field]
    let citations: [Citation]
    let derivations: [String]
    let montage: String
    /// The stored montage and reference strings, verbatim, for `MontageLayout` (brief 003).
    let montageRaw: String
    let referenceRaw: String
    let channels: [ChannelRow]
    /// `channels` with identities the table can't confuse (see `ChannelTableRow`).
    let channelTableRows: [ChannelTableRow]
    /// Built once per model, so hover and selection re-renders never rebuild it (brief 003).
    let montageLayout: MontageLayout
    let segments: [SegmentRow]
    let events: [EventRow]
    let isPublicDataset: Bool

    init(manifest m: RecordingManifest, events: [EventRecord]) {
        let s = m.source
        title = Self.title(for: m)
        isPublicDataset = s.kind == "public_dataset"
        // The manifest's own warning is the first line of the source panel (Records.swift);
        // a public dataset without one still gets the spec's line, built from its name.
        // Decision #42: on screen the Demo is just "Demo". Its stored provenance (playback
        // kind, file, hash, derivation, warning) stays in the manifest and every export.
        let demo = Self.isDemo(m)
        badge = demo ? Self.demo : nil
        warning = Self.pageWarning(for: m)

        var fields: [Field] = []
        if demo {
            // The Demo's rate is this recording's (the file it plays was resampled for the
            // board), so it leads beside "Device", and the dataset reads as what the signal was
            // derived from, never paired with that rate as if it were the dataset's own.
            fields.append(Field(label: "Sample rate", value: Fmt.hertz(m.timing.nominalSampleRateHz)))
            fields.append(Field(label: "Device", value: Self.demo))
            fields.append(Field(label: "Reference", value: Self.declared(m.reference) ?? Self.undeclared))
            if let dataset = s.dataset { fields.append(Field(label: Self.demoDerivedFrom, value: dataset)) }
            if let license = s.license { fields.append(Field(label: "License", value: license)) }
        } else {
            if let dataset = s.dataset { fields.append(Field(label: "Dataset", value: dataset)) }
            if let doi = s.doi { fields.append(Field(label: "DOI", value: doi)) }
            if let subject = s.subject { fields.append(Field(label: "Subject", value: subject)) }
            fields.append(Field(label: "Runs", value: (s.runs ?? m.segments.map(\.runID)).joined(separator: ", ")))
            fields.append(Field(label: "Sample rate", value: Fmt.hertz(m.timing.nominalSampleRateHz)))
            fields.append(Field(label: "Reference", value: Self.declared(m.reference) ?? Self.undeclared))
            fields.append(Field(label: "Device", value: Self.declared(s.boardName) ?? Self.undeclared))
            if let license = s.license { fields.append(Field(label: "License", value: license)) }
        }
        sourceFields = fields
        citations = (s.attribution ?? []).map { Citation(text: $0.text, doi: $0.doi) }
        derivations = s.derivations ?? []
        montage = Self.declared(m.montage) ?? Self.undeclared
        montageRaw = m.montage
        referenceRaw = m.reference

        channels = m.channels.map {
            ChannelRow(id: $0.id, label: Self.declared($0.label), unit: Self.declared($0.unit), kind: Self.declared($0.kind))
        }
        channelTableRows = ChannelTableRow.rows(channels)
        montageLayout = MontageLayout(montage: m.montage, reference: m.reference, channels: channels)

        let rate = m.timing.nominalSampleRateHz
        var runOrdinal: [String: Int] = [:], sessionOrdinal: [String: Int] = [:]
        for seg in m.segments.sorted(by: { $0.index < $1.index }) {
            if runOrdinal[seg.runID] == nil { runOrdinal[seg.runID] = runOrdinal.count + 1 }
            if let s = seg.sessionID, sessionOrdinal[s] == nil { sessionOrdinal[s] = sessionOrdinal.count + 1 }
        }
        segments = m.segments.sorted { $0.index < $1.index }.map { seg in
            let samples = m.chunks.filter { $0.segment == seg.index }.reduce(0) { $0 + $1.sampleCount }
            return SegmentRow(index: seg.index, runID: seg.runID, session: seg.sessionID ?? "—", samples: samples,
                              duration: rate > 0 ? "\(Fmt.fixed(Double(samples) / rate, 1)) s" : "—",
                              gaps: seg.detectedGaps.count, endReason: seg.endReason?.rawValue ?? "—",
                              runName: Self.runName(seg.runID, ordinal: runOrdinal[seg.runID] ?? 1),
                              sessionName: seg.sessionID.map { UUID(uuidString: $0) != nil ? "Session \(sessionOrdinal[$0] ?? 1)" : $0 } ?? "—")
        }
        self.events = events.map { e in
            EventRow(id: e.eventID, label: e.label,
                     onsetSeconds: e.sampleAssociation.flatMap { rate > 0 ? Double($0.sampleIndex) / rate : nil },
                     runID: e.runID, trial: e.trialID ?? "—", segment: e.sampleAssociation?.segment ?? Int.max,
                     runName: Self.runName(e.runID, ordinal: runOrdinal[e.runID] ?? 1))
        }.sorted { ($0.segment, $0.onsetSortKey) < ($1.segment, $1.onsetSortKey) }
    }

    /// A run's name for primary text: a generated UUID becomes "Run N"; a dataset's own
    /// run name (S001R04) is already readable and stays.
    static func runName(_ runID: String, ordinal: Int) -> String {
        UUID(uuidString: runID) != nil ? "Run \(ordinal)" : runID
    }

    /// The warning chip at the top of the recording page: the manifest's own warning (a
    /// public dataset without one gets the spec's line); none for the Demo (decision #42).
    static func pageWarning(for m: RecordingManifest) -> String? {
        let s = m.source
        guard !isDemo(m) else { return nil }
        return s.warning ?? (s.kind == "public_dataset" ? "Public recording (\(s.dataset ?? "public dataset")) — not recorded on your device." : nil)
    }

    static let demo = "Demo"
    static let demoDerivedFrom = "Derived from"

    /// Recorded from the bundled Demo source: playback of the Demo file.
    static func isDemo(_ m: RecordingManifest) -> Bool {
        m.source.kind == "playback" && m.source.sourceFiles?.first?.name == AcquisitionSource.demoFileName
    }

    /// A stored string, or nil when it declares nothing.
    static func declared(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    static func title(for m: RecordingManifest) -> String {
        if let subject = m.source.subject {
            return "\(subject) · \(m.segments.count) run\(m.segments.count == 1 ? "" : "s")"
        }
        return liveTitle(for: m) ?? m.runID
    }

    static func summary(for m: RecordingManifest) -> String {
        "\(m.channels.count) channels · \(m.segments.count) segment\(m.segments.count == 1 ? "" : "s") · \(Fmt.hertz(m.timing.nominalSampleRateHz))"
    }
}

/// The example's info panel: provenance and attribution, read from the manifest. The
/// attribution text is the same one every export writes (`ProjectStore.attribution`).
struct ExampleInfo: Equatable {
    let dataset: String
    let doi: String?
    let license: String?
    let subject: String?
    let runs: [String]
    let warning: String?
    let citations: [RecordingDetailModel.Citation]
    let derivations: [String]
    let attributionText: String

    /// nil for anything that is not a public dataset: a user's own recording has no
    /// attribution to show.
    init?(manifest m: RecordingManifest) {
        let s = m.source
        guard s.kind == "public_dataset", let dataset = s.dataset else { return nil }
        self.dataset = dataset
        doi = s.doi
        license = s.license
        subject = s.subject
        runs = s.runs ?? m.segments.map(\.runID)
        warning = s.warning
        citations = (s.attribution ?? []).map { .init(text: $0.text, doi: $0.doi) }
        derivations = s.derivations ?? []
        attributionText = ProjectStore.attribution(for: m)
    }

    /// Every string the panel displays, for tests and the accessibility summary.
    var displayedText: String {
        ([dataset, doi, license, subject, warning].compactMap { $0 } + runs + citations.map { "\($0.text) doi:\($0.doi)" } + derivations)
            .joined(separator: "\n")
    }
}

// MARK: - Evaluate progress

/// The determinate progress bar's label and accessibility value for one runner state.
struct ProgressDisplay: Equatable {
    enum Mark: Equatable {
        case done, current, pending
        /// Marks differ by shape, not colour.
        var symbol: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .current: return "circle.inset.filled"
            case .pending: return "circle"
            }
        }
    }

    let stage: String
    let detail: String
    let fraction: Double
    let accessibilityValue: String
    /// Index into `stages` of the stage under way (0 while the worker starts).
    let currentIndex: Int

    func mark(for index: Int) -> Mark {
        index < currentIndex ? .done : index == currentIndex ? .current : .pending
    }

    /// The worker reports loading, one event per cross-validation fold, then one per final
    /// fit + holdout scoring; "fit" and "holdout" are therefore one stage here.
    static let stages = ["Loading", "Cross-validation", "Fit and holdout", "Saving"]

    init(_ p: EvaluationRunner.Progress, modelName: (String) -> String) {
        fraction = p.fraction
        let position: Int?
        switch p {
        case .starting:
            stage = "Starting"; detail = "Starting the analysis worker"; position = nil
        case .loading:
            stage = Self.stages[0]; detail = "Reading and verifying the recording"; position = 1
        case .fitting(let model, let fold, let of, _, _):
            stage = Self.stages[1]; detail = "\(modelName(model)), fold \(fold) of \(of)"; position = 2
        case .holdout(let model, _, _):
            stage = Self.stages[2]; detail = "\(modelName(model)) scored on the held-out runs"; position = 3
        case .storing:
            stage = Self.stages[3]; detail = "Storing the result in the project"; position = 4
        }
        currentIndex = position.map { $0 - 1 } ?? 0
        let name = stage
        accessibilityValue = position.map { "\(name), \($0) of \(Self.stages.count)" } ?? name
    }
}

// MARK: - Project window chrome

/// Toolbar, placeholder and banner copy for the project window (brief 011).
enum WindowCopy {
    static let evaluateHelp = "Evaluate the selected recording (⌘R)"
    static let cancelHelp = "Cancel the evaluation (⌘.)"
    static let parametersHelp = "Evaluation parameters: seed, CSP components and the analysis window"
    static let parametersDisabled = "Parameters apply to the next evaluation; they can't change while one runs."
    static let exportHelp = "Export the selected result (⇧⌘X)"
    static let resultLoading = "The result is still loading."
    static let inspectorShow = "Show Inspector (⌥⌘I)"
    static let inspectorHide = "Hide Inspector (⌥⌘I)"
    static let inspectorLive = "Evaluate works on a saved recording; the inspector returns when you leave the live view."

    /// Models section with nothing frozen yet (decision #64: no release-planning copy).
    static let noModelsTitle = "No frozen models yet"
    static let noModelsText = "A frozen model is a result's fitted classifier, kept for replay and live feedback. "
        + "Open a result and choose Freeze for live use…."
    static let showResults = "Show Results"
    static let noModelSelected = "Select a model to see its details and replays."

    static let analysisUnavailableTitle = "Analysis unavailable"
    static let analysisUnavailableMessage = "The analysis worker stopped. Your recording is unchanged. Retry starts a fresh worker."
    static let evaluationFailedTitle = "Evaluation failed"
    static let evaluationFailedMessage = "The analysis worker refused this request; nothing was saved. Retrying without a change will fail the same way."
}
