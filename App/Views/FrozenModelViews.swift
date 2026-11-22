import SwiftUI

// Brief 006 PR 5: the Freeze for live use… sheet, frozen models under Pipelines, the
// Replay… sheet and the parity view. Every string comes from FrozenModelModels.swift.

/// Label/value rows shared by the Freeze sheet and the model detail.
private struct FactRows: View {
    let rows: [FreezeSheetModel.Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label).font(.callout).foregroundStyle(Theme.textSecondary).gridColumnAlignment(.trailing)
                    Text(row.value).font(.callout).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct FreezeSheet: View {
    let session: ProjectSession
    @Binding var draft: FrozenModelsController.FreezeDraft

    var body: some View {
        let m = draft.sheet
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.xs) {
                Text(m.title).font(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
                HelpButton(topic: .freeze)
            }
            Picker("Fit", selection: $draft.role) {
                Text("Model").tag(ModelRole.reference)
                Text("Baseline").tag(ModelRole.baseline)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            TextField("Name", text: $draft.name, prompt: Text(m.defaultName))
                .textFieldStyle(.roundedBorder)
            FactRows(rows: m.rows)
            StatusChip(kind: .info, text: m.evidence).fixedSize(horizontal: false, vertical: true)
            Label(m.feedbackSpan, systemImage: "timer").font(.callout).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let s = m.windowSuggestion { StatusChip(kind: .warning, text: s).fixedSize(horizontal: false, vertical: true) }
            Text(m.confidenceNote).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error = draft.error { StatusChip(kind: .danger, text: error).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if draft.isFreezing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { session.frozen.cancelFreeze() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.isFreezing)
                Button("Freeze") { Task { await session.freeze() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!m.canFreeze || draft.isFreezing)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        // Freezing can't be called off half-way: the sheet stays until it has finished.
        .interactiveDismissDisabled(draft.isFreezing)
    }
}

struct ReplaySheet: View {
    let session: ProjectSession
    @Binding var draft: FrozenModelsController.ReplayDraft

    var body: some View {
        let runner = session.frozen.runner
        let running = if case .running = runner.state { true } else { false }
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Replay through a frozen model").font(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
            Text(ReplayCopy.replayExplainer).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if session.frozen.models.isEmpty {
                StatusChip(kind: .info, text: ReplayCopy.noModelForReplay)
            }
            Form {
                Picker("Model", selection: $draft.modelID) {
                    ForEach(session.frozen.models) { Text($0.name).tag(Optional($0.modelID)) }
                }
                Picker("Recording", selection: $draft.recordingID) {
                    ForEach(session.recordings, id: \.id) { Text(RecordingDetailModel.title(for: $0.manifest)).tag(Optional($0.id)) }
                }
                TextField("Abstention threshold", text: $draft.thresholdText)
                    .help(ReplayCopy.thresholdHelp)
            }
            .disabled(running)
            if let error = draft.error {
                StatusChip(kind: .danger, text: error).fixedSize(horizontal: false, vertical: true)
            } else if draft.started, let words = ReplayCopy.state(runner.state) {
                if running { Label(words, systemImage: "hourglass").font(.callout) } else { StatusChip(kind: .warning, text: words) }
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if running {
                    Button("Stop Replay") { runner.cancel() }
                } else {
                    Button("Cancel", role: .cancel) { session.frozen.replayDraft = nil }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Replay") { Task { await session.replay() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(running || draft.modelID == nil || draft.recordingID == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }
}

/// The Pipelines list's first section.
struct FrozenModelRows: View {
    let session: ProjectSession

    var body: some View {
        Section(ReplayCopy.modelsSection) {
            if session.frozen.models.isEmpty {
                Text(session.frozen.loadError ?? ReplayCopy.noModels).font(.callout).foregroundStyle(Theme.textSecondary)
                    .selectionDisabled()
            }
            ForEach(session.frozen.rows(results: session.results)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).lineLimit(1)
                    Text(row.source).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Text(row.usage).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 2)
                .tag(row.id)
                .accessibilityElement(children: .combine)
                .contextMenu { Button(ReplayCopy.replayButton) { session.showReplay(model: row.id) }.disabled(session.isLiveRunning) }
            }
        }
    }
}

/// Pipelines detail for one frozen model: its facts, its replays and the selected parity view.
struct FrozenModelDetailView: View {
    let session: ProjectSession
    let model: ModelRecord

    var body: some View {
        let frozen = session.frozen
        let replays = frozen.replays(of: model.modelID)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.name).font(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button(ReplayCopy.replayButton) { session.showReplay(model: model.modelID) }
                            .disabled(session.isLiveRunning)
                            .help(session.isLiveRunning ? LiveRunCopy.pausedDuringLive : ReplayCopy.replayHelp)
                    }
                    Text(FreezeSheetModel.recipeName(model.recipe)).font(.callout).foregroundStyle(Theme.textSecondary)
                    FactRows(rows: FrozenModelRowModel.facts(model, channelLabels: FreezeSheetModel.labels(
                        session.recordings.first { $0.id == model.sourceRecordingID }?.manifest.channels ?? [])))
                    Button("Show the source result") {
                        session.section = .results
                        session.selectedResultID = model.sourceResultID
                    }
                    .buttonStyle(.link)
                    .disabled(!session.results.contains { $0.resultID == model.sourceResultID })
                }
                .card()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(ReplayCopy.replaysTitle).font(Theme.Fonts.sectionHeader).accessibilityAddTraits(.isHeader)
                    if replays.isEmpty {
                        Text(ReplayCopy.noReplays).font(.callout).foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Replay", selection: Binding(get: { frozen.selectedReplayID }, set: { frozen.selectedReplayID = $0 })) {
                            ForEach(replays) { r in
                                Text(ReplayCopy.replayRow(r, recording: recordingTitle(r.recordingID))).tag(Optional(r.liveRunID))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .card()
                if let r = frozen.selectedReplay, r.modelID == model.modelID,
                   let p = ParityViewModel(record: r, sampleRateHz: model.expectedSampleRateHz,
                                           predictions: frozen.parityPredictions?.id == r.liveRunID ? frozen.parityPredictions!.records : []) {
                    ParityView(model: p)
                }
            }
            .padding(Theme.Space.pageMargin)
        }
    }

    private func recordingTitle(_ id: UUID) -> String {
        session.recordings.first { $0.id == id }.map { RecordingDetailModel.title(for: $0.manifest) } ?? "a recording no longer in this project"
    }
}

/// "Streaming matches offline within tolerance", or where and by how much it doesn't.
struct ParityView: View {
    let model: ParityViewModel

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                StatusChip(kind: m.passed ? .positive : .warning, text: m.headline, symbol: m.symbol)
                HelpButton(topic: .replayParity)
            }
            Text("Largest difference per quantity").font(Theme.Fonts.sectionHeader).accessibilityAddTraits(.isHeader)
            ForEach(m.tolerances) { line in
                Label {
                    Text(line.text).font(.callout).monospacedDigit()
                } icon: {
                    Image(systemName: line.within.map { $0 ? "checkmark.circle" : "xmark.octagon" } ?? "minus.circle")
                        .foregroundStyle(line.within.map { $0 ? Theme.positive : Theme.danger } ?? Theme.textSecondary)
                }
                .accessibilityLabel(line.within.map { "\(line.text), \($0 ? "within" : "outside") tolerance" } ?? line.text)
            }
            Divider()
            ForEach([m.windows, m.cueLocked, m.boundary, m.abstentions, m.firstValid, m.chunkings], id: \.self) { text in
                Text(text).font(.callout).foregroundStyle(Theme.textPrimary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            if !m.mismatches.isEmpty {
                Text("Where they differ").font(Theme.Fonts.sectionHeader).accessibilityAddTraits(.isHeader)
                ForEach(m.mismatches, id: \.self) { Text($0).font(Theme.Fonts.monoCaption).foregroundStyle(Theme.textPrimary) }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
