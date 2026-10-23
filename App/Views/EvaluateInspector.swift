import SwiftUI

/// What Evaluate does and what would make its number misleading, from the record
/// (visual spec §2.4). System inspector surface; no glass inside.
struct EvaluateInspector: View {
    let session: ProjectSession
    @State private var showSplit = false

    var body: some View {
        if let handle = session.selectedRecording {
            let model = EvaluateInspectorModel(manifest: handle.manifest, events: session.eventsByRecording[handle.id] ?? [],
                                               latest: session.latestReport[handle.id], defaults: session.workerDefaults,
                                               recipes: session.recipes, modelName: session.modelName)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    section("Evaluate") {
                        VStack(spacing: Theme.Space.s) {
                            row("Recording", model.recordingTitle)
                            row("Seed", "\(session.makeRequest(recordingID: handle.id).seed)")
                        }
                        Button {
                            session.evaluate()
                        } label: {
                            Label("Evaluate", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(!session.canEvaluate)
                        .help("Evaluate (⌘R)")
                    }
                    section("What this changes") {
                        ForEach(model.changes, id: \.self) {
                            Text($0).font(.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("What would make this misleading") {
                        ForEach(model.misleading) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Image(systemName: bullet.symbol)
                                    .foregroundStyle(bullet.symbol.hasPrefix("exclamationmark") ? Theme.warning : Theme.textSecondary)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                Text(bullet.text).font(.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(Theme.Space.l)
            }
            .softScrollEdge(.bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Pinned, so it is never below the fold.
                Button("How the split works") { showSplit = true }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
                    .popover(isPresented: $showSplit, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("How the split works").font(Theme.Fonts.sectionHeader)
                            ForEach(model.splitExplanation, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                    Text("•").accessibilityHidden(true)
                                    Text(line).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.callout)
                        .padding(Theme.Space.cardPadding)
                        .frame(width: 360)
                    }
            }
        } else {
            ContentUnavailableView {
                Label("No Recording Selected", systemImage: "waveform").foregroundStyle(Theme.textSecondary)
            } description: {
                Text("Select a recording to see what Evaluate would do.").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.s)
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Fonts.inspectorHeader).foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}
