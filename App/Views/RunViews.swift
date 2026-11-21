import SwiftUI

/// Brief 005 PR 6: Start run… (protocol version, session seed, runs per session, display).
struct StartRunSheet: View {
    let session: ProjectSession
    @State var form: StartRunForm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let reason = form.disabledReason(streamReason: session.startRunDisabledReason)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(StartRunCopy.title).font(Theme.Fonts.title).accessibilityAddTraits(.isHeader)
            Form {
                Picker(StartRunCopy.protocolLabel, selection: Binding(get: { form.protocolID }, set: { if let id = $0 { form.pick(id) } })) {
                    ForEach(form.protocols) { Text(StartRunCopy.protocolTitle($0)).tag(Optional($0.protocolID)) }
                }
                if let p = form.selected {
                    Text(StartRunCopy.protocolSummary(p)).font(.callout).foregroundStyle(Theme.textSecondary)
                }
                LabeledContent(StartRunCopy.seedLabel) {
                    HStack {
                        TextField(StartRunCopy.seedLabel, text: $form.seedText).labelsHidden().font(Theme.Fonts.mono)
                        Button(StartRunCopy.newSeed) { form.seedText = String(StartRunForm.newSeed()) }
                    }
                }
                .help(StartRunCopy.seedHelp)
                Stepper(value: $form.runsPerSession, in: 1...ProtocolRecord.maxRunsPerSession) {
                    Text("\(StartRunCopy.runsLabel): \(form.runsPerSession)").monospacedDigit()
                }
                Text(StartRunCopy.runsNote(form.runsPerSession)).font(.callout).foregroundStyle(Theme.textSecondary)
                Picker(StartRunCopy.displayLabel, selection: $form.displayID) {
                    ForEach(form.displays) { Text(CueWindowModel.displayLabel($0)).tag(Optional($0.id)) }
                }
                if form.display?.isOperator == true {
                    Text(CueWindowModel.sharedDisplayNote).font(.callout).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            if let reason { StatusChip(kind: .info, text: reason) }
            if let error = session.startRunSheetError { StatusChip(kind: .danger, text: error) }
            HStack {
                Spacer()
                Button(StartRunCopy.cancel, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(StartRunCopy.start) { session.startRuns(form) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
    }
}

/// The operator panel on the acquisition screen while a session of runs is open.
struct OperatorPanel: View {
    let session: ProjectSession
    let runs: RunController
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(OperatorPanelModel.header).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(StartRunCopy.protocolTitle(runs.setup.protocolRecord)).font(.callout).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            if let status = runs.status {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let m = OperatorPanelModel(status, protocol: runs.setup.protocolRecord, runsPerSession: runs.setup.runsPerSession,
                                               streaming: streaming, nowNanos: HostMonotonicClock.nowNanos())
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(m.progress).font(Theme.Fonts.accuracyLine).foregroundStyle(Theme.textPrimary)
                        Text(m.phase).font(.title3.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        if let time = m.time { Text(time).font(.callout.monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                        if let n = m.notice { StatusChip(kind: n.danger ? .danger : .info, text: n.text) }
                        controls(m)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            Text(OperatorPanelModel.shortcuts(runs.status?.state ?? .instructions)).font(.caption).foregroundStyle(Theme.textSecondary)
            if let problem = runs.resumeProblem { StatusChip(kind: .danger, text: problem) }
            ForEach(runs.summaries.reversed()) { TimingSummaryView(runIndex: $0.runIndex, model: $0.timing) }
        }
        .card()
    }

    @ViewBuilder private func controls(_ m: OperatorPanelModel) -> some View {
        HStack(spacing: Theme.Space.s) {
            if runs.isRunActive {
                if m.canBegin { Button(OperatorPanelModel.begin) { runs.begin() }.appProminentButton().help(OperatorPanelModel.beginHelp) }
                if m.canResume || !m.canPause && !m.canBegin {
                    Button(OperatorPanelModel.resume) { runs.resume() }.disabled(!m.canResume)
                } else if m.canPause {
                    Button(OperatorPanelModel.pause) { runs.pause() }
                }
                Button(OperatorPanelModel.abortTrial) { runs.abortTrial() }.disabled(!m.canAbortTrial).help(OperatorPanelModel.abortTrialHelp)
                Button(OperatorPanelModel.abortRun, role: .destructive) { runs.abortRun() }.disabled(!m.canAbortRun).help(OperatorPanelModel.abortRunHelp)
            } else if runs.isFinished {
                Button(RunSessionCopy.close) { session.dismissRuns() }
            } else {
                if runs.canStartNextRun {
                    Button(RunSessionCopy.nextRun(runs.runsStarted + 1, of: runs.setup.runsPerSession)) { runs.startNextRun() }
                        .appProminentButton()
                        .disabled(!streaming)
                }
                Button(RunSessionCopy.finish) { Task { await session.finishRuns() } }
                    .disabled(runs.isFinishing)
                    .help(RunSessionCopy.finishHelp)
            }
        }
        .controlSize(.large)
        .fixedSize()
    }
}

struct TimingSummaryView: View {
    let runIndex: Int
    let model: TimingSummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(model.heading(runIndex: runIndex)).font(.headline).foregroundStyle(Theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                ForEach(model.rows.indices, id: \.self) { i in
                    GridRow {
                        Text(model.rows[i].0).foregroundStyle(Theme.textSecondary)
                        Text(model.rows[i].1).monospacedDigit().foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            Label(model.caveat, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, Theme.Space.s)
    }
}
