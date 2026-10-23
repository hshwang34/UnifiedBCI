import SwiftUI

/// What Evaluate does and what would make its number misleading, from the record.
struct EvaluateInspector: View {
    let session: ProjectSession
    @State private var showSplit = false

    var body: some View {
        if let handle = session.selectedRecording {
            let model = EvaluateInspectorModel(manifest: handle.manifest, events: session.eventsByRecording[handle.id] ?? [],
                                               latest: session.latestReport[handle.id], defaults: session.workerDefaults, recipes: session.recipes,
                                               modelName: session.modelName)
            Form {
                Section("Evaluate") {
                    LabeledContent("Recording", value: model.recordingTitle)
                    LabeledContent("Seed", value: "\(session.makeRequest(recordingID: handle.id).seed)")
                    Button {
                        session.evaluate()
                    } label: {
                        Label("Evaluate", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!session.canEvaluate)
                }
                Section("What this changes") {
                    ForEach(model.changes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
                Section("What would make this misleading") {
                    ForEach(model.misleading) { bullet in
                        Label {
                            Text(bullet.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: bullet.symbol).foregroundStyle(bullet.symbol.hasPrefix("exclamationmark") ? .orange : .secondary)
                        }
                    }
                }
                Section {
                    Button("How the split works") { showSplit = true }
                        .popover(isPresented: $showSplit, arrowEdge: .leading) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("How the split works").font(.headline)
                                ForEach(model.splitExplanation, id: \.self) { line in
                                    Text("• " + line).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding()
                            .frame(width: 340)
                        }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Recording Selected", systemImage: "waveform",
                                   description: Text("Select a recording to see what Evaluate would do."))
        }
    }
}
