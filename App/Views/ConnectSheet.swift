import SwiftUI

/// Brief 004: pick a source, connect, see identity and requested-vs-readback, declare the
/// channel map. File ▸ New Recording… and the welcome screen's Connect hardware open it;
/// Start preview hands over to the acquisition screen under Recordings.
struct ConnectSheet: View {
    @Bindable var model: ConnectController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            if let banner = AcquisitionStateModel.banner(model.state), model.session != nil {
                StatusChip(kind: model.state.isFailed ? .danger : .warning, text: banner)
            }
            if model.source == .synthetic || (model.canPickSource && model.selected == .synthetic) {
                StatusChip(kind: .warning, text: ConnectSource.syntheticWarning)
            }
            if model.canPickSource {
                SourcePicker(model: model)
            } else if model.snapshot.board != nil {
                Picker(ConnectSheetModel.sectionPicker, selection: $model.tab) {
                    ForEach(ConnectSheetModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch model.tab {
                case .board: BoardPanel(model: model)
                case .channelMap: ChannelMapEditor(model: model)
                }
            } else {
                HStack(spacing: Theme.Space.m) {
                    ProgressView().controlSize(.small)
                    Text(ConnectSheetModel.connecting).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 720, height: 640)
        .background(Theme.canvas)
        .task { await model.watchPorts() }
        .task { await model.loadSavedMaps() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(ConnectSheetModel.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let source = model.source {
                Text(AcquisitionStateModel.statusLine(model.state, source: source, recording: model.isRecording,
                                                      reconnects: model.snapshot.health.reconnects))
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(ConnectSheetModel.close) {
                Task { await model.closeSheet(); dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            .help(ConnectSheetModel.closeHelp)
            Spacer()
            ForEach(model.actions, id: \.self) { action in
                let primary = action == model.actions.first && action != .disconnect && action != .cancel
                Button(action.rawValue) { Task { await model.perform(action) } }
                    .disabled(action == .connect && (model.isConnecting || !(model.selected.map(model.isAvailable) ?? false)))
                    .keyboardShortcut(primary ? .defaultAction : nil)
                    .guideAnchor(action == .connect ? .newRecording : .none)
            }
        }
        .controlSize(.large)
    }
}

// MARK: Source list

private struct SourcePicker: View {
    @Bindable var model: ConnectController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(ConnectSheetModel.pickSource).font(Theme.Fonts.sectionHeader)
                Spacer()
                Button { Task { await model.refresh() } } label: { Label(ConnectSheetModel.refresh, systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
            if let gone = model.gonePort { StatusChip(kind: .warning, text: ConnectSource.gone(gone)) }
            List(selection: $model.selectedID) {
                Section(ConnectSheetModel.serialHeader) {
                    if model.ports.isEmpty {
                        Text(ConnectSheetModel.noPorts).foregroundStyle(Theme.textSecondary).selectionDisabled()
                    }
                    ForEach(model.ports) { row(.serial($0), symbol: $0.isUSB ? "cable.connector" : "dot.radiowaves.left.and.right") }
                }
                Section(ConnectSheetModel.noHardwareHeader) {
                    row(.synthetic, symbol: "waveform.path")
                    row(.demo, symbol: "play.rectangle")
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func row(_ source: ConnectSource, symbol: String) -> some View {
        let available = model.isAvailable(source)
        return HStack(spacing: Theme.Space.m) {
            // Hierarchical styles, not tokens: the selected row inverts them to white.
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).foregroundStyle(available ? .primary : .tertiary)
                Text(available ? source.caption : ConnectSheetModel.demoMissing)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .tag(source.id)
        .selectionDisabled(!available)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ready: identity and configuration

private struct BoardPanel: View {
    let model: ConnectController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                if let board = model.snapshot.board, let source = model.source {
                    section(ConnectSheetModel.identityHeader) {
                        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
                            ForEach(Array(IdentityModel.rows(board: board, source: source, brainflowVersion: model.brainflowVersion,
                                                             firmware: nil).enumerated()),
                                    id: \.offset) { _, row in
                                GridRow {
                                    Text(row.0).foregroundStyle(Theme.textSecondary)
                                    Text(row.1).monospacedDigit().textSelection(.enabled)
                                }
                                .font(.callout)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                if let c = model.snapshot.configuration, let source = model.source {
                    if let alert = ConnectSheetModel.configurationAlert(c, source: source) {
                        StatusChip(kind: alert.danger ? .danger : .warning, text: alert.text)
                    }
                    section(ConnectSheetModel.configurationHeader) { ConfigurationTable(configuration: c) }
                }
            }
            // Room for the cards' shadow inside the clip.
            .padding(.horizontal, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .padding(.horizontal, -Theme.Space.xs)
        .softScrollEdge(.vertical)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.Fonts.sectionHeader).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct ConfigurationTable: View {
    let configuration: RecordingManifest.BoardConfiguration

    var body: some View {
        let (channel, requested, readback) = ConnectSheetModel.columns
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let note = ConfigurationModel.readbackNote(configuration) {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
                GridRow {
                    Text(channel); Text(requested); Text(readback)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Divider()
                ForEach(ConfigurationModel.rows(configuration), id: \.channel) { row in
                    GridRow {
                        Text(row.channel).foregroundStyle(Theme.textSecondary)
                        Text(row.requested)
                        HStack(spacing: Theme.Space.xs) {
                            if row.differs {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                    .accessibilityLabel(ConnectSheetModel.differs)
                            }
                            Text(row.readback)
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: Channel map editor

private struct ChannelMapEditor: View {
    @Bindable var model: ConnectController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Form {
                Picker(ChannelMapModel.savedMaps, selection: Binding(get: { UUID?.none }, set: { model.pick(savedMap: $0) })) {
                    Text(ChannelMapModel.noSavedMap).tag(UUID?.none)
                    ForEach(model.savedMaps) { Text(ChannelMapModel.pickerTitle($0)).tag(UUID?.some($0.mapID)) }
                }
                .disabled(model.savedMaps.isEmpty)
                TextField(ChannelMapModel.reference, text: $model.reference)
                TextField(ChannelMapModel.montage, text: $model.montage)
            }
            .formStyle(.columns)
            if let note = ChannelMapModel.unreadable(model.unreadableMaps) {
                Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                    ForEach(model.labels.indices, id: \.self) { i in
                        GridRow {
                            Text(ConnectSheetModel.channelName(i + 1)).font(.callout).foregroundStyle(Theme.textSecondary)
                            TextField(ChannelMapModel.labelField(i + 1), text: $model.labels[i])
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(ChannelMapModel.labelField(i + 1))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.Space.s)
            }
            .card(padding: Theme.Space.l)
            Text(model.mapMessage ?? ChannelMapModel.status(model.choice))
                .font(.callout).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack {
                Button(ChannelMapModel.withoutPositions) { model.recordWithoutPositions() }
                    .help(ChannelMapModel.withoutPositionsCaption)
                Spacer()
                Button(ChannelMapModel.save) { Task { await model.saveMap() } }
                Button(ChannelMapModel.confirm) { model.confirmMap() }.guideAnchor(.channelMap)
            }
        }
    }
}
