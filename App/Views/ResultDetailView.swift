import SwiftUI

/// One stored result (visual spec §2.6): a glass hero whose uncertainty is drawn as large as
/// its number (decision #8 wording), then solid cards with the evidence behind it.
struct ResultDetailView: View {
    let session: ProjectSession
    let stored: StoredResult

    var body: some View {
        switch Result(catching: { try ResultDetailModel(stored: stored, allResults: session.results, modelName: session.modelName) }) {
        case .failure(let error):
            ContentUnavailableView("Result unreadable", systemImage: "exclamationmark.triangle", description: Text("\(error)"))
        case .success(let m):
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                    ResultHero(model: m, session: session, stored: stored)
                    if let warning = m.warning {
                        StatusChip(kind: .warning, text: warning)
                    }
                    ReproductionChip(model: m, session: session)
                    ViewThatFits(in: .horizontal) {
                        Grid(horizontalSpacing: Theme.Space.cardGap, verticalSpacing: Theme.Space.cardGap) {
                            GridRow(alignment: .top) {
                                ConfusionCard(model: m)
                                BaselineCard(model: m)
                            }
                            GridRow(alignment: .top) {
                                ClassCountsCard(model: m)
                                HeldOutRunsCard(model: m)
                            }
                        }
                        .frame(minWidth: 760)
                        VStack(spacing: Theme.Space.cardGap) {
                            ConfusionCard(model: m)
                            BaselineCard(model: m)
                            ClassCountsCard(model: m)
                            HeldOutRunsCard(model: m)
                        }
                    }
                    SplitPolicyCard(model: m)
                    ExclusionsCard(model: m)
                }
                .padding(Theme.Space.pageMargin)
            }
        }
    }
}

// MARK: Hero

private struct ResultHero: View {
    let model: ResultDetailModel
    let session: ProjectSession
    let stored: StoredResult
    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 64

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            figures(m)
            HStack {
                Text("\(m.referenceName) · stored \(stored.meta.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { workspace.exportPanel(for: session) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Space.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: Theme.Radius.hero, style: .hero)
    }

    /// The numbers and their uncertainty; one VoiceOver element reading the whole statement.
    private func figures(_ m: ResultDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Balanced accuracy").font(Theme.Fonts.heroLabel).foregroundStyle(Theme.textSecondary)
                Text(m.headline.balancedAccuracyValue).font(Theme.Fonts.display(size: displaySize)).foregroundStyle(Theme.textPrimary)
            }
            // The BA bar carries only the run-level interval; with one held-out run it is dashed.
            RangeBar(value: m.balancedAccuracy, interval: m.balancedAccuracyInterval,
                     label: m.balancedAccuracyBarLabel ?? "Balanced accuracy, no run-level interval")
            Label {
                Text(m.headline.balancedAccuracyInterval).font(.callout).foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: m.balancedAccuracyInterval == nil ? "info.circle" : "chart.bar.xaxis")
                    .foregroundStyle(Theme.textSecondary)
            }
            Divider().padding(.vertical, Theme.Space.xs)
            Text(m.headline.accuracy).font(Theme.Fonts.accuracyLine).foregroundStyle(Theme.textPrimary)
            RangeBar(value: m.accuracyValue, interval: m.accuracyInterval,
                     reference: m.largerClass.map { .init(value: $0.rate, label: "larger-class rate") },
                     label: "Accuracy interval")
            if let larger = m.largerClass {
                Label {
                    Text(larger.sentence).font(.callout).foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: larger.symbol).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(m.trialsLine).font(.callout).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m.heroAccessibilityLabel)
    }
}

private struct ReproductionChip: View {
    let model: ResultDetailModel
    let session: ProjectSession

    var body: some View {
        if let r = model.reproduction {
            let time = r.originalCreatedAt.map(ProjectSession.time) ?? "earlier"
            switch r.kind {
            case .identical:
                Button {
                    session.selectedResultID = r.originalID
                } label: {
                    StatusChip(kind: .info, text: "Reproduction of \(time) - evaluation.json identical to the original", symbol: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .help("Show the original result")
                .accessibilityAddTraits(.isLink)
            case .differs:
                StatusChip(kind: .warning, text: "Differs from original (\(time)). Same recording, configuration and seed gave different evaluation.json bytes. This is a bug; please report it.")
            }
        }
    }
}

// MARK: Cards

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
    }
}

/// A class as shown everywhere in this screen: display name over the stored label (§3).
private struct ClassName: View {
    let raw: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(ClassDisplay.name(raw)).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            if ClassDisplay.name(raw) != raw {
                Text(raw).font(Theme.Fonts.monoCaption).foregroundStyle(Theme.textSecondary)
            }
        }
        .help(raw)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClassDisplay.spoken(raw))
    }
}

