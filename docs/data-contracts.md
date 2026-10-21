# Data contracts (format version 1)

Source of truth for on-disk shapes: `Sources/Contracts/Records.swift`. This document
explains the rules behind the fields and the binary layouts the Swift types point at.
Any change an older reader could misinterpret bumps `ContractVersion.format`. Nothing has
shipped yet, so the 2026-10-20 revisions below stay at version 1.

## Project directory

```
MyExperiment.bciproj/
  project.json                 ProjectManifest (name, format version, created, child id indexes)
  recordings/<uuid>/
    recording.json             RecordingManifest
    chunks/000000.f64 …        append-only sample chunks (see below)
    events.jsonl               one EventRecord per line, append-only
  pipelines/<uuid>/
    pipeline.json              PipelineRecord
    fitted.npz                 explicit arrays only (filters, CSP patterns, LDA weights)
  results/<uuid>/
    evaluation.json            worker evaluation record (verbatim bytes from the worker)
    predictions.jsonl          PredictionRecord per line (replay and live)
  index.sqlite                 derived; rebuildable from the files above, never authoritative
```

Everything under `recordings/`, `pipelines/`, `results/` is immutable once committed. New
versions are new directories; nothing is edited in place.

### JSON coding

Every manifest is written with `ContractJSON.encoder()` and read with
`ContractJSON.decoder()`: sorted keys, pretty-printed, slashes unescaped, NaN refused, and
dates as **ISO-8601 with fractional seconds** (`2026-10-20T04:05:06.789Z`). Foundation's
stock `.iso8601` strategy drops the fraction, so it is never used. The decoder also
accepts whole-second stamps from hand-edited files. Enums serialize as their snake_case
raw values (`insufficient_window`, `stale_half`, `radio_125`).

### Atomic rewrites

Every manifest rewrite (`project.json`, `recording.json`, `pipeline.json`) follows one
protocol: write the complete new content to a sibling temp file (`.tmp-<name>`), `fsync`
it, `rename(2)` over the target, then `fsync` the directory. A crash leaves either the old
file or the new file, never a torn one, and at most one temp file, which is deleted on
open. Append-only files (`events.jsonl`, `predictions.jsonl`) are appended with one
`write` per line and never rewritten.

## Sample chunks (`chunks/NNNNNN.f64`)

- Little-endian IEEE-754 float64, row-major: `rowCount × sampleCount`, exactly as BrainFlow
  returns from `get_board_data`. Row meanings come from `RecordingManifest.channels[].sourceRow`
  plus `timing.sequenceCounterRow` and the BrainFlow timestamp row.
- No header. Dimensions, byte order, and a SHA-256 of the file bytes live in
  `RecordingManifest.chunks[]`. A chunk whose hash does not match is reported, not repaired.
- Commit protocol: write to `chunks/.tmp-NNNNNN`, fsync, rename, then rewrite the manifest
  (atomic rewrite above) with the new `ChunkEntry`. A crash leaves at most one orphan temp
  file, which is deleted on open. The committed prefix is always readable.
- Each `ChunkEntry` also records `drainedAtMonotonicNanos` (when the app drained it), the
  first/last BrainFlow timestamp, and the first/last package number, so gaps and clock
  anomalies can be re-derived from the manifest without reading the chunk.
- Chunks are ~1 s of samples (125 at 125 Hz) so forced termination loses ≤ 1 s plus whatever
  BrainFlow's ring buffer held. That buffered loss is reported as a gap with evidence
  `process_terminated`, not silently dropped.

## Timing semantics

Three clocks, never mixed:

| Clock | Where | What it measures |
|---|---|---|
| `brainflow_receipt` | BrainFlow timestamp row | **Host wall clock via `gettimeofday`** (seconds, µs resolution) when BrainFlow parsed the packet. Not monotonic — NTP can step it backwards — and **not** the ADC clock. |
| `host_monotonic` | `HostMonotonicClock` in the app | `CLOCK_MONOTONIC_RAW` nanoseconds since boot: when the app drained a chunk or presented a cue. |
| `host_wall` | `Date` | Human-readable correlation only. |

- `RecordingManifest.clockMapping` holds one anchor pair (`anchorMonotonicNanos`,
  `anchorWall`) taken at recording start, plus the epoch definition string, so monotonic
  values can be placed on a calendar after the fact and across machines.
- `TimingSemantics.timestampGeneratedBy` is `"host"` for every supported board today. If a
  board ever supplies device timestamps, that is a new value, not a reinterpretation.
- `TimingSemantics.sequenceStep` is the expected package-counter increment per committed
  sample: **1** for the synthetic board and Cyton alone, **2 for Cyton+Daisy** (BrainFlow
  commits one sample per board/Daisy packet pair and writes the even packet's counter, so
  valid Daisy counters are even and wrap mod 256). `BoardDescription.sequenceStep` exposes
  the same value and `SequenceAccounting` in the bridge is the single implementation.
- A gap is declared only from sequence-counter evidence or an explicit disconnect; receipt
  jitter alone is logged as `evidence: "receipt_interval"` with
  `estimatedMissingSamples: nil`. Gap evidence values:
  - `sequence_skip` — counter advanced by more than `sequenceStep`; `estimatedMissingSamples`
    = `(delta − step) / step`, and `ambiguous` is always true because losses of ≥ 256/step
    samples alias to smaller ones.
  - `stale_half` — counter repeated on a step-2 board: one half of the packet pair was lost
    and the committed sample mixes halves.
  - `duplicate_counter` — counter repeated on a step-1 board: a duplicated packet, not a
    loss. Provenance only, `estimatedMissingSamples: nil`.
  - `invalid_counter` — the counter row held a non-finite or non-integer value; the sample
    is kept but its place in the sequence is unknown.
  - `overflow_suspected` — at drain time BrainFlow reported ≥ `bufferSize − 125` samples
    available; its ring buffer drops the oldest silently.
  - `clock_anomaly` — the wall-clock timestamp stepped backwards. Provenance only; never a
    data gap.
  - `receipt_interval`, `process_terminated`, `disconnect` — as named.
