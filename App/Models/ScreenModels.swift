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
                      caption: "Cyton + Daisy acquisition arrives in phase 2. Recorded data works today.",
                      symbol: "cable.connector",
                      disabledReason: "Cyton + Daisy acquisition arrives in phase 2. Recorded data works today."),
    ]

    static let emptyRecents = "No recent projects."
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

/// The project window's sidebar, in the spec's order. Protocols and Live Test are
/// present but empty until phases 2 and 3.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case recordings, protocols, pipelines, results, liveTest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .protocols: return "Protocols"
        case .pipelines: return "Pipelines"
        case .results: return "Results"
        case .liveTest: return "Live Test"
        }
    }

    var symbol: String {
        switch self {
        case .recordings: return "waveform"
        case .protocols: return "list.bullet.clipboard"
        case .pipelines: return "slider.horizontal.3"
        case .results: return "chart.bar.doc.horizontal"
        case .liveTest: return "bolt.horizontal.circle"
        }
    }

    /// Whether the row carries a count badge (recordings, results).
    var showsCount: Bool { self == .recordings || self == .results }

    /// The `ContentUnavailableView` copy for sections that arrive in later phases.
    var placeholder: String? {
        switch self {
        case .protocols: return "Protocols arrive in phase 2. Needs a connected board or the cue protocol."
        case .liveTest: return "Live Test arrives in phase 3. Needs a frozen pipeline from phase 2."
        default: return nil
        }
    }

    static let statusLine = "No hardware connected · Replay mode"
}

// MARK: - Recording detail

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

    struct SegmentRow: Identifiable, Equatable {
        let index: Int
        let runID: String
        let session: String          // "—" when the source defines none
        let samples: Int
        let duration: String
        let gaps: Int
        let endReason: String
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
        var onsetText: String { onsetSeconds.map { Fmt.fixed($0, 3) } ?? "—" }
        var onsetSortKey: Double { onsetSeconds ?? -1 }
    }

    let title: String
    let warning: String?
    let sourceFields: [Field]
    let citations: [Citation]
    let derivations: [String]
    let montage: String
    let channels: [ChannelRow]
    let segments: [SegmentRow]
    let events: [EventRow]
    let isPublicDataset: Bool

    init(manifest m: RecordingManifest, events: [EventRecord]) {
        let s = m.source
        title = Self.title(for: m)
        isPublicDataset = s.kind == "public_dataset"
        // The manifest's own warning is the first line of the source panel (Records.swift);
        // a public dataset without one still gets the spec's line, built from its name.
        warning = s.warning ?? (isPublicDataset ? "Public recording (\(s.dataset ?? "public dataset")) — not recorded on your device." : nil)

        var fields: [Field] = []
        if let dataset = s.dataset { fields.append(Field(label: "Dataset", value: dataset)) }
        if let doi = s.doi { fields.append(Field(label: "DOI", value: doi)) }
        if let subject = s.subject { fields.append(Field(label: "Subject", value: subject)) }
        fields.append(Field(label: "Runs", value: (s.runs ?? m.segments.map(\.runID)).joined(separator: ", ")))
        fields.append(Field(label: "Sample rate", value: Fmt.hertz(m.timing.nominalSampleRateHz)))
        fields.append(Field(label: "Reference", value: Self.declared(m.reference) ?? Self.undeclared))
        fields.append(Field(label: "Device", value: Self.declared(s.boardName) ?? Self.undeclared))
        if let license = s.license { fields.append(Field(label: "License", value: license)) }
        sourceFields = fields
        citations = (s.attribution ?? []).map { Citation(text: $0.text, doi: $0.doi) }
        derivations = s.derivations ?? []
        montage = Self.declared(m.montage) ?? Self.undeclared

        channels = m.channels.map {
            ChannelRow(id: $0.id, label: Self.declared($0.label), unit: Self.declared($0.unit), kind: Self.declared($0.kind))
        }

        let rate = m.timing.nominalSampleRateHz
        segments = m.segments.sorted { $0.index < $1.index }.map { seg in
            let samples = m.chunks.filter { $0.segment == seg.index }.reduce(0) { $0 + $1.sampleCount }
            return SegmentRow(index: seg.index, runID: seg.runID, session: seg.sessionID ?? "—", samples: samples,
                              duration: rate > 0 ? "\(Fmt.fixed(Double(samples) / rate, 1)) s" : "—",
                              gaps: seg.detectedGaps.count, endReason: seg.endReason?.rawValue ?? "—")
        }
        self.events = events.map { e in
            EventRow(id: e.eventID, label: e.label,
                     onsetSeconds: e.sampleAssociation.flatMap { rate > 0 ? Double($0.sampleIndex) / rate : nil },
                     runID: e.runID, trial: e.trialID ?? "—", segment: e.sampleAssociation?.segment ?? Int.max)
        }.sorted { ($0.segment, $0.onsetSortKey) < ($1.segment, $1.onsetSortKey) }
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
        return m.runID
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
    /// Index into `stages` of the stage under way; `stages.count` once all are done (saving).
    let currentIndex: Int

    func mark(for index: Int) -> Mark {
        index < currentIndex ? .done : index == currentIndex ? .current : .pending
    }

    /// The worker reports loading, one event per cross-validation fold, then one per final
    /// fit + holdout scoring; "fit" and "holdout" are therefore one stage here.
    static let stages = ["Loading", "Cross-validation", "Fit and holdout"]

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
            stage = "Saving"; detail = "Storing the result in the project"; position = nil
        }
        currentIndex = position.map { $0 - 1 } ?? (p == .storing ? Self.stages.count : 0)
        let name = stage
        accessibilityValue = position.map { "\(name), \($0) of \(Self.stages.count)" } ?? name
    }
}
