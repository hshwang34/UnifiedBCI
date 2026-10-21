# Phase 0 — feasibility results

Date: 2026-10-20 · Machine: Apple Silicon (arm64), macOS 26.5.1, Xcode 26.2, Swift 6.2.3

The PRD's phase 0 exit decision: *confirm the deployment approach before substantial UI
work.* This page records what was proven, with the command that reproduces each line, and
what is still open. Nothing here is a claim about BCI performance; all data is synthetic.

## Proven

| Question | Evidence | Reproduce |
|---|---|---|
| Swift 6 (strict concurrency) app links BrainFlow natively | Build succeeds with zero warnings; `libBoardController.dylib` 5.23.0 embedded in `Contents/Frameworks` (wheel ships it universal; the app is built arm64-only) | `xcodebuild … build` |
| Bridge and worker use the same BrainFlow build | `testLibraryVersionMatchesVendoredWheel`, `testStartAnnouncesProtocolAndPinnedDependencies` assert `5.23.0 == 5.23.0` | `xcodebuild … test` |
| BrainFlow describes Cyton+Daisy as the PRD states | 16 EEG rows, 125 Hz, package-number row 0, timestamp row 30 (`testCytonDaisyDescriptionMatchesDocumentedFacts`) | same |
| A board stream can be drained with sequence accounting | Synthetic board, 0.6 s: ≥ 31 samples read, `SequenceAccounting` reports no findings at step 1, chunk carries a monotonic drain time (`testSyntheticBoardStreamsOrderedSamples`); the helper itself is unit-tested for wrap, Daisy step-2, stale-half, parity and clock-anomaly cases | same |
| Isolated Python worker launches and speaks protocol v1 | `ready` event in ~1 s from a cold venv (MNE no longer imported); `ping`, unknown-method error, `cancel` mid-fit, per-call timeout, ready timeout, protocol mismatch, kill mid-call, >1 MB result, stdout noise, `shutdown` → exit all observed (`WorkerClientTests`) | same |
| Leakage-safe CSP+rLDA fit/evaluate round-trips over IPC | `fit_evaluate_synthetic` returns grouped-by-run split policy, a frozen `split_manifest`, per-trial CI, per-run scores and run-level bootstrap, paired baseline comparison, synthetic-data warning; ~1 s for 24 trials × 8 ch | same; `(cd worker && uv run pytest)` for the worker-side tests incl. segment-vs-streaming filter parity and CSP parity against MNE |
| Worker can be bundled without system Python | `scripts/bundle_worker.sh`: python-build-standalone 3.12 + `--target` site-packages, arm64-only, size recorded under "Corrections" below; smoke test runs a fit from an isolated interpreter with a scrubbed environment | `scripts/bundle_worker.sh && xcodebuild … build` |
| On-disk record types round-trip | `ProjectManifest`, `RecordingManifest`, `EventRecord`, `PredictionRecord` encode/decode equal through `ContractJSON`, fractional-second dates preserved (`ContractsTests`) | same |

Totals at phase-0 close: 10/10 XCTest, 9/9 pytest. After the 2026-10-20 corrections
(brief 001, PR 1): 37 XCTest, 33 pytest — see below.

## Measured but not yet acceptable

- **Bundle size.** Originally 394 MB debug app, of which 358 MB was the worker. The
  heavy items were not MNE's data and docs but (a) BrainFlow's foreign-platform
  libraries (`.dll`/`.so`/x86 onnxruntime, 54 MB of 87 MB) and (b) MNE's transitive
  dependencies (matplotlib, PIL, fontTools, … ≈ 82 MB) — both now removed. Symbol
  stripping would have mattered little. Remaining size is recorded under "Corrections".

## Open gates (phase 0 is not closed until these are answered)

1. **Signing and notarization of the bundled worker.** Every Mach-O under
   `Resources/worker` (interpreter, `.so`, `.dylib`) must be signed individually with the
   personal Developer ID (Team `V56DG94ZL5`) using `--options runtime --timestamp` and no
   `--deep` (`scripts/bundle_worker.sh --sign <identity>` does exactly that), the hardened
   runtime re-enabled (`ENABLE_HARDENED_RUNTIME: YES`), and the result notarized. Mach-O
   files inside `Resources/` are fine where they are once signed; python-build-standalone
   ships an unsigned interpreter.
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

## Corrections after research (2026-10-20)

Findings from the packaging/BrainFlow/dataset research and an adversarial code review
before brief 001's first PR. Each wrong claim above has been edited in place; this list
is the audit trail.

1. **"Mach-O under `Resources` is rejected unless moved to `Frameworks`"** — false. Every
   Mach-O just needs a Developer ID signature with hardened runtime and a secure
   timestamp; location in the bundle does not matter to notarization.