- Bursty receipt intervals are recorded as-is and are never used to infer sample loss.
- Cue events carry `intendedAt` and `presentedAt` separately. `timingUncertaintyNanos` is
  `nil` until it has been measured externally; it is never defaulted to 0.
  `sourceTimeNanos` is for device-originated markers in the device's own clock.

## Sessions, runs, and segments

- `sessionID`: one sitting (cap on, montage unchanged). `runID`: one start-to-stop
  acquisition inside it. Both are stored on the recording, on every segment, and on every
  event so split-by-run and split-by-session are derivable from stored data alone.
- A `StreamSegment` is a contiguous run from one `start_stream` to a stop, disconnect, or
  failure (`endReason`). Reconnecting starts a new segment with its own sample indices.
  Filters and any stateful preprocessing reset at segment start (`preprocessingStatePolicy =
  "reset_on_segment_start"`), and the worker applies the same reset when replaying: the
  band-pass runs once over the whole segment from zero state, and trials whose window
  starts inside the filter's warm-up are excluded and listed. Nothing is ever concatenated
  across segments, and no values are interpolated into raw data.

## Source and configuration

- `Source.dataPath` distinguishes `radio_125` (dongle, 125 Hz, alternating packets) from
  `sd_250` (on-board SD card, 250 Hz). They are different recordings; neither is a
  resample of the other. It is `nil` for synthetic and imported sources.
- `boardConfiguration.requested` is what the app sent; `boardConfiguration.readback` is
  what the board reported, empty when it offers no readback. Readback is never copied
  from `requested`.

## Channel maps

`ChannelSpec.label` is user-declared. The default for a fresh Cyton+Daisy recording is the
BrainFlow default name list, flagged `montage: "unspecified"` until the operator confirms it.
Scalp positions are never inferred from channel count. Pipelines record
`expectedChannelIDs`; a recording with a different set or order is rejected, not reordered.

## Pipeline and model artifacts

`fitted.npz` holds explicit arrays only: band-pass SOS coefficients, CSP spatial filters and
patterns, chosen component indices and eigenvalues, LDA coefficients/intercept/classes, and
a `feature_kind` tag. No pickled estimators. `pipeline.predict_from_arrays` in the worker is
the reference reader and is tested against the sklearn objects the arrays came from.
`PipelineRecord.splitManifest` stores the worker's `split_manifest` verbatim.
`PipelineRecord.configHash` is SHA-256 over the canonical JSON of `configuration` +
`expectedChannelIDs` + `expectedSampleRateHz` + dependency versions.

## Evaluation record (from the worker)

Produced by `pipeline.fit_evaluate` and stored byte-for-byte as `evaluation.json` (the
client passes the worker's `result` bytes through without re-encoding):

- `split_policy` — unit (`trial`), grouping (`run`), holdout description, CV description,
  `evidence` (`same-session` | `cross-session` | `mixed-session` | `unknown-session`,
  derived from the session ids of held-out vs training runs; any run without a session
  id makes it `unknown-session` — the stronger labels are claims, not defaults), seed.
- `split_manifest` — the frozen split by id: `holdout_runs`, `holdout_trials`,
  `training_runs`, and `folds[].test_runs`. Supplying it back re-scores the identical
  split regardless of seed; a manifest that does not match the data is refused.
- `class_counts` — per split.
- `exclusions` — trials dropped and why; empty is a valid answer. Reasons:
  `window_starts_before_filter_warmup` (the window begins inside the band-pass warm-up,
  derived from the filter's slowest pole, so its features would carry a start transient
  the online path never sees), `window_starts_before_segment`, `window_exceeds_segment`.
- `models.<name>` — per-fold grouped CV balanced accuracy, and a `holdout` block with
  balanced accuracy, accuracy, confusion matrix, `n_test_trials`, `n_test_runs`, a 95 %
  Clopper-Pearson interval over held-out **trials**, `per_run` scores, and a run-level
  bootstrap interval for balanced accuracy (`null` when only one run was held out).
- `comparison` — paired reference-vs-baseline: per-run differences, their mean, a paired
  run-level bootstrap interval, and paired trial counts (reference-only / baseline-only /
  both / neither correct).
- `uncertainty_notes` — states that the trial interval assumes independent trials, which
  holds because each trial contributes exactly one window.
- `config` — derived from the fitted objects: filter band/order/sections/direction,
  warm-up, window, CSP components and chosen indices, per-class shrinkage, LDA solver and
  shrinkage.
- `data_source` — `kind` and, for synthetic data, a warning string that the UI must display.

## Prediction and action

One `PredictionRecord` per emission, live or replay. `validity` is one of `valid`,
`insufficient_window`, `stale`, `disconnected`, `worker_unavailable`, `channel_mismatch`.
`inputSampleRange` is `{start, count}` or `null` when no samples were used.
`action` is `{kind: "class", label: "<class>"}` or `{kind: "abstain"}` — abstention is a
policy outcome, not a third class, and carries no label.
`feedbackPresentedAtMonotonicNanos` is what the participant saw and when; it is logged
separately from `emittedAtMonotonicNanos` so software latency and feedback latency can be
reported as different numbers.
