import SwiftUI

/// Recording detail (visual spec §2.3): title, the source warning as a solid chip, a
/// compact Source card, then the channel / segment / event table. Every value is the manifest's.
struct RecordingDetailView: View {
    let model: RecordingDetailModel
    let info: ExampleInfo?

    enum Tab: String, CaseIterable, Identifiable {
        case channels = "Channels", segments = "Segments", events = "Events"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .channels
    @State private var showInfo = false
    @State private var showCitations = false
    @State private var channelSort = [KeyPathComparator(\RecordingDetailModel.ChannelRow.id)]
    @State private var segmentSort = [KeyPathComparator(\RecordingDetailModel.SegmentRow.index)]
    @State private var eventSort: [KeyPathComparator<RecordingDetailModel.EventRow>] = []

    var body: some View {
        // Sized by the offered space and never wider or taller than it (an explicit minimum
        // here makes the split view lay the window out larger than it is). The header
        // scrolls on its own when the window is short, so the table keeps its 240 pt.
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ViewThatFits(in: .vertical) {
                    header
                    ScrollView { header }.softScrollEdge(.bottom)
                }
                .frame(maxHeight: max(160, geo.size.height - 2 * Theme.Space.pageMargin - 240 - 80), alignment: .top)
                tablePicker
                table
                    .scrollContentBackground(.hidden)
                    .card(padding: 0)
                    .frame(minHeight: 240, maxHeight: .infinity)
            }
            .padding(Theme.Space.pageMargin)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(model.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
            if let warning = model.warning {
                StatusChip(kind: .warning, text: warning)
            }
            sourceCard
        }
    }

    private var tablePicker: some View {
            Picker("Table", selection: $tab) {
                Text("Channels \(model.channels.count)").tag(Tab.channels)
                Text("Segments \(model.segments.count)").tag(Tab.segments)
                Text("Events \(model.events.count)").tag(Tab.events)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Source").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                Spacer()
                if info != nil {
                    Button { showInfo = true } label: { Label("About this dataset", systemImage: "info.circle") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                            if let info { ExampleInfoPanel(info: info) }
                        }
                }
            }
            let fields = model.sourceFields + [RecordingDetailModel.Field(label: "Montage", value: model.montage)]
            // Four columns (two label/value pairs per row) when they fit, otherwise two.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                    ForEach(Array(stride(from: 0, to: fields.count, by: 2)), id: \.self) { i in
                        GridRow {
                            fieldCells(fields[i], wrap: false)
                            if i + 1 < fields.count { fieldCells(fields[i + 1], wrap: false) } else { Color.clear.gridCellColumns(2) }
                        }
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                    ForEach(fields) { field in
                        GridRow { fieldCells(field, wrap: true) }
                    }
                }
            }
            if !model.citations.isEmpty {
                DisclosureGroup("Citations (\(model.citations.count))", isExpanded: $showCitations) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(model.citations) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let url = c.url { Link("doi:" + c.doi, destination: url).font(.caption) }
                            }
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                }
                .font(.callout)
            }
        }
        .card()
    }

    @ViewBuilder private func fieldCells(_ field: RecordingDetailModel.Field, wrap: Bool) -> some View {
        Text(field.label)
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            .gridColumnAlignment(.leading)
        DeclaredText(value: field.value)
            .font(.callout)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: !wrap, vertical: true)
            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder private var table: some View {
        switch tab {
        case .channels:
            Table(model.channels.sorted(using: channelSort), sortOrder: $channelSort) {
                TableColumn("ID", value: \.id) { Text($0.id).font(Theme.Fonts.mono) }.width(min: 48, ideal: 64)
                TableColumn("Label", value: \.labelSortKey) { DeclaredText(value: $0.label ?? RecordingDetailModel.undeclared, declared: $0.label != nil) }.width(min: 56, ideal: 90)
                TableColumn("Unit", value: \.unitSortKey) { DeclaredText(value: $0.unit ?? RecordingDetailModel.undeclared, declared: $0.unit != nil) }.width(min: 48, ideal: 70)
                TableColumn("Kind", value: \.kindSortKey) { DeclaredText(value: $0.kind ?? RecordingDetailModel.undeclared, declared: $0.kind != nil) }.width(min: 48, ideal: 70)
            }
            .alternatingRowBackgrounds()
        case .segments:
            Table(model.segments.sorted(using: segmentSort), sortOrder: $segmentSort) {
                TableColumn("Segment", value: \.index) { Text("\($0.index)").monospacedDigit() }
                TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }
                TableColumn("Session", value: \.session)
                TableColumn("Duration", value: \.duration) { Text($0.duration).monospacedDigit() }
                TableColumn("Samples", value: \.samples) { Text("\($0.samples)").monospacedDigit() }
                TableColumn("Gaps", value: \.gaps) { Text("\($0.gaps)").monospacedDigit() }
                TableColumn("End reason", value: \.endReason)
            }
            .alternatingRowBackgrounds()
        case .events:
            Table(eventSort.isEmpty ? model.events : model.events.sorted(using: eventSort), sortOrder: $eventSort) {
                TableColumn("Label", value: \.label) { Text($0.label).font(Theme.Fonts.mono) }
                TableColumn("Onset (s)", value: \.onsetSortKey) { Text($0.onsetText).monospacedDigit() }
                TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }
                TableColumn("Trial", value: \.trial) { Text($0.trial).font(Theme.Fonts.mono) }
            }
            .alternatingRowBackgrounds()
        }
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
            Text(value).italic().foregroundStyle(Theme.textSecondary)
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