/// Rows = true class, columns = predicted. Correct cells: accent shading by row share and a
/// check; wrong cells: hatched surface and a cross, so errors never look like successes.
private struct ConfusionCard: View {
    let model: ResultDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardTitle(text: "Confusion matrix (held-out trials)")
            Grid(horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(0..<2, id: \.self) { j in
                        VStack(spacing: 2) {
                            Text("Predicted").font(.caption).foregroundStyle(Theme.textSecondary)
                            ClassName(raw: model.classNames[j], alignment: .center)
                        }
                        .gridColumnAlignment(.center)
                    }
                }
                ForEach(0..<2, id: \.self) { i in
                    GridRow {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("True").font(.caption).foregroundStyle(Theme.textSecondary)
                            ClassName(raw: model.classNames[i], alignment: .trailing)
                        }
                        .gridColumnAlignment(.trailing)
                        ForEach(model.cells.filter { $0.row == i }) { cell in
                            MatrixCell(cell: cell)
                        }
                    }
                }
            }
            Text(model.confusionSummary).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.confusionSummary)
    }
}

private struct MatrixCell: View {
    let cell: ResultDetailModel.Cell
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous)
        VStack(spacing: 0) {
            Text("\(cell.count)").font(Theme.Fonts.matrixNumber).foregroundStyle(Theme.textPrimary)
            Text("of \(cell.rowTotal)").font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
        .frame(width: 120, height: 84)
        .background {
            if cell.isCorrect {
                let a = scheme == .dark ? 0.10 + 0.35 * cell.rowShare : 0.08 + 0.22 * cell.rowShare
                shape.fill(Theme.accentFill.opacity(min(a, scheme == .dark ? 0.45 : 0.30)))
            } else {
                ZStack {
                    shape.fill(Theme.surface2)
                    if cell.count > 0 { Hatch().clipShape(shape) }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: cell.isCorrect ? "checkmark" : "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
                .padding(Theme.Space.s)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

/// 45° 1pt hatch in textTertiary at 25%.
private struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            ctx.stroke(path, with: .color(Theme.textTertiary.opacity(0.25)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct BaselineCard: View {
    let model: ResultDetailModel

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardTitle(text: "Baseline comparison")
            ValueBar(label: m.referenceName, value: m.referenceBalancedAccuracy, fill: Theme.accentInk)
            ValueBar(label: m.baselineName, value: m.baselineBalancedAccuracy, fill: Theme.textSecondary)
            Text(m.differenceLine).font(.callout).foregroundStyle(Theme.textPrimary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Label {
                Text(m.differenceInterval).font(.callout).foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: m.differenceUnavailable ? "info.circle" : "chart.bar.xaxis").foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.Space.s) {
                PairChip(label: "Both correct", count: m.paired.bothCorrect)
                PairChip(label: "Reference only", count: m.paired.referenceOnlyCorrect)
                PairChip(label: "Baseline only", count: m.paired.baselineOnlyCorrect)
                PairChip(label: "Neither", count: m.paired.neitherCorrect)
            }
            Text(m.cvLine).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// One balanced accuracy on 0…1, labelled with its value.
private struct ValueBar: View {
    let label: String
    let value: Double
    let fill: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(label).font(.callout).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Fmt.fixed(value)).font(Theme.Fonts.mono).foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(fill).frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), balanced accuracy \(Fmt.fixed(value))")
    }
}

private struct PairChip: View {
    let label: String
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface2, in: .rect(cornerRadius: Theme.Radius.chip))
        .accessibilityElement(children: .combine)
    }
}

private struct ClassCountsCard: View {
    let model: ResultDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardTitle(text: "Class counts")
            Table(model.classCounts) {
                TableColumn("Class") { ClassName(raw: $0.className) }
                TableColumn("Training") { Text("\($0.train)").monospacedDigit() }.width(70)
                TableColumn("Held out") { Text("\($0.holdout)").monospacedDigit() }.width(70)
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 40 + CGFloat(model.classCounts.count) * 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct HeldOutRunsCard: View {
    let model: ResultDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardTitle(text: "Held-out runs")
            Table(model.perRun) {
                TableColumn("Run") { Text($0.runID).font(Theme.Fonts.mono) }
                TableColumn("Trials") { Text("\($0.trials)").monospacedDigit() }.width(50)
                TableColumn("Reference BA") { Text($0.reference).monospacedDigit() }.width(100)
                TableColumn("Baseline BA") { Text($0.baseline).monospacedDigit() }.width(90)
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 40 + CGFloat(max(model.perRun.count, 1)) * 32)
            Text("Reference: \(model.referenceName)").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct SplitPolicyCard: View {
    let model: ResultDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardTitle(text: "Split policy")
            ForEach(model.splitFields) { f in
                LabeledContent {
                    Text(f.value)
                        .font(f.mono ? Theme.Fonts.mono : .callout)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                } label: {
                    Text(f.label).font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
            Label {
                Text(model.evidence.text).font(.callout).foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: model.evidence.symbol).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct ExclusionsCard: View {
    let model: ResultDetailModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if model.exclusions.isEmpty {
                    Text("None.").foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(model.exclusions, id: \.self) { Text($0).font(.callout).foregroundStyle(Theme.textPrimary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.s)
        } label: {
            CardTitle(text: "Exclusions (\(model.exclusions.count))")
        }
        .card()
    }
}