2. **"Relocatable" interpreter** — overstated. `sysconfig` and `libpython` carry stale
   absolute build paths. Harmless for our `-m` launch, and libpython is deleted (the
   interpreter is statically linked, verified with `otool -L`), but not a general promise.
3. **"Universal"** — the worker is arm64-only (python-build-standalone per architecture)
   and the app now builds `ARCHS=arm64` (brief 001 decision #5). Only the vendored
   BrainFlow dylib happens to be universal.
4. **"Stripping halves the bundle"** — no. Deleting BrainFlow's foreign-platform libraries
   and the MNE/matplotlib dependency tree is what matters; `.dylib` symbol stripping is a
   rounding error.
5. **"Contiguous sequence counters"** — proven only on the synthetic board. Cyton+Daisy
   commits one sample per packet pair and writes the even counter, so valid deltas are
   +2 mod 256; delta 0 is a stale half-sample. `SequenceAccounting` encodes this and
   `BoardDescription.sequenceStep` exposes it.
6. **"Non-decreasing receipt timestamps"** — an observation on one synthetic run, not a
   guarantee. The BrainFlow timestamp row is `gettimeofday` wall clock, which NTP can step
   backwards; backward steps are logged as `clock_anomaly` and timestamps are never used
   to detect gaps. The app records its own `CLOCK_MONOTONIC_RAW` drain time per chunk.
7. **Worker protocol** — MNE/sklearn printed to stdout between JSON lines; the worker now
   keeps its protocol on a private duplicate of fd 1 and redirects fd 1 to stderr.
   Unparseable or wrong-version requests were answered with `id: null` (caller hung
   forever); the id is now recovered first. `ping`/`cancel`/`shutdown` are answered from
   a reader thread while a fit runs; a `getppid` watchdog exits when the app dies.
8. **Swift client** — output chunks were consumed in unordered tasks; the ready timeout
   leaked its continuation; `didExit` could discard a final response; `JSONSerialization`
   could raise an uncatchable NSException on NaN. All replaced (ordered `AsyncStream`
   consumer, real timeouts with process termination, EOF-and-exit gating, `Codable`
   envelopes with verbatim result bytes, SIGPIPE ignored, interpreter isolated with a
   scrubbed environment).
9. **Filter-state parity** — offline features were computed by zero-state filtering each
   pre-cut trial (start transient: variance 26.5 in the first 0.5 s vs 0.36 steady state),
   something the online path never does. Segments are now filtered continuously and
   epoched afterwards; trials inside the filter warm-up (0.55 s for the 8–30 Hz order-4
   Butterworth at 125 Hz, derived from its slowest pole) are excluded and listed.
10. **Synthetic data was rigged for the baseline** (axis-aligned per-channel power change).
    The generator now mixes latent sources through a random full-rank matrix with drift
    and pink noise; a shuffled-label negative control is part of the test suite.
11. **Holdout was not auditable** — the record now carries a `split_manifest` by id, can
    re-score a supplied manifest regardless of seed, and refuses one that does not match
    the data. Uncertainty adds per-run scores, a run-level bootstrap, and a paired
    reference-vs-baseline comparison.
12. **MNE dropped from the runtime set.** CSP is implemented in the worker (Ledoit-Wolf
    shrinkage, generalized eigendecomposition) and checked against `mne.decoding.CSP` in
    the dev test suite. Worker cold start no longer pays MNE's import.
13. **Bundle after trimming:** `scripts/bundle_worker.sh` now yields **149 MB** (was
    358 MB): interpreter 29 MB (libpython, Tcl/Tk, IDLE, ensurepip, pip removed), site
    120 MB (scipy 52, BrainFlow 25 after `lipo -thin arm64` of its 10 universal dylibs,
    sklearn 23, numpy 12). BrainFlow's remaining 25 MB is its darwin dylibs
    (DataHandler, MLModule, onnxruntime arm64, vendor SDKs); the
    worker only needs `libBoardController` for version parity, so a further ~20 MB is
    available if the package is trimmed to that one library — deliberately not done in
    PR 1 because `brainflow.__init__` imports modules that load the others lazily and
    that needs its own smoke test. The script's smoke test runs a real fit from an
    isolated interpreter (`-s -P -u -B -X utf8`, `env -i`) and caught that
    `numpy.testing` is a runtime import (scipy's array-API shim), so only `tests/`
    directories are deleted.

## Recommended next step

Proceed to **phase 1 (replay to report)** in parallel with gate 1: the project store
(`.bciproj` directory, chunk writer with atomic commit, index rebuild), a bundled public
motor-imagery recording with an explicit channel map, signal inspection with named quality
rules, and the evaluation view driven by the worker's record. Treat gate 1 as a background
task that must close before any build is handed to a tester.
