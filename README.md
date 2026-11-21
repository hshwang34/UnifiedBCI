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

## Status

Phases 1–3 of the PRD roadmap are built: replay to report (brief 001, released in 0.1.0),
recording and cued protocols (briefs 004, 005), and closed-loop evaluation with live
feedback (brief 006), all on main. Every hardware brief is waiting for its hand-run
checklist on the real Cyton + Daisy (decision #26). Until a checklist passes, nothing here
claims the board was tested, and no hardware latency is reported.

## Replay to report (brief 001, shipped)

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

## Live acquisition (brief 004, on main)

- **Connect hardware** on the welcome window, or **File ▸ New Recording…** (⌥⌘N) in a
  project, opens the Connect sheet. Pick the dongle's serial port, the synthetic board or the
  **Demo**. The sheet shows the board's identity and the settings it was sent next to the
  settings it reported back.
- Declare the channel map, or choose "Record without positions". Then the acquisition screen
  under Recordings shows a 16-channel preview of the last 10 s and the stream health
  (effective rate, gaps by counter evidence, drain and timestamp intervals, writer backlog,
  free disk). It also has Record / Stop.
- Recordings are committed about once a second and survive a force-quit, a pulled dongle or
  a full disk, each with a named end reason. A reconnect continues the recording in a new
  segment; nothing is joined across the break.
- **Try it without hardware:** choose **Demo**. It streams the bundled example EEG through
  the same live path, with its electrodes declared, so you can preview, record and open the
  recording like any other.

### Supported sources

| Source | Status |
|---|---|
| OpenBCI Cyton + Daisy (USB dongle, 125 Hz radio path) | built, not yet hand-tested |
| BrainFlow synthetic board | built and tested in CI (labelled "generated signal, not a device") |
| Demo (bundled example EEG via BrainFlow's playback-file board) | built and tested in CI |

The Cyton + Daisy row changes once the hand-run checklist in brief 004's appendix passes on
the real board (decision #26).

## Cued protocol (brief 005, on main)

- **Protocols** in the project sidebar lists the project's cued protocols with their version
  and how many runs used each one. A project starts with "Left vs right hand (Graz-style)" v1:
  fixation 2 s, arrow cue 4 s, rest 1.5–2.5 s, 20 trials per class, 4 runs per session.
  Every value can be edited. An edit is saved as a new version, and a version is never
  changed in place.
- **Start Run…** on the acquisition screen (while streaming) picks a protocol version, a
  session seed and the participant display. A borderless full-screen window then shows a
  fixation cross, an arrow and a blank rest, trial after trial, in a seeded order the app can
  reproduce. The operator panel shows the run, trial and phase, the stream health, and
  **Abort Trial** (Esc), **Pause** / **Resume** (Space) and **Abort Run** (⌘.). These keys
  work from either window. With one display, the participant window covers the operator
  window and the keyboard is the control. Each run is its own run and segment in the same
  recording. Its run plan (seed and planned trials) is written before the first cue.
- Every phase is logged as an event with its intended time, the app's presentation
  callback, and the EEG sample it is tied to (the BrainFlow marker the app inserted, or, if
  the marker isn't found, the nearest receipt timestamp, and the event says which).
  **Evaluate** on the recording uses the protocol's class labels and needs at least 3 runs.
  Aborted trials, and trials whose window spans a detected gap, are excluded and listed.
  **Export Result** includes the run plans and the protocol versions they used
  ([docs/export-format.md](docs/export-format.md)).
- **Try it without hardware:** connect the **Demo** source, wait for the preview, press
  **Start Run…**, and run a session. The Demo plays back the bundled example's EEG, which
  has nothing to do with the arrows shown, so evaluating a Demo session tests the workflow,
  not decoding: expect accuracy near chance.

**Timing, stated honestly.** After each run the panel shows "Cue timing (software)": how
late each phase was presented relative to its schedule (median, 95th percentile, max), and
how many screen changes were a frame or more late. These numbers come from the app's own
display callbacks. The delay from the app's callback to light on the screen, and from the
screen to the EEG sample, is **not** measured (that would need a photodiode or trigger box),
so `timingUncertaintyNanos` stays empty for marker-tied cues. That uncertainty is small
relative to a motor-imagery window, which is why this protocol is offered and P300/SSVEP are
not. The Cyton + Daisy behaviour (where the marker lands on real packets, lateness with the
board streaming, two-display setups) is checked by hand in brief 005's appendix.

## Live feedback (brief 006, on main)

- **Freeze for live use…** on a result turns the evaluation's own fit (the one whose held-out
  score is on screen, decision #38) into a frozen model. The sheet lists the channels, rate,
  band-pass, window and class labels it expects, and how long feedback can show in each cue.
  Frozen models are listed under Pipelines.
- **Replay…** runs a recording through the frozen model chunk by chunk (1, 7, 13, 125
  samples and a random mix) beside the offline path. It reports "Streaming matches offline
  within tolerance", or where and by how much it doesn't, against declared tolerances.
- **Live Test** in the sidebar picks a frozen model, an abstention threshold (default 0.60,
  decision #39) and a protocol, then **Start Live Run** runs the cued protocol with feedback.
  During each cue the participant sees a bar grow toward the predicted side, but only for
  windows wholly inside the imagery period (decision #40). Otherwise the bar is hidden and
  the state is named in words: "Model unsure", "Waiting for enough signal", "Signal
  delayed", "Board disconnected" or "Analysis stopped". The operator view mirrors the bar
  under the same rules and adds the raw score, the abstain rate, software latency and each
  trial's outcome. Evaluate and Replay are paused during a live run.
- Afterwards the **live-run card** (in Live Test, and under the result the model came from)
  shows balanced accuracy and accuracy over trials with a 95 % Clopper-Pearson interval, the
  confusion matrix, abstained and invalid trials and why, the larger-class rate,
  `cross-session` / `same-session` / `unknown-session` evidence, the offline result it came
  from, and software latency (receipt → prediction p50 / p95 / max). The app also replays the
  new recording through the model and shows "Live matched replay: n of n windows" or lists
  the windows that differ.
- Predictions (`predictions.jsonl`, every window, every validity) and what the participant
  was shown (`feedback.jsonl`) are logged separately. **Export Result** includes the models
  and live runs that belong to the result ([docs/export-format.md](docs/export-format.md)).
- **Try it without hardware:** connect the **Demo**, record and evaluate three short runs
  with a 2 s window, freeze the result, then start a live run from Live Test. In a Debug
  build, `-BCIExploreExampleAt <new.bciproj> -BCIConnectSource demo -BCILiveTest 2` does all
  of that unattended (add `-BCISnapshotDir <dir>` for screenshots).

**Honest limits.** "Model confidence" is the shrinkage-LDA posterior of the class it
picked. It is not calibrated, and it is not a probability of intent: a two-class model can't
tell when nobody is imagining anything, so abstention is a policy and not a detector.
Latency is software only, from the drain of a window's last sample to the prediction and
then to the frame's presentation callback. Radio or USB transport and display delay are not
measured. The Demo plays recorded EEG that has nothing to do with the arrows on screen, so
a Demo live run is expected to land near chance. It tests the loop, not decoding, and the
card shows it the same way as any other result. Live feedback on a real participant, real
board latency against the 100 ms p95 target, and how often radio bursts trip the 250 ms
stale rule are checked by hand in brief 006's appendix.

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
Sources/Evaluation/         EvaluationRunner: worker lifecycle, typed progress, reproduction links;
                            ReplayRunner, LiveInferenceRunner, FeedbackPolicy (brief 006)
Sources/Protocol/           ProtocolRunner (phases, pauses, aborts, markers), ProtocolSchedule (seeded order)
Sources/Acquisition/        AcquisitionSession (live state machine, drain loop, reconnect), stream
                            health, board configuration and readback, preview buffer
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
