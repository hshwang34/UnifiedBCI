import SwiftUI

// Brief 006 PR 7: the Live Test operator view. Copy comes from LiveTestModels.swift.

/// The Live Test section's detail: the operator view while a live run is on, else the
/// selected live run's card, else the setup.
struct LiveTestDetail: View {
    let session: ProjectSession

    var body: some View {
        if let live = session.liveFeedback, live.phase != .ended {
            LiveTestOperatorView(session: session, live: live)
        } else if let id = session.selectedLiveRunID, let run = session.frozen.liveRuns.first(where: { $0.liveRunID == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                    LiveRunCard(session: session, run: run, showsSource: true).guideAnchor(.liveRunCard)
                    Button(LiveRunCopy.setupTitle + "…") { session.selectedLiveRunID = nil }
                }
                .padding(Theme.Space.pageMargin)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .softScrollEdge(.top)
        } else {
            LiveTestSetupView(session: session)
        }
    }
}

/// The content column: a row for a new live run, then the live runs, newest first.
struct LiveRunsList: View {
    @Bindable var session: ProjectSession

    var body: some View {
        List(selection: Binding(get: { session.selectedLiveRunID ?? LiveRunsList.setupID },
                                set: { session.userSelectedLiveRun($0 == LiveRunsList.setupID ? nil : $0) })) {
            Label(LiveRunCopy.newRunRow, systemImage: "plus.circle").tag(LiveRunsList.setupID)
            if !session.frozen.liveRuns.isEmpty {
                Section(LiveRunCopy.runsListTitle) {
                    ForEach(session.frozen.liveRuns) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.dateTime(run.startedAt))
                            Text(session.frozen.models.first { $0.modelID == run.modelID }?.name ?? "Model unavailable")
                                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(run.liveRunID)
                    }
                }
            }
        }
    }

    static let setupID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// New live run: model, abstention threshold, protocol, seed and display, then Start.
struct LiveTestSetupView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(LiveRunCopy.setupTitle).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(LiveRunCopy.setupIntro).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Form {
                    Section {
                        Picker(LiveRunCopy.modelLabel, selection: $session.liveTestForm.modelID) {
                            ForEach(session.frozen.models) { Text($0.name).tag(Optional($0.modelID)) }
                        }
                        if let model = session.liveSetupModel {
                            Text(LiveRunCopy.modelSummary(model)).font(.callout).foregroundStyle(Theme.textSecondary)
                            if let mismatch = session.liveMismatch(model) {
                                Label(mismatch, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.textPrimary)
                            }
                        }
                        LabeledContent(LiveRunCopy.thresholdLabel) {
                            TextField(LiveRunCopy.thresholdLabel, text: $session.liveTestForm.thresholdText)
                                .labelsHidden().font(Theme.Fonts.mono).frame(maxWidth: 90).multilineTextAlignment(.trailing)
                                .onSubmit { Task { await session.startLiveFromSetup() } }
                        }
                        .help(LiveRunCopy.thresholdHelp)
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                            Text(LiveRunCopy.thresholdHelp).font(.caption).foregroundStyle(Theme.textSecondary)
                            HelpButton(topic: .modelConfidence)
                        }
                    }
                    if let form = session.liveRunForm {
                        Section {
                            Picker(StartRunCopy.protocolLabel, selection: Binding(get: { form.protocolID }, set: { if let id = $0 { session.liveRunForm?.pick(id) } })) {
                                ForEach(form.protocols) { Text(StartRunCopy.protocolTitle($0)).tag(Optional($0.protocolID)) }
                            }
                            if let p = form.selected {
                                Text(StartRunCopy.protocolSummary(p)).font(.callout).foregroundStyle(Theme.textSecondary)
                                if let model = session.liveSetupModel {
                                    Label(FreezeSheetModel.span(offset: model.window.offsetSeconds, length: model.window.lengthSeconds,
                                                                cue: Double(p.timing.cueMs) / 1000), systemImage: "timer")
                                        .font(.callout).foregroundStyle(Theme.textPrimary)
                                }
                            }
                            Stepper(value: Binding(get: { form.runsPerSession }, set: { session.liveRunForm?.runsPerSession = $0 }),
                                    in: 1...ProtocolRecord.maxRunsPerSession) {
                                Text("\(StartRunCopy.runsLabel): \(form.runsPerSession)").monospacedDigit()
                            }
                            LabeledContent(StartRunCopy.seedLabel) {
                                TextField(StartRunCopy.seedLabel, text: Binding(get: { form.seedText }, set: { session.liveRunForm?.seedText = $0 }))
                                    .labelsHidden().font(Theme.Fonts.mono)
                            }
                            .help(StartRunCopy.seedHelp)
                            Picker(StartRunCopy.displayLabel, selection: Binding(get: { form.displayID }, set: { session.liveRunForm?.displayID = $0 })) {
                                ForEach(form.displays) { Text(CueWindowModel.displayLabel($0)).tag(Optional($0.id)) }
                            }
                            if form.display?.isOperator == true {
                                Text(CueWindowModel.sharedDisplayNote).font(.callout).foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 420)
                if let error = session.startRunSheetError { StatusChip(kind: .danger, text: error) }
                HStack(spacing: Theme.Space.m) {
                    if session.isStartingLive { ProgressView().controlSize(.small) }
                    if let reason = session.liveStartDisabledReason { Text(reason).font(.callout).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    Button { Task { await session.startLiveFromSetup() } } label: { Label(LiveRunCopy.start, systemImage: "play.fill") }
                        .appProminentButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.liveStartDisabledReason != nil)
                        .help(session.liveStartDisabledReason ?? LiveRunCopy.start)
                        .guideAnchor(.liveStart)
                }
            }
            .padding(Theme.Space.pageMargin)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdge(.top)
        .task(id: session.live?.state) { await session.prepareLiveSetup(operatorScreen: session.projectWindow?.screen) }
    }
}

