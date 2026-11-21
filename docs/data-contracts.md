# Data contracts (format version 1)

Source of truth for on-disk shapes: `Sources/Contracts/Records.swift`. This document
explains the rules behind the fields and the binary layouts the Swift types point at.
Any change an older reader could misinterpret bumps `ContractVersion.format`. Nothing has
shipped yet, so the 2026-10-20 revisions below stay at version 1.

## Project directory

```
MyExperiment.bciproj/
  project.json                 ProjectManifest (name, format version, created) — no child index
  README.md                    optional; the bundled example carries its license text here
  recordings/<uuid>/
    recording.json             RecordingManifest
    chunks/000000.f64 …        append-only sample chunks (see below)
    events.jsonl               one EventRecord per line, append-only
    runs/<runID>.plan.json     RunPlan of a cued run (brief 005), written before its first cue
  pipelines/<uuid>/
    pipeline.json              PipelineRecord
    fitted.npz                 explicit arrays only (filters, CSP patterns, LDA weights)
  montages/<uuid>/
    montage.json               ChannelMapRecord: a saved channel map (made on first save)
  protocols/<uuid>/
    protocol.json              ProtocolRecord: one immutable cued-protocol version
  results/<uuid>/
    evaluation.json            worker evaluation record (verbatim bytes from the worker)
    result.meta.json           ResultMeta: wall clock, durations, worker build, reproduction link
  models/<uuid>/
    model.json                 ModelRecord: a frozen model; its arrays stay in pipelines/ (brief 006)
  live/<uuid>/
    run.json                   LiveRunRecord: a live run or a stored replay (kind live | replay)
    predictions.jsonl          PredictionRecord per line, append-only
    feedback.jsonl             FeedbackRecord per line, append-only (live runs only)
```

**Index: none. The directory scan is the truth.** A recording, pipeline or result exists
iff its UUID-named directory holds its manifest (`recording.json`, `pipeline.json`,
`result.meta.json`); `project.json` lists nothing. The `index.sqlite` the PRD allows for
navigation is not written in format 1 — it would be derived and rebuildable, never
authoritative, and nothing needs it yet. Everything under `recordings/`, `pipelines/`,
`results/` is immutable once committed. New versions are new directories; nothing is
edited in place. UUIDs in directory names and JSON compare case-insensitively (Swift
writes upper-case, the dataset converter lower-case).

