import SwiftUI

/// Brief 004 PR 6: the live acquisition screen under Recordings (decision #30). Header with
/// the state in words and Record / Stop, the state banner, the 16-lane preview of the last
/// 10 s, and the stream-health panel (updated once a second). Copy: LiveModels / AcquisitionModels.
struct AcquisitionView: View {
    let session: ProjectSession
    @Bindable var live: ConnectController
    @State private var confirmDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                header
                notices
                if let runs = session.runs {
                    OperatorPanel(session: session, runs: runs, streaming: live.state == .streaming)
                }
                PreviewCard(live: live)
                HealthCard(live: live)
            }
            .padding(Theme.Space.pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdge(.top)
        .sheet(item: Binding(get: { session.startRunForm.map(FormBox.init) }, set: { session.startRunForm = $0?.form })) { box in
            StartRunSheet(session: session, form: box.form)
        }
    }

    /// `sheet(item:)` needs an identity; one form is open at a time.
    private struct FormBox: Identifiable {
        let form: StartRunForm
        var id: Int { 0 }
    }

    /// A session of protocol runs owns the recording: Record and Stop step aside for its panel.
    private var runsOpen: Bool { session.runs.map { !$0.isFinished } ?? false }

    private var source: ConnectSource { live.source ?? .demo }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(LiveScreenModel.title(source)).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                let lines = AcquisitionStateModel.statusLines(live.state, source: source, recording: live.isRecording,
                                                              reconnects: live.snapshot.health.reconnects)
                Label {
                    Text("\(lines.state) · \(lines.source)").lineLimit(2)
                } icon: {
                    Image(systemName: AcquisitionStateModel.symbol(live.state, recording: live.isRecording))
                        .foregroundStyle(live.isRecording ? Theme.danger : Theme.accentInk)
                }
                .font(.callout).foregroundStyle(Theme.textSecondary)
                if live.isRecording, let started = live.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(LiveScreenModel.recordingLine(elapsedS: context.date.timeIntervalSince(started),
                                                           committedSamples: live.snapshot.health.writer?.committedSamples ?? 0,
                                                           rateHz: Double(live.snapshot.board?.samplingRate ?? 125)))
                            .font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    }
                } else {
                    Text(LiveScreenModel.mapLine(live.choice)).font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Space.m)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            Button(LiveScreenModel.channelMap) { session.showConnectSheet() }
                .help(LiveScreenModel.channelMapHelp)
                .disabled(live.isRecording)
            Button(AcquisitionAction.disconnect.rawValue) {
                if live.isRecordingNow { confirmDisconnect = true } else { Task { await session.endLive() } }
            }
            .help(LiveScreenModel.disconnectHelp)
            .disabled(live.state == .stopping)
            .confirmationDialog(LiveScreenModel.disconnectQuestion, isPresented: $confirmDisconnect) {
                Button(LiveScreenModel.disconnectConfirm, role: .destructive) { Task { await session.endLive() } }
                Button(LiveScreenModel.disconnectKeep, role: .cancel) {}
            } message: {
                Text(LiveScreenModel.disconnectInfo)
            }
            if !runsOpen, !live.isRecording {
                Button(StartRunCopy.button) {
                    Task { await session.showStartRun(operatorScreen: NSApp.keyWindow?.screen) }
                }
                .help(session.startRunDisabledReason ?? StartRunCopy.buttonHelp)
                .disabled(session.startRunDisabledReason != nil)
            }
            if runsOpen {
                EmptyView()
            } else if live.isRecording {
                Button { Task { await live.perform(.stopRecording) } } label: {
                    Label(AcquisitionAction.stopRecording.rawValue, systemImage: "stop.fill")
                }
                .appProminentButton()
                .tint(Theme.danger)
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .help(LiveScreenModel.stopHelp)
            } else {
                Button { Task { await live.perform(.record) } } label: {
                    Label(AcquisitionAction.record.rawValue, systemImage: "record.circle")
                }
                .appProminentButton()
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(live.recordDisabledReason != nil || live.isStartingRecording || live.isFinishingRecording)
                .help(live.recordDisabledReason ?? LiveScreenModel.recordHelp)
            }
        }
        .controlSize(.large)
        .fixedSize()
    }

    @ViewBuilder private var notices: some View {
        if let error = session.startRunError { StatusChip(kind: .danger, text: error) }
        if let banner = AcquisitionStateModel.banner(live.state) {
            let failed = live.state.isFailed
            HStack(alignment: .center, spacing: Theme.Space.m) {
                StatusChip(kind: failed ? .danger : .warning, text: banner)
                ForEach(live.screenActions.filter { $0 == .reconnectNow || $0 == .retry || $0 == .reconnect }, id: \.self) { action in
                    Button(action.rawValue) { Task { await live.perform(action) } }.buttonStyle(.bordered).fixedSize()
                }
            }
        }
        if source == .synthetic { StatusChip(kind: .warning, text: ConnectSource.syntheticWarning) }
        if let message = live.recordMessage {
            HStack(spacing: Theme.Space.m) {
                StatusChip(kind: message.danger ? .danger : .positive, text: message.text)
                if let id = live.lastRecordingID, !live.isRecording {
                    Button(LiveScreenModel.showRecording) { session.showRecording(id) }.buttonStyle(.bordered).fixedSize()
                }
            }
        }
        if !live.isRecording {
            let h = live.snapshot.health
            if let warning = RecordingEndModel.diskWarning(hoursLeft: h.hoursLeft, freeBytes: h.freeBytes) {
                StatusChip(kind: .warning, text: warning)
            }
            if live.state == .streaming, let reason = live.recordDisabledReason {
                StatusChip(kind: .info, text: reason)
            } else if let warning = RecordGate.warning(source: source, configuration: live.snapshot.configuration) {
                StatusChip(kind: .warning, text: warning)
            }
        }
    }
}

