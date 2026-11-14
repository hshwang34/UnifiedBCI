# BCI Workspace

A native macOS workspace for producing, inspecting, reproducing, and live-testing a BCI
experiment. First device: OpenBCI Cyton + Daisy. First recipe: two-class motor imagery
with CSP + shrinkage LDA. Recorded-data workflows come before hardware.

Product requirements and architecture: see the PRD this repo was started from
(`docs/PRD.md`). This README tracks what is actually built.

## Download

[**BCI Workspace 0.1.0**](https://github.com/hshwang34/UnifiedBCI/releases/latest): a
Developer ID-signed, notarized DMG for Apple Silicon Macs on macOS 15 or later. Open it and
drag the app to Applications.

## Status — Phase 1 "replay to report" (brief 001, shipped)

What a user can do today, with no hardware and no terminal:

- **Explore the bundled example**: PhysioNet EEGMMIDB S001, three motor-imagery runs,
  16 sensorimotor channels, ODC-BY, with its citation shown and exported.
- **Inspect a recording**: source and provenance, channels with their montage and
  reference, continuous segments and gaps, and the event table.
- **Evaluate** the reference pipeline (causal 8–30 Hz band-pass → CSP → shrinkage LDA)
  against a frozen, run-level holdout: balanced accuracy, accuracy with a trial-level
  95 % interval, confusion matrix, class counts, exclusions, the simpler log-variance
  baseline, and the seed that reproduces the split.
- **Reproduce and export**: every result stores its full configuration and reproduction
  links; File ▸ Export Result writes a documented folder readable outside the app
  ([docs/export-format.md](docs/export-format.md)).

Under the hood: a `.bciproj` project store with atomic, hash-verified chunk commits, a
pinned Python analysis worker bundled inside the app, and a native BrainFlow bridge proven
in phase 0 ([docs/phase-0-results.md](docs/phase-0-results.md)); the phase-0 feasibility
checks stay available in their own window.

Also shipped since 0.1.0 (on main, in the next release): a first-run intro and a 3D
montage view of the declared electrode positions (brief 003), and a **Quality** tab on each
recording with per-channel spectra (raw and band-passed) and flatline, clipping, large
deflection, mains and outlier checks that each name their rule and measured value (brief 002).
Next: a raw / band-passed signal trace view. Live Cyton + Daisy acquisition, cued protocols
and live feedback are phase 2.

## Layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated, not committed)
App/                        SwiftUI app: welcome, project window (recordings, results), export, feasibility window
  Resources/ExampleProject/ S001-motor-imagery.bciproj — bundled example (7.9 MB, folder reference)
Sources/BrainFlowBridge/    actor-owned Swift wrapper over BrainFlow's C ABI
Sources/WorkerClient/       JSON-lines IPC client that owns the Python worker process
Sources/Contracts/          on-disk record types: Project, Recording, Event, Pipeline, Result, Prediction
Sources/ProjectStore/       .bciproj store: atomic chunk writer + CommitHook, verified reader,
                            bundled-example import, results, export
Sources/Evaluation/         EvaluationRunner: worker lifecycle, typed progress, reproduction links
Tools/BCIStoreCrashHelper/  command-line helper the crash tests kill at a named commit point
Tests/                      XCTest: bridge, worker, contracts, store (crash matrix), runner, export
  Fixtures/tiny.bciproj     8-channel, 42 s/run cut of the example for fast tests
native/brainflow/           C headers (5.23.0) + module map; dylib vendored by script
worker/                     Python 3.12 package, pinned by uv.lock (runtime: numpy/scipy/sklearn/brainflow;
  src/bciworkspace_worker/  mne is dev-only) protocol.py · pipeline.py (own CSP+rLDA, baseline) ·
                            project_io.py (verified chunk reads) · main.py
  tools/                    convert_eegmmidb.py — dev-time EDF → .bciproj converter (needs mne)
docs/                       data contracts, export format, ADRs, phase results, product briefs
scripts/                    bootstrap.sh · vendor_brainflow.sh · bundle_worker.sh
```

Regenerating the bundled example and the test fixture from the raw PhysioNet files
(downloaded by hand into `build/datasets/eegmmidb/`, never committed):

```sh
cd worker
uv run python tools/convert_eegmmidb.py --raw-dir ../build/datasets/eegmmidb --out ../App/Resources/ExampleProject/S001-motor-imagery.bciproj
uv run python tools/convert_eegmmidb.py --raw-dir ../build/datasets/eegmmidb --out ../Tests/Fixtures/tiny.bciproj --preset tiny
```

The converter is byte-deterministic and `tests/test_convert_eegmmidb.py` (skipped
without the raw files) checks the committed fixture matches it.

## Build

Requirements: macOS 15+, Xcode 26, `brew install uv xcodegen`.

```sh
scripts/bootstrap.sh          # uv sync, vendor BrainFlow dylib, generate .xcodeproj
open BCIWorkspace.xcodeproj   # or:
xcodebuild -project BCIWorkspace.xcodeproj -scheme BCIWorkspace test
(cd worker && uv run pytest)  # worker-only tests; add `-m slow` for the full-example budget test
```

Debug builds launch the worker from `worker/.venv` (path baked into Info.plist as
`BCIWorkerDevRoot`; empty in Release). `scripts/bundle_worker.sh` assembles an arm64-only
interpreter + site-packages under `build/worker-dist/` (149 MB), which the build copies
into the app bundle and the app prefers when present; `--sign <identity>` signs every
Mach-O individually. The interpreter is launched isolated (`-I`, or `-s -P` when the
bundled site needs `PYTHONPATH`) with a scrubbed environment; the app never falls back to
a system Python.

Release builds are signed with the personal Developer ID under the hardened runtime and
notarized: `scripts/release.sh <version>` produces a stapled DMG in `build/release/`
([docs/RELEASING.md](docs/RELEASING.md)).

## Design rules carried from the PRD

- One owner for acquisition; UI and training never block draining the device.
- Record sequence numbers (step +1, or +2 mod 256 on Cyton+Daisy), BrainFlow's wall-clock
  timestamps, host monotonic drain time, and gaps. Never reinterpret bursty arrival times
  as an irregular ADC clock; never interpolate raw data.
- Fit every pipeline step inside the training fold; split by run/session, never by window;
  freeze a holdout before fitting; report per-trial uncertainty and a simpler baseline.
- Offline evaluation replays the same causal transforms, state policy, and gap behavior
  used online: the band-pass runs once over each continuous segment from zero state and
  trials are cut afterwards; trials inside the filter warm-up are excluded and listed.
- Explicit channel maps and montages; nothing is inferred from channel count.
- A two-class classifier does not detect "no intent"; abstention is a policy, not evidence.

## Non-goals (for now)

Every BrainFlow device, graph editors, plugins, cloud accounts, clinical use, guaranteed
motor-imagery performance. See PRD section 10.
