import Charts
import SwiftUI

/// The Recording screen's Quality tab (brief 002, decisions #21–#25): per segment, a channel
/// table of the rules that fired, the selected channel's spectrum, the rules legend and the
/// footer. No overall verdict anywhere. Every string comes from `QualityModel`.
struct QualityTabView: View {
    let session: ProjectSession
    /// Index into `QualityModel.sections`; owned by the page so the montage rings follow it.
    @Binding var segment: Int
    /// Shared with the montage head, by channel id.
    @Binding var selected: String?
    @State private var processed = false

    var body: some View {
        switch session.qualityState {
        case .notStarted: startPanel(QualityModel.notStartedText)
        case .cancelled: startPanel(QualityModel.cancelledText)
        case .running(let p): progressPanel(p)
        case .unavailable(let details):
            ErrorBanner(title: QualityModel.unavailableTitle, message: QualityModel.unavailableMessage, details: details, retry: { session.inspect() })
        case .failed(let details):
            ErrorBanner(title: QualityModel.failedTitle, message: QualityModel.failedMessage, details: details, retry: nil)
        case .ready(let model):
            if model.sections.indices.contains(segment) { content(model, model.sections[segment]) }
        }
    }

    private func startPanel(_ text: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(text).font(.callout).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
            Button(QualityModel.inspectButton) { session.inspect() }.appProminentButton()
        }
        .card()
    }

    private func progressPanel(_ p: InspectionRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(QualityModel.progressText(p)).font(.callout).foregroundStyle(Theme.textPrimary)
            HStack(spacing: Theme.Space.m) {
                ProgressView(value: p.fraction, total: 1)
                    .progressViewStyle(TrackProgressStyle())
                    .accessibilityLabel(QualityModel.progressLabel)
                    .accessibilityValue(QualityModel.progressText(p))
                Button("Cancel") { session.cancelInspection() }.buttonStyle(.bordered)
            }
        }
        .card()
    }

    // MARK: Report

    private func content(_ model: QualityModel, _ section: QualityModel.Section) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if model.sections.count > 1 {
                    Picker(QualityModel.segmentPicker, selection: $segment) {
                        ForEach(model.sections.indices, id: \.self) { Text(model.sections[$0].title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Text(section.title).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                }
                Text(section.summary).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            channelTable(section)
            if let spectrum = model.spectrum(section: segment, channel: selected) {
                spectrumCard(spectrum, nyquist: section.nyquistHz)
            }
            legend(model)
            Text(QualityModel.footer).font(.callout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A list rather than a `Table`: flag lines wrap (a macOS table row is one line high).
    /// Arrow keys move the selection, and with it the spectrum and the electrode.
    private func channelTable(_ section: QualityModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ChannelLine(label: Text(QualityModel.channelColumn), kind: Text(QualityModel.kindUnitColumn)) { Text(QualityModel.flagsColumn) }
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                // Lines up with the plain list's row inset.
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
                .accessibilityHidden(true)
            Divider()
            List(section.rows, selection: $selected) { r in
                ChannelLine(label: Text(r.label).font(Theme.Fonts.mono), kind: Text(r.kindUnit).foregroundStyle(Theme.textSecondary)) { FlagsCell(row: r) }
                    .padding(.vertical, Theme.Space.xxs)
                    // VoiceOver reads the row as one sentence: channel first, then flags.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(r.accessibilityLabel)
            }
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            .scrollContentBackground(.hidden)
        }
        .card(padding: 0)
        .frame(height: RecordingDetailView.tableHeight)
    }

    private func spectrumCard(_ spectrum: QualityModel.Spectrum, nyquist: Double) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            let title = Text("\(QualityModel.spectrumTitle) · \(spectrum.label)").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            let toggle = Picker(QualityModel.spectrumTitle, selection: $processed) {
                Text(QualityModel.rawTitle).tag(false)
                Text(QualityModel.processedTitle).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(minLength: Theme.Space.m); toggle }
                VStack(alignment: .leading, spacing: Theme.Space.s) { title; toggle }
            }
            if let note = spectrum.unavailableText(processed: processed) {
                StatusChip(kind: .info, text: note)
            } else {
                SpectrumChart(points: spectrum.series(processed: processed), nyquist: nyquist)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spectrum.accessibilitySummary)
                    .accessibilityValue(processed ? QualityModel.processedTitle : QualityModel.rawTitle)
            }
        }
        .card()
    }

    private func legend(_ model: QualityModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(QualityModel.legendTitle).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                ForEach(model.legend) { r in
                    GridRow {
                        Text(r.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(r.text).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Channel, kind · unit and flags columns, shared by the header and the rows.
private struct ChannelLine<Flags: View>: View {
    let label: Text
    let kind: Text
    @ViewBuilder let flags: Flags

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            label.frame(width: 64, alignment: .leading)
            kind.frame(width: 84, alignment: .leading)
            flags.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One channel's flags, one line each; else the status ("None of these rules fired"), then
/// any checks that could not run.
private struct FlagsCell: View {
    let row: QualityModel.ChannelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status = row.status { Text(status).foregroundStyle(Theme.textSecondary) }
            ForEach(row.flags, id: \.ruleID) { flag in
                Label { Text(flag.text) } icon: { Image(systemName: "flag.fill").foregroundStyle(Theme.warning) }
            }
            ForEach(row.notAssessed, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.textSecondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

/// Log power (dB) against frequency, 1 Hz to Nyquist. Each `run` is its own series, so a
/// missing bin is a gap, never a line drawn across it.
private struct SpectrumChart: View {
    let points: [QualityModel.Point]
    let nyquist: Double
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Chart {
            ForEach(points.indices, id: \.self) { i in
                let p = points[i]
                LineMark(x: .value(QualityModel.frequencyAxis, p.hz), y: .value(QualityModel.powerAxis, p.db), series: .value("Run", p.run))
                    .foregroundStyle(Theme.accentInk)
                    .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 2 : 1.5))
            }
        }
        .chartXScale(domain: 1...max(nyquist, 2))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel(QualityModel.frequencyAxis)
        .chartYAxisLabel(QualityModel.powerAxis)
        .frame(height: 220)
    }
}
