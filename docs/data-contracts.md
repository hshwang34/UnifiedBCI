# Data contracts (format version 1)

Source of truth for on-disk shapes: `Sources/Contracts/Records.swift`. This document
explains the rules behind the fields and the binary layouts the Swift types point at.
Any change an older reader could misinterpret bumps `ContractVersion.format`.

## Project directory

```
MyExperiment.bciproj/
  project.json                 ProjectManifest (name, format version, created, index of children)
  recordings/<uuid>/
    recording.json             RecordingManifest
    chunks/000000.f64 …        append-only sample chunks (see below)
    events.jsonl               one EventRecord per line, append-only
  pipelines/<uuid>/
    pipeline.json              PipelineRecord
    fitted.npz                 explicit arrays only (filters, CSP patterns, LDA weights)
  results/<uuid>/
    evaluation.json            worker evaluation record (verbatim)
    predictions.jsonl          PredictionRecord per line (replay and live)
  index.sqlite                 derived; rebuildable from the files above, never authoritative
```

Everything under `recordings/`, `pipelines/`, `results/` is immutable once committed. New
versions are new directories; nothing is edited in place.

## Sample chunks (`chunks/NNNNNN.f64`)

- Little-endian IEEE-754 float64, row-major: `rowCount × sampleCount`, exactly as BrainFlow
  returns from `get_board_data`. Row meanings come from `RecordingManifest.channels[].sourceRow`
  plus `timing.sequenceCounterRow` and the BrainFlow timestamp row.
- No header. Dimensions, byte order, and a SHA-256 of the file bytes live in
  `RecordingManifest.chunks[]`. A chunk whose hash does not match is reported, not repaired.
- Commit protocol: write to `chunks/.tmp-NNNNNN`, fsync, rename, then append the
  `ChunkEntry` to the manifest and fsync again. A crash leaves at most one orphan temp file,
  which is deleted on open. The committed prefix is always readable.
- Chunks are ~1 s of samples (125 at 125 Hz) so forced termination loses ≤ 1 s plus whatever
  BrainFlow's ring buffer held. That buffered loss is reported as a gap with evidence
  `"process_terminated"`, not silently dropped.

## Timing semantics

Three clocks, never mixed:

| Clock | Where | What it measures |
|---|---|---|
| `brainflow_receipt` | BrainFlow timestamp row | For Cyton over the dongle: host time when BrainFlow parsed the packet. **Not** the ADC clock. |
| `host_monotonic` | `ContinuousClock` in the app | When the app drained a chunk or presented a cue. |
| `host_wall` | `Date` | Human-readable correlation only. |

- `TimingSemantics.timestampGeneratedBy` is `"host"` for every supported board today. If a
  board ever supplies device timestamps, that is a new value, not a reinterpretation.
- Bursty receipt intervals are recorded as-is. A gap is declared only from sequence-counter
  evidence (`package_num` skips, modulo the 0–255 wrap) or an explicit disconnect; receipt
  jitter alone is logged as `evidence: "receipt_interval"` with `estimatedMissingSamples: nil`.
- Cue events carry `intendedAt` and `presentedAt` separately. `timingUncertaintyNanos` is
  `nil` until it has been measured externally; it is never defaulted to 0.

## Segments and reconnection

A `StreamSegment` is a contiguous run from one `start_stream` to a stop, disconnect, or
failure. Reconnecting starts a new segment with its own sample indices. Filters and any
stateful preprocessing reset at segment start (`preprocessingStatePolicy =
"reset_on_segment_start"`), and the worker applies the same reset when replaying. Nothing is
ever concatenated across segments, and no values are interpolated into raw data.

## Channel maps

`ChannelSpec.label` is user-declared. The default for a fresh Cyton+Daisy recording is the
BrainFlow default name list, flagged `montage: "unspecified"` until the operator confirms it.
Scalp positions are never inferred from channel count. Pipelines record
`expectedChannelIDs`; a recording with a different set or order is rejected, not reordered.

## Pipeline and model artifacts

`fitted.npz` holds explicit arrays only: band-pass SOS coefficients, CSP spatial filters and
patterns, chosen component indices, LDA coefficients/intercept, and feature normalization
constants. No pickled estimators. `PipelineRecord.configHash` is SHA-256 over the canonical
JSON of `configuration` + `expectedChannelIDs` + `expectedSampleRateHz` + dependency versions.

## Evaluation record (from the worker)

Produced by `pipeline.fit_evaluate` and stored verbatim as `evaluation.json`:

- `split_policy` — unit (`trial`), grouping (`run`), holdout description, CV description,
  `evidence` (`same-session` | `cross-session`), seed.
- `class_counts` — per split.
- `exclusions` — trials dropped and why (empty is a valid answer).
- `models.<name>` — per-fold grouped CV balanced accuracy, and a `holdout` block with
  balanced accuracy, accuracy, confusion matrix, `n_test_trials`, and a 95 % Clopper-Pearson
  interval over held-out **trials**.
- `config` — filter band/order/direction, CSP components and regularization, LDA shrinkage.
- `data_source` — `kind` and, for synthetic data, a warning string that the UI must display.

## Prediction and action

One `PredictionRecord` per emission, live or replay. `validity` is one of `valid`,
`insufficient_window`, `stale`, `disconnected`, `worker_unavailable`, `channel_mismatch`.
`action` is a class label or `abstain`. `feedbackPresentedAtMonotonicNanos` is what the
participant saw and when; it is logged separately from `emittedAtMonotonicNanos` so
software latency and feedback latency can be reported as different numbers.
