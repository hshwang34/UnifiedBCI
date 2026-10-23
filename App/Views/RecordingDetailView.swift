import SwiftUI

/// Recording detail (visual spec §2.3): title, the source warning as a solid chip, the
/// Source card in full, then the channel / segment / event table at a fixed height. One
/// scroll for the whole page; nothing is hidden behind a nested scroll.
struct RecordingDetailView: View {
    let model: RecordingDetailModel
    let info: ExampleInfo?
    @Binding var tab: RecordingTab

    @State private var showInfo = false
    @State private var showCitations = false
    @State private var tableWidth: CGFloat = 0
    @State private var channelSort = [KeyPathComparator(\RecordingDetailModel.ChannelRow.id)]
    @State private var segmentSort = [KeyPathComparator(\RecordingDetailModel.SegmentRow.index)]
    @State private var eventSort: [KeyPathComparator<RecordingDetailModel.EventRow>] = []

    static let tableHeight: CGFloat = 360
    /// Below this table width the Segments and Events tables drop their low-value columns
    /// (named under the table) rather than scroll sideways.
    static let narrowTable: CGFloat = 580

    var body: some View {
        // The GeometryReader pins the page to the column's width: a ScrollView alone passes
        // its content's ideal width (the 4-column grid's) up to the split view, which then
        // lays the window out wider than it is.
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(model.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                if let warning = model.warning {
                    StatusChip(kind: .warning, text: warning)
                }
                sourceCard
                tablePicker
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    table
                        .scrollContentBackground(.hidden)
                        .card(padding: 0)
                        .frame(height: Self.tableHeight)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
                    if let hidden = hiddenColumnsNote {
                        Text(hidden).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(Theme.Space.pageMargin)
            .frame(width: geo.size.width, alignment: .leading)
        }
        }
        .frame(minWidth: 0, minHeight: 0)
    }

    private var narrow: Bool { tableWidth > 0 && tableWidth < Self.narrowTable }

    private var hiddenColumnsNote: String? {
        guard narrow else { return nil }
        switch tab {
        case .channels: return nil
        case .segments: return "Segment, Session and End reason appear in a wider window."
        case .events: return "Trial appears in a wider window."
        }
    }

    private var tablePicker: some View {
            Picker("Table", selection: $tab) {
                Text("Channels \(model.channels.count)").tag(RecordingTab.channels)
                Text("Segments \(model.segments.count)").tag(RecordingTab.segments)
                Text("Events \(model.events.count)").tag(RecordingTab.events)
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
                TableColumn("ID", value: \.id) { Text($0.id).font(Theme.Fonts.mono) }.width(min: 40, ideal: 56)
                TableColumn("Label", value: \.labelSortKey) { DeclaredText(value: $0.label ?? RecordingDetailModel.undeclared, declared: $0.label != nil) }.width(min: 40, ideal: 72)
                TableColumn("Unit", value: \.unitSortKey) { DeclaredText(value: $0.unit ?? RecordingDetailModel.undeclared, declared: $0.unit != nil) }.width(min: 32, ideal: 52)
                TableColumn("Kind", value: \.kindSortKey) { DeclaredText(value: $0.kind ?? RecordingDetailModel.undeclared, declared: $0.kind != nil) }.width(min: 32, ideal: 52)
            }
            .alternatingRowBackgrounds()
        case .segments:
            let rows = model.segments.sorted(using: segmentSort)
            if narrow {
                Table(rows, sortOrder: $segmentSort) {
                    TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }.width(min: 48, ideal: 76)
                    TableColumn("Duration", value: \.duration) { Text($0.duration).monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Samples", value: \.samples) { Text("\($0.samples)").monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Gaps", value: \.gaps) { Text("\($0.gaps)").monospacedDigit() }.width(min: 28, ideal: 40)
                }
                .alternatingRowBackgrounds()
            } else {
                Table(rows, sortOrder: $segmentSort) {
                    TableColumn("Segment", value: \.index) { Text("\($0.index)").monospacedDigit() }.width(min: 40, ideal: 56)
                    TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }.width(min: 48, ideal: 76)
                    TableColumn("Session", value: \.session).width(min: 40, ideal: 60)
                    TableColumn("Duration", value: \.duration) { Text($0.duration).monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Samples", value: \.samples) { Text("\($0.samples)").monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Gaps", value: \.gaps) { Text("\($0.gaps)").monospacedDigit() }.width(min: 28, ideal: 40)
                    TableColumn("End reason", value: \.endReason).width(min: 48, ideal: 70)
                }
                .alternatingRowBackgrounds()
            }
        case .events:
            let rows = eventSort.isEmpty ? model.events : model.events.sorted(using: eventSort)
            if narrow {
                Table(rows, sortOrder: $eventSort) {
                    TableColumn("Label", value: \.label) { Text($0.label).font(Theme.Fonts.mono) }.width(min: 64, ideal: 112)
                    TableColumn("Onset (s)", value: \.onsetSortKey) { Text($0.onsetText).monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }.width(min: 48, ideal: 64)
                }
                .alternatingRowBackgrounds()
            } else {
                Table(rows, sortOrder: $eventSort) {
                    TableColumn("Label", value: \.label) { Text($0.label).font(Theme.Fonts.mono) }.width(min: 64, ideal: 112)
                    TableColumn("Onset (s)", value: \.onsetSortKey) { Text($0.onsetText).monospacedDigit() }.width(min: 40, ideal: 60)
                    TableColumn("Run", value: \.runID) { Text($0.runID).font(Theme.Fonts.mono) }.width(min: 48, ideal: 64)
                    TableColumn("Trial", value: \.trial) { Text($0.trial).font(Theme.Fonts.mono) }.width(min: 64, ideal: 96)
                }
                .alternatingRowBackgrounds()
            }
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
