import SwiftUI

/// Brief 005 PR 6, redesigned in brief 010: Start run… (protocol version, session seed, runs
/// per session, display), with one trial drawn to scale and the session's length.
struct StartRunSheet: View {
    let session: ProjectSession
    @State var form: StartRunForm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let reason = form.disabledReason(streamReason: session.startRunDisabledReason)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: StartRunCopy.title, subtitle: StartRunCopy.subtitle, symbol: "figure.mind.and.body")
                .padding([.horizontal, .top], Theme.Space.xl)
            Form {
                Section(StartRunCopy.protocolSection) {
                    Picker(StartRunCopy.protocolLabel, selection: Binding(get: { form.protocolID }, set: { if let id = $0 { form.pick(id) } })) {
                        ForEach(form.protocols) { Text(StartRunCopy.protocolTitle($0)).tag(Optional($0.protocolID)) }
                    }
                    if let p = form.selected {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(StartRunCopy.trialAnatomy).font(.caption).foregroundStyle(Theme.textSecondary)
                            TrialAnatomyStrip(model: TrialAnatomyModel(p))
                            Text(StartRunCopy.protocolSummary(p)).font(.callout).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
                Section(StartRunCopy.sessionSection) {
                    LabeledContent(StartRunCopy.seedLabel) {
                        HStack {
                            TextField(StartRunCopy.seedLabel, text: $form.seedText).labelsHidden().font(Theme.Fonts.mono)
                            Button(StartRunCopy.newSeed, systemImage: "dice") { form.seedText = String(StartRunForm.newSeed()) }
                                .labelStyle(.iconOnly)
                                .help(StartRunCopy.newSeed)
                        }
                    }
                    .help(StartRunCopy.seedHelp)
                    Stepper(value: $form.runsPerSession, in: 1...ProtocolRecord.maxRunsPerSession) {
                        LabeledContent(StartRunCopy.runsLabel) {
                            Text("\(form.runsPerSession)").monospacedDigit().contentTransition(.numericText())
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(StartRunCopy.runsNote(form.runsPerSession))
                        if let p = form.selected { Text(StartRunCopy.sessionEstimate(p, runs: form.runsPerSession)).monospacedDigit() }
                    }
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                }
                Section(StartRunCopy.displaySection) {
                    Picker(StartRunCopy.displayLabel, selection: $form.displayID) {
                        ForEach(form.displays) { Text(CueWindowModel.displayLabel($0)).tag(Optional($0.id)) }
                    }
                    if form.display?.isOperator == true {
                        SharedDisplayNote()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let reason { StatusChip(kind: .info, text: reason) }
                if let error = session.startRunSheetError { StatusChip(kind: .danger, text: error) }
            }
            .padding(.horizontal, Theme.Space.xl)
            HStack {
                Spacer()
                Button(StartRunCopy.cancel, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button { session.startRuns(form) } label: { Label(StartRunCopy.start, systemImage: "play.fill") }
                    .appProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil)
            }
            .padding(Theme.Space.xl)
        }
        .frame(width: 580)
    }
}

/// A sheet's title row: a symbol in a soft accent disc, the title and one line under it.
struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ScaledMetric(relativeTo: .title2) private var disc: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.accentInk)
                .frame(width: disc, height: disc)
                .background(Theme.accentInk.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One display for both: the participant window covers this one, so the keys are the controls.
struct SharedDisplayNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "keyboard").foregroundStyle(Theme.accentInk).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(CueWindowModel.sharedDisplayNote).font(.callout).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    keyHint(OperatorPanelModel.spaceKey, OperatorPanelModel.begin)
                    keyHint(OperatorPanelModel.escapeKey, OperatorPanelModel.abortTrial)
                    keyHint(OperatorPanelModel.abortRunKey, OperatorPanelModel.abortRun)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func keyHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            KeyCap(key: key)
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// One trial to scale: fixation, cue and rest as capsules whose widths follow their durations.
/// With `current`, that phase is filled (the operator panel's phase strip); the fill moves
/// between phases with the app's motion (none under Reduce Motion). Only the operator sees it.
struct TrialAnatomyStrip: View {
    let model: TrialAnatomyModel
    var current: OperatorPanelModel.Step? = nil
    var cue: (name: String, symbol: CueSymbol)? = nil
    @Namespace private var namespace
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { g in
            let spacing = Theme.Space.xs
            let minimum: CGFloat = min(110, (g.size.width - 2 * spacing) / 3)
            let free = max(0, g.size.width - 2 * spacing - 3 * minimum)
            HStack(spacing: spacing) {
                ForEach(model.segments) { seg in
                    segment(seg).frame(width: minimum + free * seg.fraction)
                }
            }
        }
        .frame(height: height)
        .animation(Theme.motion(reduceMotion: LaunchArguments.reduceMotion(system: systemReduceMotion)), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(current.map { "Now: \($0.title)" + (cue.map { ", \($0.name)" } ?? "") } ?? "")
    }

    @ViewBuilder private func segment(_ seg: TrialAnatomyModel.Segment) -> some View {
        let on = seg.step == current
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: on && seg.step == .cue ? (cue?.symbol.symbol ?? seg.step.symbol) : seg.step.symbol)
                .font(.callout.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(on && seg.step == .cue ? (cue?.name ?? seg.title) : seg.title)
                .font(.callout.weight(on ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xxs)
            Text(seg.duration).font(.caption.monospacedDigit()).opacity(0.8).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.textSecondary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                shape.fill(Theme.surface2)
                if on {
                    shape.fill(Theme.accentFill.gradient).matchedGeometryEffect(id: "current", in: namespace)
                }
            }
        }
        .overlay(shape.strokeBorder(contrast == .increased ? Theme.textTertiary : Theme.hairline, lineWidth: 1).opacity(on ? 0 : 1))
    }
}

