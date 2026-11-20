import SwiftUI

/// The Quality tab's signal view (brief 002): every channel stacked on one shared scale, a
/// 10 s window moved with Earlier / Later or the slider, Raw or Band-passed. Data arrives
/// decimated (≤ 1,000 min/max points per channel), so one Canvas pass draws it all.
struct SignalTraceCard: View {
    static let anchor = "trace"
    let session: ProjectSession
    /// The segment's worker index, and its position in `QualityModel.sections`.
    let segment: Int
    let section: Int
    @Binding var selected: String?

    var body: some View {
        let model = session.traceModel(segment: segment, section: section)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header(model)
            controls(model)
            if let problem {
                // The latest window failed: say so instead of leaving the last one on screen.
                problem
            } else if let model {
                TraceStack(model: model, selected: $selected)
                captions(model)
            } else {
                ProgressView(TraceModel.loading).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .card()
        .id(Self.anchor)
        .task(id: "\(session.selectedRecordingID?.uuidString ?? "")/\(segment)/\(session.traceStartS)") {
            session.loadTrace(segment: segment)
        }
    }

    private func header(_ model: TraceModel?) -> some View {
        let title = Text(model?.headerText ?? TraceModel.header(nil))
            .font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
        @Bindable var session = session
        let toggle = Picker(TraceModel.title, selection: $session.traceBandpassed) {
            Text(TraceModel.rawTitle).tag(false)
            Text(TraceModel.processedTitle).tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack { title; Spacer(minLength: Theme.Space.m); toggle }
            VStack(alignment: .leading, spacing: Theme.Space.s) { title; toggle }
        }
    }

    private func controls(_ model: TraceModel?) -> some View {
        let length = model?.segmentDurationS ?? session.traces.window?.segmentDurationS ?? 0
        let last = max(0, length - SignalWindowRunner.durationS)
        let start = session.traceStartS
        return HStack(spacing: Theme.Space.m) {
            Button { session.traceStartS = TraceModel.step(start, by: -1, segment: length) } label: {
                Label(TraceModel.earlier, systemImage: "chevron.left")
            }
            .disabled(start <= 0)
            Slider(value: Binding(get: { min(start, last) }, set: { session.traceStartS = TraceModel.clampStart($0.rounded(), segment: length) }),
                   in: 0...max(last, 1))
                .disabled(last <= 0)
                .accessibilityLabel(TraceModel.positionLabel)
                .accessibilityValue(model?.rangeText ?? "")
            Button { session.traceStartS = TraceModel.step(start, by: 1, segment: length) } label: {
                Label(TraceModel.later, systemImage: "chevron.right").labelStyle(TrailingIconLabel())
            }
            .disabled(start >= last)
        }
        .buttonStyle(.bordered)
    }

    /// The analysis-unavailable treatment used elsewhere: Retry when the worker has gone (the
    /// next call starts a fresh one); a refusal shows its details, and moving the window asks again.
    private var problem: ErrorBanner? {
        switch session.traces.state {
        case .unavailable(let r, let reason) where isShown(r):
            return ErrorBanner(title: TraceModel.unavailableTitle, message: TraceModel.unavailableMessage, details: reason,
                               retry: { [session, segment] in session.loadTrace(segment: segment) })
        case .failed(let r, let reason) where isShown(r):
            return ErrorBanner(title: TraceModel.unavailableTitle, message: TraceModel.unavailableMessage, details: reason, retry: nil)
        default: return nil
        }
    }

    private func isShown(_ r: SignalWindowRunner.Request) -> Bool {
        r.recordingID == session.selectedRecordingID && r.segment == segment
    }

    private func captions(_ model: TraceModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let note = model.scaleNote { Text(note) }
            HStack {
                Text(model.scaleText)
                Spacer()
                if session.traces.isBusy { Text(TraceModel.loading) }
            }
            if let note = model.warmupNote { Text(note) }
            if model.lanes.contains(where: \.isFlagged) {
                Label { Text(TraceModel.flaggedLegend) } icon: { Image(systemName: "flag.fill").foregroundStyle(Theme.warning) }
            }
        }
        .font(.caption).foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

/// Lane labels (flag symbol and rule titles on flagged lanes) beside one Canvas of traces.
/// Each lane is one VoiceOver element: channel, flags, then min/max in the window.
private struct TraceStack: View {
    let model: TraceModel
    @Binding var selected: String?
    @Environment(\.colorSchemeContrast) private var contrast
    static let laneHeight: CGFloat = 30
    static let labelWidth: CGFloat = 132
    static let axisHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.lanes) { lane in
                HStack(spacing: 0) {
                    label(lane)
                        .frame(width: Self.labelWidth, height: Self.laneHeight, alignment: .leading)
                        .background(lane.isFlagged ? Theme.warningFill : .clear)
                    Color.clear
                }
                .frame(height: Self.laneHeight)
                .background(selected == lane.id ? Theme.accentFill.opacity(0.3) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { selected = lane.id }
                .help(lane.accessibilityLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(lane.accessibilityLabel)
                .accessibilityAddTraits(selected == lane.id ? [.isSelected, .isButton] : .isButton)
                .accessibilityAction { selected = lane.id }
            }
            Color.clear.frame(height: Self.axisHeight).accessibilityHidden(true)
        }
        .overlay { canvas.allowsHitTesting(false).accessibilityHidden(true) }
        .clipped()
    }

    private func label(_ lane: TraceModel.Lane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if lane.isFlagged { Image(systemName: "flag.fill").foregroundStyle(Theme.warning).imageScale(.small) }
                Text(lane.label).font(Theme.Fonts.monoCaption.weight(lane.isFlagged ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
            }
            if lane.isFlagged {
                Text(lane.flags.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else if let note = lane.note {
                Text(note).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.leading, Theme.Space.xs)
    }

    private var canvas: some View {
        Canvas { ctx, size in
            // Right inset leaves room for the last tick's label.
            let x0 = Self.labelWidth + Theme.Space.s, width = max(1, size.width - x0 - Theme.Space.m)
            let span = max(model.endS - model.startS, 1e-9)
            func x(_ t: Double) -> CGFloat { x0 + CGFloat((t - model.startS) / span) * width }
            let plotHeight = Self.laneHeight * CGFloat(model.lanes.count)
            if let w = model.warmup {
                let rect = CGRect(x: x(w.lowerBound), y: 0, width: max(1, x(w.upperBound) - x(w.lowerBound)), height: plotHeight)
                ctx.fill(Path(rect), with: .color(Theme.textTertiary.opacity(0.16)))
                var edge = Path()
                edge.move(to: CGPoint(x: rect.maxX, y: 0)); edge.addLine(to: CGPoint(x: rect.maxX, y: plotHeight))
                ctx.stroke(edge, with: .color(Theme.textSecondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text(TraceModel.warmupTag).font(.caption2).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: rect.maxX + 3, y: 2), anchor: .topLeading)
            }
            for t in model.ticks {
                var grid = Path()
                grid.move(to: CGPoint(x: x(t), y: 0)); grid.addLine(to: CGPoint(x: x(t), y: plotHeight))
                ctx.stroke(grid, with: .color(Theme.hairline), lineWidth: 0.5)
                ctx.draw(Text(TraceModel.tickLabel(t)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: x(t), y: plotHeight + 2), anchor: .top)
            }
            for (i, lane) in model.lanes.enumerated() {
                // The lane's height is `lane.scale`: ± half of it around the centre, clipped
                // there, so a trace stays inside its own lane (same bound as `lane.clipped`).
                let unit = Self.laneHeight / CGFloat(lane.scale)
                let limit = lane.halfScale
                let mid = Self.laneHeight * (CGFloat(i) + 0.5)
                func y(_ v: Double) -> CGFloat { mid - CGFloat(min(max(v, -limit), limit)) * unit }
                var path = Path()
                var run = -1
                for p in lane.points {
                    let a = CGPoint(x: x(p.t), y: y(p.lo)), b = CGPoint(x: x(p.t), y: y(p.hi))
                    if p.run != run { path.move(to: a); run = p.run } else { path.addLine(to: a) }
                    path.addLine(to: b)
                }
                ctx.stroke(path, with: .color(Theme.accentInk), lineWidth: contrast == .increased ? 1.25 : 0.9)
            }
        }
    }
}