// MARK: Preview

private struct PreviewCard: View {
    @Bindable var live: ConnectController
    @State private var auto = AutoHeight()
    static let laneHeight: CGFloat = 21
    static let labelWidth: CGFloat = 52
    static let axisHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(LivePreviewModel.title).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if live.isRecording {
                    Label(LiveScreenModel.recordingBadge, systemImage: "record.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.danger)
                }
                Spacer()
                Picker(LivePreviewModel.scaleLabel, selection: $live.scale) {
                    Text(LivePreviewModel.pickerTitle(.auto)).tag(LivePreviewModel.Scale.auto)
                    Divider()
                    ForEach(LivePreviewModel.fixedHeights, id: \.self) { Text(LivePreviewModel.pickerTitle(.fixed($0))).tag(LivePreviewModel.Scale.fixed($0)) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            let lanes = max(1, live.preview?.rows.count ?? live.laneLabels.count)
            // At most 15 redraws a second, and none while no new frame has arrived: the
            // Canvas re-renders only when its captured frame count changes.
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: live.state != .streaming)) { _ in
                canvas(lanes: lanes, frame: live.preview?.framesIngested ?? -1, scale: live.scale)
            }
            .frame(height: Self.laneHeight * CGFloat(lanes) + Self.axisHeight)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.updatesFrequently)
            Text(LivePreviewModel.caption).font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    /// Built from counts and the last drawn height: no second copy of the window.
    private var accessibilityText: String {
        let b = live.preview
        let height: Double
        switch live.scale {
        case .fixed(let h): height = h
        case .auto: height = auto.lastHeight
        }
        return LivePreviewModel.accessibilityLabel(channels: b?.rows.count ?? 0, height: height,
                                                   filled: Double(b?.filledCount ?? 0) / Double(max(1, b?.rate ?? 1)))
    }