/// The operator panel on the acquisition screen while a session of runs is open (brief 010):
/// the state at a glance, where the session is, the phase on the participant's screen, and the
/// next action with its key.
struct OperatorPanel: View {
    let session: ProjectSession
    let runs: RunController
    let streaming: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let status = runs.status {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let m = OperatorPanelModel(status, protocol: runs.setup.protocolRecord, runsPerSession: runs.setup.runsPerSession,
                                               streaming: streaming, nowNanos: HostMonotonicClock.nowNanos())
                    content(m)
                }
            } else {
                header(nil)
            }
            if let problem = runs.resumeProblem { StatusChip(kind: .danger, text: problem) }
            if !runs.summaries.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    // The newest run's timing in full; earlier runs fold away.
                    ForEach(Array(runs.summaries.reversed().enumerated()), id: \.element.id) { i, s in
                        TimingSummaryView(runIndex: s.runIndex, model: s.timing, expandedAtFirst: i == 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .card()
        .animation(motion, value: runs.summaries.count)
    }

    private var motion: Animation? { Theme.motion(reduceMotion: LaunchArguments.reduceMotion(system: systemReduceMotion)) }

    private func header(_ m: OperatorPanelModel?) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(OperatorPanelModel.header).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(StartRunCopy.protocolTitle(runs.setup.protocolRecord)).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let m { RunBadge(badge: m.badge) }
        }
    }

    @ViewBuilder private func content(_ m: OperatorPanelModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header(m)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.progress).font(Theme.Fonts.accuracyLine).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Spacer(minLength: Theme.Space.m)
                    if let time = m.time {
                        Text(time).font(.callout.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
                SessionProgress(dots: m.runDots, fraction: m.trialFraction)
            }
            if m.step != nil {
                TrialAnatomyStrip(model: TrialAnatomyModel(runs.setup.protocolRecord), current: m.step, cue: m.cue)
            } else {
                Text(m.phase).font(.title3.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if let n = m.notice { StatusChip(kind: n.danger ? .danger : .info, text: n.text) }
            controls(m)
            Text(OperatorPanelModel.shortcuts(runs.status?.state ?? .instructions, moreRuns: runs.runsStarted < runs.setup.runsPerSession))
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(motion, value: m.step == nil)
        .animation(motion, value: m.progress)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(m.accessibilitySummary)
    }

    /// One row of buttons; in a narrow column they stack instead of clipping.
    @ViewBuilder private func controls(_ m: OperatorPanelModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { buttons(m) }.fixedSize()
            VStack(alignment: .leading, spacing: Theme.Space.s) { buttons(m) }.fixedSize()
        }
        .controlSize(.large)
    }

    @ViewBuilder private func buttons(_ m: OperatorPanelModel) -> some View {
        Group {
            if runs.isRunActive {
                if m.canBegin {
                    Button { runs.begin() } label: { ShortcutLabel(title: OperatorPanelModel.begin, symbol: "play.fill", key: OperatorPanelModel.spaceKey, prominent: true) }
                        .appProminentButton()
                        .help(OperatorPanelModel.beginHelp)
                        .accessibilityHint(OperatorPanelModel.beginHelp)
                }
                if m.canResume || !m.canPause && !m.canBegin {
                    Button { runs.resume() } label: { ShortcutLabel(title: OperatorPanelModel.resume, symbol: "play.fill", key: OperatorPanelModel.spaceKey, prominent: m.canResume) }
                        .appProminentButton()
                        .disabled(!m.canResume)
                        .accessibilityHint("Space")
                } else if m.canPause {
                    Button { runs.pause() } label: { ShortcutLabel(title: OperatorPanelModel.pause, symbol: "pause.fill", key: OperatorPanelModel.spaceKey) }
                        .accessibilityHint("Space")
                }
                Button { runs.abortTrial() } label: { ShortcutLabel(title: OperatorPanelModel.abortTrial, key: OperatorPanelModel.escapeKey) }
                    .disabled(!m.canAbortTrial)
                    .help(OperatorPanelModel.abortTrialHelp)
                    .accessibilityHint(OperatorPanelModel.abortTrialHelp)
                Button(role: .destructive) { runs.abortRun() } label: { ShortcutLabel(title: OperatorPanelModel.abortRun, key: OperatorPanelModel.abortRunKey) }
                    .disabled(!m.canAbortRun)
                    .help(OperatorPanelModel.abortRunHelp)
                    .accessibilityHint(OperatorPanelModel.abortRunHelp)
            } else if runs.isFinished {
                Button(RunSessionCopy.close) { session.dismissRuns() }
            } else {
                if runs.canStartNextRun {
                    Button { runs.startNextRun() } label: {
                        Label(RunSessionCopy.nextRun(runs.runsStarted + 1, of: runs.setup.runsPerSession), systemImage: "forward.fill")
                    }
                    .appProminentButton()
                    .disabled(!streaming)
                }
                if runs.canStartNextRun {
                    Button(RunSessionCopy.finish) { Task { await session.finishRuns() } }
                        .disabled(runs.isFinishing)
                        .help(RunSessionCopy.finishHelp)
                } else {
                    // The last run is done: finishing is the next action.
                    Button { Task { await session.finishRuns() } } label: { Label(RunSessionCopy.finish, systemImage: "checkmark") }
                        .appProminentButton()
                        .disabled(runs.isFinishing)
                        .help(RunSessionCopy.finishHelp)
                }
            }
        }
    }
}

