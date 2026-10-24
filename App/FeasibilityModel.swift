#if DEBUG
// Phase-0 feasibility checks: developer tooling, compiled into Debug builds only.
import Foundation
import Observation

/// Phase 0 feasibility checks, each answering one "will this ship?" question from the PRD:
/// native BrainFlow linking, a drained synthetic stream with sequence accounting, and a
/// bundled/dev Python worker reachable over the versioned IPC protocol.
@MainActor
@Observable
final class FeasibilityModel {
    enum Status: Equatable { case pending, running, passed(String), failed(String) }

    var brainflowLink: Status = .pending
    var syntheticStream: Status = .pending
    var workerLaunch: Status = .pending
    var workerFit: Status = .pending
    var fitProgress: String = ""
    var fitSummary: [String] = []

    private var board: BrainFlowBoard?
    private var worker: WorkerClient?
    private var streamTask: Task<Void, Never>?

    var brainflowVersion: String {
        (try? BrainFlowBoard.libraryVersion()) ?? "unavailable"
    }

    // MARK: BrainFlow

    func checkBrainFlowLink() {
        brainflowLink = .running
        do {
            let version = try BrainFlowBoard.libraryVersion()
            let daisy = try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)
            brainflowLink = .passed("libBoardController \(version); \(daisy.name): \(daisy.eegChannelRows.count) EEG rows @ \(daisy.samplingRate) Hz, timestamp row \(daisy.timestampRow)")
        } catch {
            brainflowLink = .failed("\(error)")
        }
    }

    func runSyntheticStream(seconds: Double = 3) {
        syntheticStream = .running
        streamTask?.cancel()
        streamTask = Task {
            do {
                let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
                self.board = board
                let desc = board.description
                try await board.startStream()
                let start = ContinuousClock.now
                var drained = 0
                var accounting = SequenceAccounting(board: desc)
                var findings: [SequenceAccounting.Finding] = []
                var overflows = 0
                var firstTS: Double? = nil, lastTS: Double? = nil
                while ContinuousClock.now - start < .seconds(seconds) {
                    try await Task.sleep(for: .milliseconds(50))
                    let chunk = try await board.readAll()
                    guard chunk.count > 0 else { continue }
                    drained += chunk.count
                    if chunk.overflowSuspected { overflows += 1 }
                    findings += accounting.ingest(counters: chunk.row(desc.packageNumRow), timestamps: chunk.row(desc.timestampRow))
                    let ts = chunk.row(desc.timestampRow)
                    if firstTS == nil { firstTS = ts.first }
                    lastTS = ts.last
                }
                try await board.release()
                self.board = nil
                let span = (lastTS ?? 0) - (firstTS ?? 0)
                let effective = span > 0 ? Double(drained) / span : 0
                syntheticStream = .passed(String(format: "%@ @ %d Hz nominal (step %d): drained %d samples over %.2f s of wall-clock timestamps (%.1f Hz effective), %d sequence/clock findings, %d overflow-suspected drains",
                                                 desc.name, desc.samplingRate, desc.sequenceStep, drained, span, effective, findings.count, overflows))
            } catch {
                try? await self.board?.release()
                self.board = nil
                syntheticStream = .failed("\(error)")
            }
        }
    }

    // MARK: Worker

    func launchWorker() {
        workerLaunch = .running
        Task {
            guard let launch = WorkerLaunch.locate() else {
                workerLaunch = .failed("no bundled worker and no development venv at BCIWorkerDevRoot; run scripts/bootstrap.sh")
                return
            }
            let client = WorkerClient(launch: launch)
            worker = client
            do {
                let hello = try await client.start()
                let versions = hello.versions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                workerLaunch = .passed("\(launch.origin) worker pid \(hello.pid), protocol v\(hello.protocol): \(versions)")
            } catch {
                workerLaunch = .failed("\(error)")
            }
        }
    }

    func runWorkerFit() {
        guard let worker else { workerFit = .failed("start the worker first"); return }
        workerFit = .running
        fitProgress = ""
        fitSummary = []
        Task {
            let progressTask = Task {
                for await ev in worker.events where ev.name == "progress" {
                    if let p = try? JSONSerialization.jsonObject(with: ev.data) as? [String: Any] {
                        fitProgress = "\(p["model"] ?? "") fold \(p["fold"] ?? "")/\(p["of"] ?? "")"
                    }
                }
            }
            defer { progressTask.cancel() }
            do {
                let data = try await worker.call("fit_evaluate_synthetic", params: ["seed": 0, "n_runs": 4, "trials_per_run": 20])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let models = obj["models"] as? [String: [String: Any]] ?? [:]
                var lines: [String] = []
                for (name, m) in models.sorted(by: { $0.key < $1.key }) {
                    let hold = m["holdout"] as? [String: Any] ?? [:]
                    let ba = hold["balanced_accuracy"] as? Double ?? .nan
                    let ci = hold["accuracy_ci95"] as? [Double] ?? [.nan, .nan]
                    let n = hold["n_test_trials"] as? Int ?? 0
                    let cv = m["cv_balanced_accuracy_mean"] as? Double ?? .nan
                    lines.append(String(format: "%@ — holdout balanced acc %.2f (n=%d trials, 95%% CI %.2f–%.2f), grouped CV %.2f", name, ba, n, ci[0], ci[1], cv))
                }
                let split = obj["split_policy"] as? [String: Any] ?? [:]
                lines.append("split: \(split["holdout"] ?? ""), \(split["cv"] ?? ""), evidence=\(split["evidence"] ?? "")")
                if let src = obj["data_source"] as? [String: Any], let w = src["warning"] as? String { lines.append("⚠︎ \(w)") }
                fitSummary = lines
                let elapsed = obj["elapsed_seconds"] as? Double ?? 0
                workerFit = .passed(String(format: "fit + evaluate round-trip in %.1f s", elapsed))
            } catch {
                workerFit = .failed("\(error)")
            }
        }
    }

    func shutdownWorker() {
        let w = worker
        worker = nil
        Task { await w?.shutdown() }
    }
}
#endif
