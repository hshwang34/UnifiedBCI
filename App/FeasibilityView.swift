import SwiftUI

struct FeasibilityView: View {
    @Bindable var model: FeasibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phase 0 — feasibility checks").font(.title2.weight(.semibold))
                Text("Each row answers one packaging question from the PRD before any workspace UI is built.")
                    .foregroundStyle(.secondary)
            }

            Form {
                CheckRow(title: "Link BrainFlow natively", status: model.brainflowLink) {
                    model.checkBrainFlowLink()
                }
                CheckRow(title: "Drain a synthetic board for 3 s", status: model.syntheticStream) {
                    model.runSyntheticStream()
                }
                CheckRow(title: "Launch isolated Python worker", status: model.workerLaunch) {
                    model.launchWorker()
                }
                CheckRow(title: "Fit + evaluate CSP/rLDA over IPC", status: model.workerFit) {
                    model.runWorkerFit()
                }
                if !model.fitProgress.isEmpty, model.workerFit == .running {
                    Text(model.fitProgress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if !model.fitSummary.isEmpty {
                    Section("Evaluation record (synthetic data)") {
                        ForEach(model.fitSummary, id: \.self) { line in
                            Text(line).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Run all") {
                    model.checkBrainFlowLink()
                    model.runSyntheticStream()
                    model.launchWorker()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Text("BrainFlow \(model.brainflowVersion)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .onDisappear { model.shutdownWorker() }
    }
}

private struct CheckRow: View {
    let title: String
    let status: FeasibilityModel.Status
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                detail
            }
            Spacer()
            Button("Run", action: action).disabled(status == .running)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case .pending: Text("Not run").font(.caption).foregroundStyle(.secondary)
        case .running: Text("Running…").font(.caption).foregroundStyle(.secondary)
        case .passed(let s): Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .failed(let s): Text(s).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