/// A live run as fresh-session evidence (brief 006): the trial-level figures, how they
/// compare with the model's held-out result, latency, and the live-vs-replay check.
struct LiveRunCard: View {
    let session: ProjectSession
    let run: LiveRunRecord
    /// Shows a link to the offline result it came from (off on that result's own page).
    var showsSource = false
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 52

    var body: some View {
        let model = session.frozen.models.first { $0.modelID == run.modelID }
        Group {
            if let card = session.frozen.liveCards[run.liveRunID] {
                content(card, model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: run) {
            let names = Dictionary((session.recordingProtocols[run.recordingID]?.classes ?? []).map { ($0.label, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            await session.frozen.loadInputs(run, force: true, classNames: names)
        }
    }

    @ViewBuilder private func content(_ m: LiveRunCardModel, model: ModelRecord?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.title).font(Theme.Fonts.heroLabel).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    StatusChip(kind: m.evidence == "cross-session" ? .info : .warning, text: EvidenceText.short(m.evidence))
                        .fixedSize()
                }
                Text(model.map { "\($0.name) · threshold \(Fmt.fixed(run.abstainThreshold))" } ?? "Model unavailable")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Balanced accuracy").font(Theme.Fonts.heroLabel).foregroundStyle(Theme.textSecondary)
                    Text(m.balancedAccuracyValue).font(Theme.Fonts.display(size: displaySize)).foregroundStyle(Theme.textPrimary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Text(m.accuracyLine).font(Theme.Fonts.accuracyLine).foregroundStyle(Theme.textPrimary)
                    HelpButton(topic: .liveRunInterval)
                }
                Label(LiveRunCopy.scoredLikeOffline, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                RangeBar(value: m.accuracy ?? 0, interval: m.interval,
                         reference: m.largerClass.map { .init(value: $0.rate, label: "larger-class rate") }, label: "Live accuracy interval")
                if let larger = m.largerClass { Label(larger.sentence, systemImage: larger.symbol).font(.callout).foregroundStyle(Theme.textPrimary) }
                Text(m.trialsLine).font(.callout).foregroundStyle(Theme.textSecondary).monospacedDigit()
                Label(m.comparison, systemImage: "arrow.left.arrow.right").font(.callout).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(m.evidenceSentence + " " + LiveRunCopy.scoringNote).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsSource, let model {
                    Button(LiveRunCopy.showSource) {
                        session.section = .results
                        session.selectedResultID = model.sourceResultID
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Theme.Space.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: Theme.Radius.hero, style: .hero)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(m.accessibilityLabel)
            StatusChip(kind: m.replayOK == true ? .positive : m.replayOK == false ? .danger : .info, text: m.replayLine)
                .fixedSize(horizontal: false, vertical: true)
            if let w = m.logWarning { StatusChip(kind: .warning, text: w).fixedSize(horizontal: false, vertical: true) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.cardGap) { matrix(m); latency(m) }
                VStack(spacing: Theme.Space.cardGap) { matrix(m); latency(m) }
            }
        }
    }

    private func matrix(_ m: LiveRunCardModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(LiveRunCopy.matrixTitle).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            Grid(horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(m.classNames.indices, id: \.self) { j in
                        Text("Predicted\n\(m.classNames[j])").font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
                    }
                }
                ForEach(0..<2, id: \.self) { i in
                    GridRow {
                        Text("True\n\(m.classNames[safe: i] ?? "")").font(.caption).multilineTextAlignment(.trailing).foregroundStyle(Theme.textSecondary)
                        ForEach(m.cells.filter { $0.row == i }) { MatrixCell(cell: $0) }
                    }
                }
            }
            ForEach(m.excluded, id: \.self) { Text($0).font(.callout).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func latency(_ m: LiveRunCardModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(LiveTestCopy.latencyHeader).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
                ForEach(m.latency) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(Theme.textSecondary)
                        Text(row.value).foregroundStyle(Theme.textPrimary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(LiveRunCopy.latencyTarget + " " + LiveRunCopy.latencyCaveat).font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct LiveTestOperatorView: View {
    let session: ProjectSession
    let live: LiveFeedbackController

    var body: some View {
        let m = panel()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(LiveTestCopy.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(LiveTestCopy.modelLine(live.model, live.protocolRecord)).font(.callout).foregroundStyle(Theme.textSecondary)
                }
                if live.phase != .running {
                    StatusChip(kind: .info, text: live.phase == .checking ? LiveRunCopy.checking : LiveRunCopy.stopping)
                }
                // Re-evaluated 20 times a second, so the stale rule hides the operator's bar
                // when the participant's is hidden, not at the next 4 Hz status refresh.
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in FeedbackStateCard(model: feedbackState()) }
                if let w = m.logWarning { StatusChip(kind: .warning, text: w) }
                HStack(alignment: .top, spacing: Theme.Space.cardGap) {
                    StatTile(title: LiveTestCopy.abstainHeader, value: m.abstainValue, line: m.abstainLine, symbol: "hand.raised")
                    StatTile(title: LiveTestCopy.latencyHeader, value: m.latencyValue, line: m.latencyLine, symbol: "stopwatch",
                             note: LiveTestCopy.latencyNote)
                }
                if let runs = session.runs {
                    OperatorPanel(session: session, runs: runs, streaming: session.live?.state == .streaming)
                }
                TrialOutcomesCard(model: m)
            }
            .padding(Theme.Space.pageMargin)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdge(.top)
    }

    /// Tiles and trial rows: rebuilt only when the 4 Hz status (or the trials) change.
    private func panel() -> LiveFeedbackPanelModel {
        LiveFeedbackPanelModel(live.status, model: live.model, protocolRecord: live.protocolRecord, threshold: live.policy.threshold,
                               truth: live.truth, aborted: live.aborted)
    }

    /// The stale-sensitive state and bar, rebuilt at 20 Hz without touching the trial rows.
    private func feedbackState() -> LiveFeedbackStateModel {
        let mirrored = live.feed.mirrored(now: HostMonotonicClock.nowNanos())
        return LiveFeedbackStateModel(live.status, mirror: mirrored?.display, mirrored: mirrored?.update, gap: runGap(), model: live.model,
                                      protocolRecord: live.protocolRecord, directions: live.feed.directions)
    }

    /// Between runs, or after the session's last one: no cue can come until a run starts.
    private func runGap() -> LiveFeedbackStateModel.RunGap? {
        guard let runs = session.runs, runs.runsStarted > 0, !runs.isRunActive else { return nil }
        return runs.isFinished || runs.runsStarted >= runs.setup.runsPerSession ? .sessionDone : .betweenRuns
    }
}

/// The current state in words, the bar as the participant sees it, and the raw prediction.
private struct FeedbackStateCard: View {
    let model: LiveFeedbackStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: symbol).foregroundStyle(tint).font(.title3).accessibilityHidden(true)
                Text(model.state).font(Theme.Fonts.heroLabel).foregroundStyle(Theme.textPrimary)
                if let d = model.detail { Text(d).font(Theme.Fonts.monoCaption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                Spacer(minLength: 0)
                Text(LiveTestCopy.feedbackHeader).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            FeedbackGauge(bar: model.bar, side: model.barSide, leftEnd: model.leftEnd, rightEnd: model.rightEnd)
                .frame(height: 56)
            Text(model.prediction).font(.callout.monospacedDigit()).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            Text(LiveTestCopy.confidenceNote).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.heroPadding)
        .glassSurface(cornerRadius: Theme.Radius.hero, style: .hero)
    }

    private var symbol: String {
        switch model.tone {
        case .positive: return "waveform.path.ecg"
        case .info: return "hourglass"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch model.tone {
        case .positive: return Theme.positive
        case .info: return Theme.accentInk
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        }
    }
}

/// The participant's bar, mirrored for the operator: a track, the centre line, and the bar
/// growing toward its class's side. Animated only when Reduce Motion is off.
struct FeedbackGauge: View {
    let bar: LiveFeedbackStateModel.Bar?
    let side: String?
    let leftEnd: String
    let rightEnd: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2, h: CGFloat = 14
            let length = CGFloat(bar?.length ?? 0) * half
            // The participant bar's minimum, at the same proportion.
            let minimum = half * CGFloat(CueWindowModel.feedbackMinimumFraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textTertiary.opacity(0.18)).frame(height: h)
                Capsule()
                    .fill(Theme.accentInk.gradient)
                    .frame(width: max(bar == nil ? 0 : minimum, length), height: h)
                    .offset(x: (bar?.direction ?? 1) < 0 ? half - max(minimum, length) : half)
                    .opacity(bar == nil ? 0 : 1)
                Rectangle().fill(Theme.textPrimary).frame(width: 2, height: 30).offset(x: half - 1)
            }
            .frame(maxHeight: .infinity)
            .animation(Theme.motion(reduceMotion: LaunchArguments.reduceMotion(system: systemReduceMotion)), value: bar)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(leftEnd).opacity((bar?.direction ?? 0) < 0 ? 1 : 0.6)
                Spacer()
                Text(rightEnd).opacity((bar?.direction ?? 0) > 0 ? 1 : 0.6)
            }
            .font(.caption2).foregroundStyle(Theme.textSecondary)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Participant feedback bar")
        .accessibilityValue(bar.map { "\(side ?? "") side, \(Int(($0.length * 100).rounded())) percent of full length" } ?? "Hidden")
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let line: String
    let symbol: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label(title, systemImage: symbol).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
            Text(value).font(Theme.Fonts.display(size: 30)).foregroundStyle(Theme.textPrimary)
            Text(line).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct TrialOutcomesCard: View {
    let model: LiveFeedbackPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(LiveTestCopy.trialsHeader).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
            Text(model.trialsSummary).font(.callout).foregroundStyle(Theme.textPrimary)
            if !model.trials.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
                    ForEach(model.trials.reversed()) { row in
                        GridRow {
                            Image(systemName: row.correct == true ? "checkmark.circle.fill" : row.correct == false ? "xmark.circle" : "circle.dashed")
                                .foregroundStyle(row.correct == true ? Theme.positive : Theme.textSecondary)
                                .accessibilityHidden(true)
                            Text(row.id).font(Theme.Fonts.monoCaption).foregroundStyle(Theme.textSecondary)
                            Text(row.cue).foregroundStyle(Theme.textPrimary)
                            Text(row.outcome).foregroundStyle(Theme.textPrimary)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
            Text(LiveTestCopy.trialsNote).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