/// The run's state as a tinted chip with a symbol (operator only, so its symbol may move).
private struct RunBadge: View {
    let badge: OperatorPanelModel.Badge
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let reduce = LaunchArguments.reduceMotion(system: systemReduceMotion)
        Label {
            Text(badge.text).contentTransition(.opacity)
        } icon: {
            Image(systemName: badge.symbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: badge.tone == .live && !reduce)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs + 1)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .fixedSize()
        .animation(Theme.motion(reduceMotion: reduce), value: badge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run state: \(badge.text)")
    }

    private var tint: Color {
        switch badge.tone {
        case .ready: return Theme.accentInk
        case .live: return Theme.positive
        case .paused: return Theme.warning
        case .done: return Theme.textSecondary
        case .problem: return Theme.danger
        }
    }
}

/// Runs of the session as dots (done, this one, to come) and this run's trials as a bar.
private struct SessionProgress: View {
    let dots: [ParticipantCardModel.Dot]
    let fraction: Double?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(dots.indices, id: \.self) { i in
                    Capsule()
                        .fill(dots[i] == .pending ? AnyShapeStyle(Theme.textTertiary.opacity(0.35)) : AnyShapeStyle(Theme.accentInk))
                        .frame(width: dots[i] == .current ? 18 : 7, height: 7)
                        .opacity(dots[i] == .done ? 0.55 : 1)
                }
            }
            .accessibilityHidden(true)
            ProgressView(value: fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Theme.accentInk)
                .opacity(fraction == nil ? 0.35 : 1)
                .accessibilityLabel("Trials in this run")
        }
    }
}

struct TimingSummaryView: View {
    let runIndex: Int
    let model: TimingSummaryModel
    var expandedAtFirst = true
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? expandedAtFirst }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                    ForEach(model.rows.indices, id: \.self) { i in
                        GridRow {
                            Text(model.rows[i].0).foregroundStyle(Theme.textSecondary)
                            Text(model.rows[i].1).monospacedDigit().foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                                .contentTransition(.numericText())
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
                Label(model.caveat, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(model.heading(runIndex: runIndex), systemImage: "timer").font(.headline).foregroundStyle(Theme.textPrimary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
    }
}