    /// `frame` is read inside the renderer: a Canvas whose captures don't change is not
    /// re-rendered, so an unchanged frame count costs nothing.
    private func canvas(lanes laneCount: Int, frame: Int, scale: LivePreviewModel.Scale) -> some View {
        let buffer = live.preview
        let labels = live.laneLabels
        let isAuto = scale == .auto
        let auto = auto
        return Canvas { ctx, size in
            _ = frame
            let plotX = Self.labelWidth, plotW = max(1, size.width - plotX - Theme.Space.s)
            let plotH = Self.laneHeight * CGFloat(laneCount)
            for i in 0..<laneCount where i % 2 == 1 {
                ctx.fill(Path(CGRect(x: 0, y: Self.laneHeight * CGFloat(i), width: size.width, height: Self.laneHeight)),
                         with: .color(Theme.surface2.opacity(0.55)))
            }
            for t in LivePreviewModel.ticks {
                let x = plotX + plotW * CGFloat(t + 10) / 10
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: plotH))
                ctx.stroke(grid, with: .color(Theme.hairline), lineWidth: 1)
                // The lane-height caption sits under the left edge instead of "-10 s".
                guard t > LivePreviewModel.ticks[0] else { continue }
                ctx.draw(Text(LivePreviewModel.tickLabel(t)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: x, y: plotH + 3), anchor: t == 0 ? .topTrailing : .top)
            }
            guard let buffer else {
                ctx.draw(Text(LivePreviewModel.waiting).font(.callout).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: plotX + plotW / 2, y: plotH / 2))
                return
            }
            let w = buffer.window()
            let height: Double
            switch scale {
            case .fixed(let h): height = h
            case .auto: height = auto.height(for: w)
            }
            let model = LivePreviewModel(window: w, labels: labels, columns: Int(plotW), height: height)
            let colW = plotW / CGFloat(max(1, Int(plotW)))
            for b in model.breakColumns.sorted() {
                let x = plotX + CGFloat(b) * colW
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: 0)); edge.addLine(to: CGPoint(x: x, y: plotH))
                ctx.stroke(edge, with: .color(Theme.warning), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ctx.draw(Text(LivePreviewModel.segmentTag).font(.caption).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: x + 4, y: 2), anchor: .topLeading)
            }
            let unit = Self.laneHeight / CGFloat(max(height, 1e-9))
            let limit = Float(height / 2)
            for (i, lane) in model.lanes.enumerated() {
                let mid = Self.laneHeight * (CGFloat(i) + 0.5)
                ctx.draw(Text(lane.label).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary),
                         at: CGPoint(x: Theme.Space.s, y: mid), anchor: .leading)
                func y(_ v: Float) -> CGFloat { mid - CGFloat(min(max(v, -limit), limit)) * unit }
                var path = Path()
                var open = false
                for (c, e) in lane.columns.enumerated() {
                    guard let e else { open = false; continue }
                    let x = plotX + (CGFloat(c) + 0.5) * colW
                    // Nothing is drawn across the start of a new segment.
                    if !open || model.breakColumns.contains(c) { path.move(to: CGPoint(x: x, y: y(e.lo))) } else { path.addLine(to: CGPoint(x: x, y: y(e.lo))) }
                    path.addLine(to: CGPoint(x: x, y: y(e.hi)))
                    open = true
                }
                ctx.stroke(path, with: .color(Theme.accentInk), lineWidth: 1)
            }
            ctx.draw(Text(LivePreviewModel.heightText(height, auto: isAuto)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary),
                     at: CGPoint(x: 0, y: plotH + 3), anchor: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// The auto lane height, re-measured every 2 s so the scale doesn't flicker frame to frame.
@MainActor
private final class AutoHeight {
    private var value: Double?
    private var measured = Date.distantPast
    var lastHeight: Double { value ?? 100 }

    func height(for w: PreviewBuffer.Window) -> Double {
        if value == nil || Date().timeIntervalSince(measured) >= 2, w.count > 0 {
            value = LivePreviewModel.autoHeight(w)
            measured = Date()
        }
        return value ?? 100
    }
}

// MARK: Health

private struct HealthCard: View {
    let live: ConnectController

    var body: some View {
        let h = live.snapshot.health
        let rows = HealthModel.rows(h, nowNanos: HostMonotonicClock.nowNanos())
        let half = (rows.count + 1) / 2
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(LiveScreenModel.healthHeader).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    grid(Array(rows.prefix(half)))
                    grid(Array(rows.dropFirst(half)))
                }
                grid(rows)
            }
            if h.gaps.values.contains(where: { $0.ambiguous > 0 }) {
                Text(HealthModel.ambiguousNote(step: live.snapshot.board?.sequenceStep ?? 1)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Label(HealthModel.footer, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(Theme.textSecondary)
                    Text(rows[i].1).monospacedDigit().foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 300, alignment: .leading)
    }
}
