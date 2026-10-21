# Phase 0 — feasibility results

Date: 2026-10-20 · Machine: Apple Silicon (arm64), macOS 26.5.1, Xcode 26.2, Swift 6.2.3

The PRD's phase 0 exit decision: *confirm the deployment approach before substantial UI
work.* This page records what was proven, with the command that reproduces each line, and
what is still open. Nothing here is a claim about BCI performance; all data is synthetic.

## Proven

| Question | Evidence | Reproduce |
|---|---|---|
| Swift 6 (strict concurrency) app links BrainFlow natively | Build succeeds with zero warnings; `libBoardController.dylib` 5.23.0 embedded in `Contents/Frameworks`, universal arm64/x86_64 | `xcodebuild … build` |
| Bridge and worker use the same BrainFlow build | `testLibraryVersionMatchesVendoredWheel`, `testStartAnnouncesProtocolAndPinnedDependencies` assert `5.23.0 == 5.23.0` | `xcodebuild … test` |
| BrainFlow describes Cyton+Daisy as the PRD states | 16 EEG rows, 125 Hz, package-number row 0, timestamp row 30 (`testCytonDaisyDescriptionMatchesDocumentedFacts`) | same |
| A board stream can be drained with sequence accounting | Synthetic board, 0.6 s: ≥ 62 samples read, receipt timestamps non-decreasing, package counter contiguous mod 256 (`testSyntheticBoardStreamsOrderedSamples`) | same |
| Isolated Python worker launches and speaks protocol v1 | `ready` event in ~1.1 s from a cold venv; `ping`, unknown-method error, `shutdown` → process exit observed (`WorkerClientTests`) | same |
| Leakage-safe CSP+rLDA fit/evaluate round-trips over IPC | `fit_evaluate_synthetic` returns grouped-by-run split policy, frozen holdout, per-trial CI, baseline model, synthetic-data warning; ~1.9–3.6 s for 60–80 trials × 16 ch × 3 s | same; `(cd worker && uv run pytest)` for the 9 worker-side tests incl. causal-filter chunk parity |
| Worker can be bundled without system Python | `scripts/bundle_worker.sh`: python-build-standalone 3.12.13 + `--target` site-packages, 358 MB; smoke test from inside `BCIWorkspace.app/Contents/Resources/worker/` answers `ready` + `pong` | `scripts/bundle_worker.sh && xcodebuild … build` |
| On-disk record types round-trip | `RecordingManifest`, `PredictionRecord` encode/decode equal (`ContractsTests`) | same |

Totals: 10/10 XCTest, 9/9 pytest.

## Measured but not yet acceptable

- **Bundle size.** 394 MB debug app, of which 358 MB is the worker (numpy/scipy/sklearn/mne
  with MNE's data and docs). Trimming MNE to the decoding subset, dropping scipy test
  suites, and stripping `.dylib` symbols should roughly halve it. Not blocking phase 1.

## Open gates (phase 0 is not closed until these are answered)

1. **Signing and notarization of the bundled worker.** Hundreds of `.so`/`.dylib` files
   under `Resources/worker/site` must be signed with the personal Developer ID (Team
   `V56DG94ZL5`), the hardened runtime re-enabled (`ENABLE_HARDENED_RUNTIME: YES`), and the
   result notarized. Known pitfalls: Mach-O files inside `Resources/` are rejected by
   notarization unless moved under `Frameworks/` or signed individually; python-build-
   standalone ships an unsigned interpreter.
2. **Clean-machine launch.** Install the signed build on a Mac without Xcode, Homebrew, or
   uv and run all four checks. Required by PRD section 5 P0 ("without hardware or terminal
   setup").
3. **Live Cyton+Daisy connection.** Only the synthetic board has been exercised. The dongle
   serial-port path, `config_board` readback, and real receipt-timestamp burstiness are
   phase 2 work but should be smoke-tested once before UI investment.
4. **Observation of target developers** (PRD gate "Problem evidence"). Not software; not
   started.

## Decisions taken

- [ADR 0001](adr/0001-native-app-with-bundled-worker.md): native SwiftUI app + out-of-process
  pinned Python worker; training and inference share one implementation.
- [ADR 0002](adr/0002-brainflow-native-boundary.md): BrainFlow via C module map behind a
  single-owner actor; constants hand-mirrored; DataHandler/MLModule not linked.
- Data contracts v1: [data-contracts.md](data-contracts.md).

## Recommended next step

Proceed to **phase 1 (replay to report)** in parallel with gate 1: the project store
(`.bciproj` directory, chunk writer with atomic commit, index rebuild), a bundled public
motor-imagery recording with an explicit channel map, signal inspection with named quality
rules, and the evaluation view driven by the worker's record. Treat gate 1 as a background
task that must close before any build is handed to a tester.
