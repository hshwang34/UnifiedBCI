import SwiftUI

/// One stored result: headline per decision #8, then the evidence behind it.
struct ResultDetailView: View {
    let session: ProjectSession
    let stored: StoredResult
    @Environment(Workspace.self) private var workspace
    @State private var showExclusions = false

    var body: some View {
        switch Result(catching: { try ResultDetailModel(stored: stored, allResults: session.results, modelName: session.modelName) }) {
        case .failure(let error):
            ContentUnavailableView("Result unreadable", systemImage: "exclamationmark.triangle", description: Text("\(error)"))
        case .success(let m):
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.headline.balancedAccuracy).font(.largeTitle.monospacedDigit().weight(.semibold))
                        Text(m.headline.accuracy).font(.title2.monospacedDigit())
                        Text(m.headline.balancedAccuracyInterval).foregroundStyle(.secondary)
                        Text(m.trialsLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    if let warning = m.warning {
                        Label {
                            Text(warning).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    reproductionBadge(m)
                    HStack {
                        Text("\(m.referenceName) · stored \(stored.meta.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { workspace.exportPanel(for: session) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    }
                }

                Section("Confusion matrix (held-out trials)") {
                    ConfusionGrid(model: m)
                }

                Section("Class counts") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            Text("Class").fontWeight(.medium)
                            Text("Training").fontWeight(.medium).gridColumnAlignment(.trailing)
                            Text("Held out").fontWeight(.medium).gridColumnAlignment(.trailing)
                        }
                        Divider()
                        ForEach(m.classCounts) { row in
                            GridRow {
                                Text(row.className)
                                Text("\(row.train)").monospacedDigit()
                                Text("\(row.holdout)").monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("Held-out runs") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            Text("Run").fontWeight(.medium)
                            Text("Trials").fontWeight(.medium).gridColumnAlignment(.trailing)
                            Text("\(m.referenceName) BA").fontWeight(.medium).gridColumnAlignment(.trailing)
                            Text("Baseline BA").fontWeight(.medium).gridColumnAlignment(.trailing)
                        }
                        Divider()
                        ForEach(m.perRun) { row in
                            GridRow {
                                Text(row.runID)
                                Text("\(row.trials)").monospacedDigit()
                                Text(row.reference).monospacedDigit()
                                Text(row.baseline).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("Baseline comparison") {
                    Text(m.baselineLine).monospacedDigit()
                    Text(m.differenceLine).monospacedDigit()
                    Text(m.differenceInterval).foregroundStyle(.secondary)
                    Text(m.pairedLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text(m.cvLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }

                Section("Split policy") {
                    ForEach(m.splitFields) { f in
                        LabeledContent(f.label) { Text(f.value).multilineTextAlignment(.trailing).textSelection(.enabled) }
                    }
                    Label {
                        Text(m.evidence.text)
                    } icon: {
                        Image(systemName: m.evidence.symbol).foregroundStyle(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("Exclusions (\(m.exclusions.count))", isExpanded: $showExclusions) {
                        if m.exclusions.isEmpty {
                            Text("None.").foregroundStyle(.secondary)
                        } else {
                            ForEach(m.exclusions, id: \.self) { Text($0).font(.callout) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private func reproductionBadge(_ m: ResultDetailModel) -> some View {
        if let r = m.reproduction {
            let time = r.originalCreatedAt.map(ProjectSession.time) ?? "earlier"
            switch r.kind {
            case .identical:
                Button {
                    session.selectedResultID = r.originalID
                } label: {
                    Label("Reproduction of \(time) — evaluation.json identical to the original", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.link)
                .help("Show the original result")
            case .differs:
                Label {
                    Text("Differs from original (\(time)). Same recording, configuration and seed gave different evaluation.json bytes. This is a bug; please report it.")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

/// 2×2 grid, rows = true class, columns = predicted. One accent shade by count; every cell
/// carries its number, so nothing depends on the shading.
private struct ConfusionGrid: View {
    let model: ResultDetailModel

    var body: some View {
        let maxCount = max(1, model.cells.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    ForEach(0..<2, id: \.self) { j in
                        Text("Predicted \(model.classNames[j])").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(0..<2, id: \.self) { i in
                    GridRow {
                        Text("True \(model.classNames[i])").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        ForEach(model.cells.filter { $0.row == i }) { cell in
                            Text("\(cell.count)")
                                .font(.title2.monospacedDigit())
                                .frame(minWidth: 110, minHeight: 48)
                                .background(Color.accentColor.opacity(0.08 + 0.5 * Double(cell.count) / Double(maxCount)), in: .rect(cornerRadius: 6))
                                .overlay(alignment: .topTrailing) {
                                    if cell.isCorrect {
                                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary).padding(4)
                                    }
                                }
                                .accessibilityLabel(cell.accessibilityLabel)
                        }
                    }
                }
            }
            Text(model.confusionSummary).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.confusionSummary)
    }
}
