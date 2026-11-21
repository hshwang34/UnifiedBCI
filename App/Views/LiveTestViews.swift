import SwiftUI

// Brief 006 PR 7: the Live Test operator view. Copy comes from LiveTestModels.swift.

/// The Live Test section's detail: the operator view of the live run, else the placeholder.
struct LiveTestDetail: View {
    let session: ProjectSession

    var body: some View {
        if let live = session.liveFeedback {
            LiveTestOperatorView(session: session, live: live)
        } else {
            ContentUnavailableView {
                Label(SidebarSection.liveTest.title, systemImage: SidebarSection.liveTest.symbol).foregroundStyle(Theme.textSecondary)
            } description: {
                Text(LaunchArguments.liveFeedbackPreview ? LiveTestCopy.previewPlaceholder : SidebarSection.liveTest.placeholder ?? "")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct LiveTestOperatorView: View {
    let session: ProjectSession
    let live: LiveFeedbackController

    var body: some View {
        let m = LiveFeedbackPanelModel(live.status, model: live.model, protocolRecord: live.protocolRecord, threshold: live.policy.threshold,
                                       directions: live.feed.directions, truth: live.truth, aborted: live.aborted)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(LiveTestCopy.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(LiveTestCopy.modelLine(live.model, live.protocolRecord)).font(.callout).foregroundStyle(Theme.textSecondary)
                }
                FeedbackStateCard(model: m)
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
}

/// The current state in words, the bar as the participant sees it, and the raw prediction.
private struct FeedbackStateCard: View {
    let model: LiveFeedbackPanelModel

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
    let bar: LiveFeedbackPanelModel.Bar?
    let side: String?
    let leftEnd: String
    let rightEnd: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2, h: CGFloat = 14
            let length = CGFloat(bar?.length ?? 0) * half
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textTertiary.opacity(0.18)).frame(height: h)
                Capsule()
                    .fill(Theme.accentInk.gradient)
                    .frame(width: max(bar == nil ? 0 : 4, length), height: h)
                    .offset(x: (bar?.direction ?? 1) < 0 ? half - max(4, length) : half)
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