A `.bciproj` may come from anyone, so every manifest is validated as hostile input on
open: chunk file names must be the canonical `chunks/NNNNNN.f64` for their index (the
path is built from the index, never taken from the manifest), dimensions must be
positive with overflow-checked byte sizes, every channel's `sourceRow` must be a row of
every chunk, chunk paths must resolve inside `chunks/`, and the orphan sweep never
follows symbolic links or deletes anything that resolves outside the project. The
worker applies the same rules (`project_io.validate`) before reading a sample, also
requires each chunk to be a regular file (no symlink, FIFO or device) whose `stat`
size matches before it is read, and reports every violation as error code `integrity`.

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
open. Append-only files (`events.jsonl`, `predictions.jsonl`, `feedback.jsonl`) are
appended one line at a time with `O_APPEND` (short writes looped; a failed append is
truncated back to the file's earlier size), fsynced per line, and never rewritten. A
reader drops a last line cut off mid-write (no newline, not decodable) and says so; any
other line that fails to decode is an error.

## Sample chunks (`chunks/NNNNNN.f64`)

- Little-endian IEEE-754 float64, row-major: `rowCount × sampleCount`, exactly as BrainFlow
  returns from `get_board_data`. Row meanings come from `RecordingManifest.channels[].sourceRow`
  plus `timing.sequenceCounterRow` and the BrainFlow timestamp row.
- No header. Dimensions, byte order, and a SHA-256 of the file bytes live in
  `RecordingManifest.chunks[]`. A chunk whose hash does not match is reported, not repaired.
- Commit protocol: write to `chunks/.tmp-NNNNNN`, fsync, rename, then rewrite the manifest
  (atomic rewrite above) with the new `ChunkEntry`. A crash leaves at most one orphan temp
  file, which is deleted on open, or one renamed-but-unlisted chunk, which `verify`
  reports as `unlistedChunk` and nothing adopts or deletes. The committed prefix is always
  readable. `ChunkWriter` exposes the four commit points (`afterTmpWrite`, `afterFsync`,
  `afterRename`, `afterManifestWrite`) through a `CommitHook` so the crash tests kill a
  helper process at each one instead of sleeping.
- Imported recordings (`source.kind == "public_dataset"`) have no counter or timestamp
  rows: the chunk rows are exactly the channels, `channels[i].sourceRow == i`, and the
  timing/package fields of each `ChunkEntry` are `null`.
- Each `ChunkEntry` also records `drainedAtMonotonicNanos` (when the app drained it), the
  first/last BrainFlow timestamp, and the first/last package number, so gaps and clock
  anomalies can be re-derived from the manifest without reading the chunk.
- Chunks are ~1 s of samples (125 at 125 Hz) so forced termination loses ≤ 1 s plus whatever
  BrainFlow's ring buffer held. That buffered loss is reported as a gap with evidence
  `process_terminated`, not silently dropped.
- **The one rewrite of a committed recording manifest.** A live writer holds
  `recordings/<uuid>/.writer.lock` (`flock`, created before the manifest, removed when the
  writer finishes). On open, a recording whose last segment has no `endReason` and whose
  lock is free belonged to a killed writer: `ProjectStore.open` takes the lock, re-reads the
  manifest, and closes each open segment with `endReason: process_terminated`,
  `endedAtMonotonicNanos` = its last chunk's drain time, and a `process_terminated` gap after
  its last committed sample. If the writer was alive but could not close the segment (a disk
  so full the manifest rewrite failed), the lock file holds its note (`disk_full <n>`) and the
  segment is closed with that reason and `uncommittedSampleCount: n` instead. Chunk entries and
  everything else are left byte-for-byte as committed; this is the only post-hoc change a
  committed recording ever gets. `StreamSegment.uncommittedSampleCount` (optional) counts
  samples received for a segment but never committed (disk full, writer backlog), so nothing
  is dropped silently.

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
- `TimingSemantics.timestampGeneratedBy` is `"host"` for every supported board today, and
  `"none"` for an import that carries no per-sample timestamps at all (sample time is
  `index / nominalSampleRateHz` from segment start; `timestampClock` is then `host_wall`
  only because the field is required). If a board ever supplies device timestamps, that is
  a new value, not a reinterpretation.
- An import also has no drain clock. Its `clockMapping.monotonicEpoch` says so
  (`"synthetic: nanoseconds of sample time since the first sample of the source file"`),
  `anchorMonotonicNanos` is 0 and `anchorWall` is the source file's header start date.
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
  `nil` until it has been measured externally; it is never defaulted to 0. One exception
  (brief 005): an event whose `sampleAssociation.method` is `nearest_receipt_timestamp`
  (no BrainFlow marker was found) carries the 95th percentile of the recent drain
  intervals. A receipt timestamp is only known to within the drain that delivered it, so
  this is a conservative software spread of the sample pick, not a measured onset error.
  A `brainflow_marker` association leaves it `nil`. The evaluation counts fallback cues
  (`warnings` kind `cue_by_nearest_timestamp`) and the result screen names them.
  `sourceTimeNanos` is for device-originated markers in the device's own clock.
- Protocol events (brief 005): per trial `fixation`, the class label (the cue), `cue_end`,
  `rest`, and `trial_abort` when aborted; per run `run_start`, `run_end`, `pause`, `resume`.
  `origin` is `"protocol"` for what the runner scheduled and `"operator"` for an operator
  action (abort, pause, resume); every event carries `sessionID`, `runID` and, for trial
  events, `trialID` (`<runID>-t<nn>`, as in the run plan). `intendedAtMonotonicNanos` is the
  scheduled time and `presentedAtMonotonicNanos` the presentation callback of the first
  frame that drew it, converted from `mach_absolute_time` to `host_monotonic` by an offset
  sampled in the same callback; they are never copied from each other, and a missing
  callback leaves `presentedAt` null. Phase events carry a `sampleAssociation`
  (`recordingID`, `segment`, `sampleIndex`, `method`): `brainflow_marker` when the marked
  sample was found, `nearest_receipt_timestamp` when it wasn't (the event time is converted
  to wall clock with the newest drain pair and the nearest BrainFlow timestamp is picked).
  Both are software associations, neither corrected for display or transport delay. Run
  and operator events have no association. They may also carry `reason` (`trial_abort`, `pause`: `operator`,
  `pause`, `disconnect`, `run_aborted`), `aborted` (`run_end` ended early) and
  `plannedLabel` (`trial_abort`: the trial's planned class, so a trial aborted before its
  cue appeared is still listed as excluded). All optional; older readers ignore them.
