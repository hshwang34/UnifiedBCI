import SwiftUI

/// Source panel over a channel / segment / event table. Every value is the manifest's.
struct RecordingDetailView: View {
    let model: RecordingDetailModel
    let info: ExampleInfo?

    enum Tab: String, CaseIterable, Identifiable {
        case channels = "Channels", segments = "Segments", events = "Events"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .channels
    @State private var showInfo = false
    @State private var channelSort = [KeyPathComparator(\RecordingDetailModel.ChannelRow.id)]
    @State private var segmentSort = [KeyPathComparator(\RecordingDetailModel.SegmentRow.index)]
    @State private var eventSort: [KeyPathComparator<RecordingDetailModel.EventRow>] = []

    var body: some View {
        // A plain stack sized by the offered space, with no minimum width of its own: VSplitView
        // (and any explicit minWidth here) made the split view lay the window out wider than
        // it is, collapsing the sidebar and pushing the inspector off-screen.
        GeometryReader { geo in
            VStack(spacing: 0) {
                sourceForm
                    .frame(height: max(160, geo.size.height * 0.45))
                Divider()
                Picker("Table", selection: $tab) {
                    Text("Channels (\(model.channels.count))").tag(Tab.channels)
                    Text("Segments (\(model.segments.count))").tag(Tab.segments)
                    Text("Events (\(model.events.count))").tag(Tab.events)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 8)
                table
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceForm: some View {
        Form {
            Section {
                if let warning = model.warning {
                    Label {
                        Text(warning).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.headline)
                }
                ForEach(model.sourceFields) { field in
                    LabeledContent(field.label) {
                        Text(field.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Montage") { DeclaredText(value: model.montage) }
                if !model.citations.isEmpty {
                    LabeledContent("Citations") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(model.citations) { c in
                                if let url = c.url {
                                    Link(Self.shortCitation(c.text), destination: url).help(c.text)
                                } else {
                                    Text(Self.shortCitation(c.text)).help(c.text)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Source")
                    Spacer()
                    if info != nil {
                        Button { showInfo = true } label: { Label("About this dataset", systemImage: "info.circle") }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                                if let info { ExampleInfoPanel(info: info) }
                            }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var table: some View {
        switch tab {
        case .channels:
            Table(model.channels.sorted(using: channelSort), sortOrder: $channelSort) {
                TableColumn("ID", value: \.id) { Text($0.id).monospaced() }
                TableColumn("Label", value: \.labelSortKey) { DeclaredText(value: $0.label ?? RecordingDetailModel.undeclared, declared: $0.label != nil) }
                TableColumn("Unit", value: \.unitSortKey) { DeclaredText(value: $0.unit ?? RecordingDetailModel.undeclared, declared: $0.unit != nil) }
                TableColumn("Kind", value: \.kindSortKey) { DeclaredText(value: $0.kind ?? RecordingDetailModel.undeclared, declared: $0.kind != nil) }
            }
        case .segments:
            Table(model.segments.sorted(using: segmentSort), sortOrder: $segmentSort) {
                TableColumn("Segment", value: \.index) { Text("\($0.index)").monospacedDigit() }
                TableColumn("Run", value: \.runID)
                TableColumn("Session", value: \.session)
                TableColumn("Duration", value: \.duration)
                TableColumn("Samples", value: \.samples) { Text("\($0.samples)").monospacedDigit() }
                TableColumn("Gaps", value: \.gaps) { Text("\($0.gaps)").monospacedDigit() }
                TableColumn("End reason", value: \.endReason)
            }
        case .events:
            Table(eventSort.isEmpty ? model.events : model.events.sorted(using: eventSort), sortOrder: $eventSort) {
                TableColumn("Label", value: \.label)
                TableColumn("Onset (s)", value: \.onsetSortKey) { Text($0.onsetText).monospacedDigit() }
                TableColumn("Run", value: \.runID)
                TableColumn("Trial", value: \.trial)
            }
            .alternatingRowBackgrounds()
        }
    }

    /// "Schalk, G., … (2004). …" → "Schalk 2004"; the full text is the link's help.
    static func shortCitation(_ text: String) -> String {
        let author = text.split(separator: ",").first.map(String.init) ?? text
        let year = text.range(of: #"\((\d{4})\)"#, options: .regularExpression).map { String(text[$0].dropFirst().dropLast()) }
        return year.map { "\(author) \($0)" } ?? author
    }
}

/// A stored value, or "undeclared" in secondary italics: never a guess.
struct DeclaredText: View {
    let value: String
    var declared: Bool

    init(value: String, declared: Bool? = nil) {
        self.value = value
        self.declared = declared ?? (value != RecordingDetailModel.undeclared)
    }

    var body: some View {
        if declared {
            Text(value).textSelection(.enabled)
        } else {
            Text(value).italic().foregroundStyle(.secondary)
        }
    }
}

/// Provenance and attribution of a bundled public recording, from its manifest.
struct ExampleInfoPanel: View {
    let info: ExampleInfo

    var body: some View {
        Form {
            Section("Dataset") {
                if let warning = info.warning {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Name", value: info.dataset)
                if let doi = info.doi, let url = URL(string: "https://doi.org/" + doi) {
                    LabeledContent("DOI") { Link(doi, destination: url) }
                }
                if let subject = info.subject { LabeledContent("Subject", value: subject) }
                LabeledContent("Runs", value: info.runs.joined(separator: ", "))
                if let license = info.license { LabeledContent("License", value: license) }
            }
            if !info.citations.isEmpty {
                Section("Please cite") {
                    ForEach(info.citations) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let url = c.url { Link("doi:" + c.doi, destination: url).font(.caption) }
                        }
                    }
                }
            }
            if !info.derivations.isEmpty {
                Section("Conversions applied on import") {
                    ForEach(info.derivations, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Section {
                Button("Copy Attribution") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.attributionText, forType: .string)
                }
            } footer: {
                Text("The same attribution is written to every export as ATTRIBUTION.md.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }
}