- The worker never fails a protocol recording over one trial: a cue without an
  association is excluded `no_sample_for_cue` (or `trial_aborted` when aborted), and a
  last `events.jsonl` line cut off mid-write (no newline, not JSON) is ignored with the
  warning `events_last_line_truncated`. Any other malformed line is still an error.

## Sessions, runs, and segments

- `sessionID`: one sitting (cap on, montage unchanged). `runID`: one start-to-stop
  acquisition inside it. Both are stored on the recording, on every segment, and on every
  event so split-by-run and split-by-session are derivable from stored data alone.
  `sessionID` is optional: when the source does not define a session it is `null`, and
  the worker reports `unknown-session` evidence rather than claiming `same-session`. The
  bundled EEGMMIDB example is `null` — PhysioNet lists 14 runs per subject but never says
  which were one sitting, and every EDF carries the same placeholder start date.
- A `StreamSegment` is one contiguous recorded span: samples committed without a break,
  from Record (or a cued run's start) to a stop, disconnect, or failure (`endReason`). It
  is no longer tied to one `start_stream`: with the cued protocol (brief 005) the stream
  keeps going between runs, each run is a new segment with a new `runID`, and stopping
  between runs closes the segment `stopped`. Reconnecting starts a new segment with its own
  sample indices; a reconnect mid-run continues the same `runID` in the new segment.
- `endReason` says how a segment ended, and is set exactly once:
  - `stopped`: Stop recording, Disconnect, closing the project window, or quitting the app.
    The partial last chunk is flushed first.
  - `disconnect`: no samples for 3 s, or a BrainFlow read error. A `disconnect` gap follows
    the last sample. When the board comes back within the 30 s retry window
    (decision #32), the same recording continues in a new segment with the same
    `sessionID` and `runID` and sample indices from 0. When it doesn't, the recording ends
    here.
  - `disk_full`: free space fell under 100 MB, or a write returned `ENOSPC`.
  - `error`: any other write failure, or the writer fell 30 chunks behind. Samples that were
    never committed are counted in `uncommittedSampleCount`.
  - `process_terminated`: set after the fact by `ProjectStore.open` (see "The one rewrite"
    above).
  - `worker_failure`: reserved.
- A segment without an `endReason` is either still being written (its writer lock is held)
  or will be closed as `process_terminated` on the next open.
  Filters and any stateful preprocessing reset at segment start (`preprocessingStatePolicy =
  "reset_on_segment_start"`), and the worker applies the same reset when replaying: the
  band-pass runs once over the whole segment from zero state, and trials whose window
  starts inside the filter's warm-up are excluded and listed. Nothing is ever concatenated
  across segments, and no values are interpolated into raw data. A run may span several
  segments (a reconnect mid-run, decision #35): each segment is still filtered on its own and
  trials still group by run for every split. Segments sharing a `runID` count as one run only
  when they are consecutive by segment index and declare the same session; otherwise the
  evaluation is refused as a duplicate run id. Trial ids must be unique within a recording.

## Protocols and run plans

Added for brief 005 without a format bump: older readers never open `protocols/` or
`runs/`, and `TimingSemantics.markerRow` is an optional key they ignore.

- `protocols/<uuid>/protocol.json` (`ProtocolRecord`) is one version, written once (temp
  directory → fsync → rename) and never edited. Editing makes a new directory with
  `version` + 1, `basedOn` = the version it was edited from, and the same `lineageID` (the
  id of v1). A new project gets the default (decision #28) as v1. Durations are whole
  milliseconds. `contentHash` is SHA-256 over compact sorted-key JSON of the class labels
  and cue symbols, `timing`, `trialsPerClass` and `order`, the fields that decide what the
  participant sees and when; it is recomputed on read, and a mismatch makes the file
  unreadable. Each file is read with a size cap and validated (ids, two classes, labels
  `[a-z0-9_]` and not a protocol event name such as `rest` or `trial_abort`, durations 1 ms–30 s, rest min ≤ max, 1–100 trials per class); a file that
  fails is skipped and counted, never fatal. A new version's parent is re-read from the
  store; a draft identical to any version of its lineage is refused. A stored version whose
  `lineageID` differs from its parent's is flagged ("mislinked") and grouped as a lineage of
  its own, never merged into the one it claims; so is every version on a `basedOn` cycle and
  every version more than 256 below its root. The chain is walked iteratively.
- `recordings/<uuid>/runs/<runID>.plan.json` (`RunPlan`) is written atomically before the
  run's first cue and never replaced. It names the protocol id, version and content hash,
  the session seed, the run index and `seed` = session seed + run index (run seeds stay
  below 2^52 so they are exact in any JSON reader), and the planned trials: id
  `<runID>-t<nn>`, label, drawn rest and nominal offsets in ms from the first fixation
  (fixation, cue, cue end, end; pauses shift what happens, never the plan). Run ids are
  `[A-Za-z0-9_-]`, 1–64 characters, because they name the file. A plan is used only when the
  protocol version it names is stored with the same content hash; otherwise it is listed as a
  protocol mismatch. "Used in n runs" counts the plans that are used. Plans are never written
  through a symbolic link: a symlinked recording (or `runs/`) directory is not a child of the
  project at all.
- Order `seeded_shuffle_v1`: SplitMix64 started at the run seed; Fisher–Yates from the end
  over the class-balanced list (class 0 × N, then class 1 × N) with an unbiased
  rejection draw `below(n)`; then one `below(restMax − restMin + 1)` per trial for rest, on
  a 1 ms grid (the runner shows each phase at the first frame on or after its time). It is
  integer arithmetic only. `Sources/Protocol/ProtocolSchedule.swift` and
  `worker/src/bciworkspace_worker/protocol_schedule.py` implement it, and both are tested
  against `Tests/Fixtures/protocol_schedule_golden.json`.
- `TimingSemantics.markerRow` is BrainFlow's marker row for live recordings (0 except on the
  sample written after `insert_marker`), validated as a row of every chunk; `nil` for imports
  and older recordings. The marker row is a stored chunk row like any other and is never
  exported as a channel. Marker values (`ProtocolRunner.marker(for:in:)`):

  | Value | Event |
  |---|---|
  | 1 | `fixation` |
  | 4 | `cue_end` (the `rest` that starts with it shares its sample) |
  | 5 | `rest` shown after a `trial_abort` |
  | 10 + class index | the cue: 10 for `classes[0]`, 11 for `classes[1]` |

  The cue range starts above every phase value, so a cue is never read as another phase;
  the writer matches by value, not by order. Markers are inserted at the presentation
  callback of the frame that first drew the phase. When no callback came, no marker is
  inserted and the event associates by `nearest_receipt_timestamp` at its intended time.
- An export carries the recording's run plans and exactly the protocol versions they name,
  byte for byte (`docs/export-format.md`, "Run plans and protocols").

## Source and configuration

- `Source.kind` is `"brainflow"` (a real board), `"synthetic"` (BrainFlow's synthetic board,
  `warning: "Synthetic board — generated signal, not a device"`), `"playback"` or
  `"public_dataset"`. A `playback` recording came through BrainFlow's playback-file board.
  It names the played file and its SHA-256 in `sourceFiles`, and never claims a device or
  a data path. The Demo source (decision #42) is a playback of the bundled
  `S001R04-demo-cyton-daisy-125hz.csv`. Its sidecar (`<name>.json`, `kind:
  derived_playback`) is used only when it names the file's hash. It adds the dataset,
  license, attribution, `derivations` (resampled 160 → 125 Hz) and the warning, which stay
  in the manifest and every export. On screen it is called "Demo". The sidecar's channel
  labels, montage and reference pre-fill the channel map, which the operator still confirms. For a public
  dataset the provenance fields are filled: `dataset`, `doi`, `license`, `subject`, `runs`,
  a `warning` the UI shows on the first line of the source panel ("Public dataset, not
  recorded on OpenBCI Cyton+Daisy…"), `attribution` (citations with DOIs, shown in the
  info panel and written to every export), `derivations` (every conversion applied on
  import — channel crop, unit handling, name normalization; resampling is never one) and
  `sourceFiles` (input file names with SHA-256). `boardName` is then the original
  acquisition device as the dataset documents it, `boardID` is `null`, `brainflowVersion`
  is `"n/a"` and `appVersion` names the converter. The bundled example is produced by
  `worker/tools/convert_eegmmidb.py` (dev-time, byte-deterministic, tested).
- `Source.dataPath` distinguishes `radio_125` (dongle, 125 Hz, alternating packets) from
  `sd_250` (on-board SD card, 250 Hz). They are different recordings; neither is a
  resample of the other. It is `nil` for synthetic, playback and imported sources.
- `boardConfiguration.requested` is what the app sent; `boardConfiguration.readback` is
  what the board reported, empty when it offers no readback. Readback is never copied
  from `requested`. Keys are per channel, `chNN.<setting>` (`gain`, `input`, `bias`, `srb2`,
  `power`). `requested` also holds `chNN.command` and `chNN.acknowledged`: `yes` only for a
  Cyton "Success" reply, otherwise `no`, or `not applicable` for boards that aren't a device.
  On a Cyton, `readback` holds each command's `chNN.reply`, plus `raw` (the `?` reply). When
  that reply parses as a register dump, `readback` also holds the per-channel `chNN.gain`,
  `.input`, `.bias`, `.srb2` and `.power` (`CytonRegisterReadback`); otherwise it is `raw`
  only, and nothing is guessed. A readback gain other than 24 disables Record. A
  recording's configuration covers every segment: a reconnect that finds different settings
  ends the recording instead of adding a segment.

## Channel maps

`ChannelSpec.label` is user-declared. The default for a fresh Cyton+Daisy recording is the
BrainFlow default name list, flagged `montage: "undeclared"` until the operator confirms a map (decision #31).
Saved maps are immutable `montages/<uuid>/montage.json` (`ChannelMapRecord`: `mapID`,
`createdAt`, `montage`, `reference`, `channels`); a recording copies the chosen map into its
manifest, so it never depends on `montages/`. Older readers ignore the directory (no format
bump). The reference defaults to `SRB2`.
Scalp positions are never inferred from channel count. Pipelines record
`expectedChannelIDs`; a recording with a different set or order is rejected, not reordered.

## Pipeline and model artifacts

`fitted.npz` holds explicit arrays only: band-pass SOS coefficients, CSP spatial filters and
patterns, chosen component indices and eigenvalues, LDA coefficients/intercept/classes, and
a `feature_kind` tag. No pickled estimators. The reference model's arrays are at the top
level; the baseline's are the same names prefixed `baseline__`, so one file carries both
fits of one evaluation. `pipeline.predict_from_arrays` in the worker is the reference
reader and is tested against the sklearn objects the arrays came from. The worker writes
the file to a path the app supplies inside `pipelines/.tmp-<uuid>/` (binary never crosses
the protocol pipe); `storeResult` renames the directory into place.
`PipelineRecord.splitManifest` stores the worker's `split_manifest` verbatim.
`PipelineRecord.configHash` is SHA-256 over the canonical JSON (sorted keys, compact) of
`configuration` + `expectedChannelIDs` + `expectedSampleRateHz` + `dependencyVersions`,
computed by the worker. The seed is deliberately not part of it: a result is identified by
recording + `configHash` + seed.

## Frozen models and live runs

Added for brief 006 without a format bump: older readers never open `models/` or `live/`,
`results/` is untouched, and `predictions.jsonl` was never written before (so its new
optional fields, the optional `emittedAtMonotonicNanos` and the `invalid_input` validity
break no reader).

- `models/<uuid>/model.json` (`ModelRecord`) freezes one fit of one evaluation (decision
  #38: the evaluation's own fit on its training runs, so the model's evidence is its
  result's held-out score). It is written once (temp directory → fsync → rename) and never
  edited. It holds what the model expects (channel ids in order, rate, band-pass, window,
  the filter warm-up the worker derived), class labels in LDA class order (a positive score
  favours `classLabels[1]`), `role` (`reference`, or `baseline` for the `baseline__` arrays),
  the training runs and their sessions (null where unknown), `configHash`, worker versions
  and `fittedSHA256`. The arrays are not copied: they stay in the immutable
  `pipelines/<sourcePipelineID>/fitted.npz`, whose path is built from the id and never read
  from the record. Freezing requires the worker's `validate_model` summary of that file,
  and the store hashes the bytes again and refuses if they differ; the worker re-checks the
  hash on every use ("model file changed since it was frozen"). The summary must describe
the frozen role and LDA classes exactly `[0, 1]` (the evaluation's `left`, `right`), and every
training run must be in the source recording. One model per fit and role.
- `live/<uuid>/run.json` (`LiveRunRecord`): `kind` `replay` is written once with its
  predictions and parity report. `kind` `live` is written at start and rewritten once at the
  end (`endedAt`, prediction summary, latency summary, live-vs-replay check), with the atomic
  rewrite; a live run without `endedAt` ended with the app. Its logs are created empty and
  fsynced with the directory at start. A log that would pass the 64 MB read cap stops
  logging instead (`loggingStopped` names why), so it always stays readable. Both store the model, recording,
  runs, hop and abstention threshold (decision #39); a live run also its stale limit.
- `predictions.jsonl` gets `sequence` (from 0, per run), `validityDetail`,
  `acquisitionReceiptMonotonicNanos`, `workerComputeNanos`, `confidence` (the uncalibrated
  shrinkage-LDA posterior of the predicted class, "model confidence" on screen),
  `windowKind` (`hop` | `cue_locked`), `trialID`, `feedbackEligible` and, in a replay,
  `offline` (the reference path's validity and score for the same window). A replay has no
  emission clock, so `emittedAtMonotonicNanos` is null there. In live logs
  `feedbackPresentedAtMonotonicNanos` stays null: `feedback.jsonl` (`FeedbackRecord`) holds
  what the participant saw (bar side and length as a fraction of the half-width, or hidden
  and the words shown instead) and the presentation callback of the first frame showing it,
  keyed by prediction `sequence`.

## Results and reproduction

`results/<uuid>/` is written as `.tmp-<uuid>` and renamed, so it is complete or absent.
`evaluation.json` is the `evaluation` member of the worker's `fit_evaluate_project`
response, byte-for-byte (the client slices it out of the response line without
re-encoding). `result.meta.json` (`ResultMeta`) carries everything that varies between
two runs of the same evaluation and therefore must stay out of `evaluation.json`:
wall-clock `createdAt`, `durationsSeconds` (worker stages from its `done` event plus the
app's total), `workerVersions`, `workerOrigin`, `evaluationSHA256`, and the reproduction
link. Results are listed by `createdAt`.

Same recording + `configHash` + seed as an earlier result: the evaluation is still run
(that is the reproducibility evidence), the bytes are compared, and the new record is
stored with `reproductionOf` = the root original when identical, or `divergedFrom` = that
original when not. Both stay listed. A different seed is simply a new result.

Export (`ProjectStore.export(result:to:)`) is documented in `docs/export-format.md`.

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
  the online path never sees), `window_starts_before_segment`, `window_exceeds_segment`,
  `trial_aborted` (a `trial_abort` event names the trial; decision #34), `no_sample_for_cue`
  (a cue event without a sample association, so it can't be placed in the data), and
  `window_spans_detected_gap` (a `sequence_skip`, `stale_half`, `duplicate_counter`,
  `invalid_counter` or `overflow_suspected` gap lies inside the window or inside the filter
  warm-up before it, so the band-passed window would carry the discontinuity's transient;
  the entry adds `gap_after_sample` and `gap_evidence`). `duplicate_counter` counts because
  BrainFlow stores a repeated packet as received: nothing is lost, but the window holds one
  sample twice and the rest one period late. `receipt_interval` and `clock_anomaly` never
  exclude. **Behaviour change (brief 005):** a recording made before brief 005 whose
  manifest lists such gaps used to keep every trial; re-evaluating it now excludes the
  trials those gaps touch, so its result differs (stored as `divergedFrom`). Recordings with
  no such gaps, including the bundled example and the test fixture, evaluate byte for byte
  as before.
- `warnings` — present only when there is something to say. Today: a `trial_abort` event
  naming a trial with no cue in the recording (`abort_names_unknown_trial`).
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
- `data_source` — `kind`, recording id, counts, and for synthetic or public-dataset data the
  `warning` string the UI must display, plus `dataset`/`doi`/`license`/`subject`/`runs`
  passed through from the recording's `source`.

## Prediction and action

One `PredictionRecord` per emission, live or replay. `validity` is one of `valid`,
`insufficient_window`, `stale`, `disconnected`, `worker_unavailable`, `channel_mismatch`,
`invalid_input` (the worker refused the window's samples).
`inputSampleRange` is `{start, count}` or `null` when no samples were used.
`action` is `{kind: "class", label: "<class>"}` or `{kind: "abstain"}` — abstention is a
policy outcome, not a third class, and carries no label.
`feedbackPresentedAtMonotonicNanos` is what the participant saw and when; it is logged
separately from `emittedAtMonotonicNanos` so software latency and feedback latency can be
reported as different numbers.
