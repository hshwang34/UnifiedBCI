# 005 — Cued motor-imagery protocol

**Status:** draft · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
After brief 004 a user can record a stream, but a stream without labelled trials can't be
evaluated: `fit_evaluate_project` needs cue events with a sample association, and today
only the bundled example (converted from EDF annotations) has them. To collect their own
motor-imagery data, a user would have to run a separate stimulus program and then align its
log with the recording by hand, which is exactly the fragile transition the PRD names. PRD §5
makes this P0: "Run one configurable, cued two-class motor-imagery protocol. Seeded trial
order, rest/cue periods, aborts, and timing records survive export. Channel/montage
configuration is explicit." PRD §6 adds: "Log intended presentation and presentation
callbacks separately."

## Who it's for
The developer running a session on themselves or a participant: the operator sits at the
project window, the participant faces a full-screen cue window. Afterwards, the same
developer evaluating the new recording with the existing pipeline.

## What success looks like
- A project has a **Protocols** section with the Graz-style default (decision #28) ready to
  run; changing any value makes a new protocol version, and a version that has been used can
  never change.
- The operator starts a run from the acquisition screen; the participant sees a fixation
  cross, an arrow, a blank rest, trial after trial, in a seeded order the app can reproduce.
- The operator sees where the run is (trial 17 of 40, current phase, time left), stream
  health, and can abort the trial or the run at any time.
- When the run ends, the recording has one event per cue phase with intended time, the
  presentation-callback time, and a sample association; its run plan sits beside it.
- Pressing Evaluate on that recording works with no extra setup and reports the protocol's
  class labels.
- Every place that shows cue timing says what it is: software-logged, not measured on the screen.

## Acceptance criteria
Protocol definition
- [ ] Sidebar **Protocols** lists the project's protocols with name, version and "used in n
      runs". A new project gets the default protocol "Left vs right hand (Graz-style)" v1:
      classes `cue_left_hand` (left arrow) and `cue_right_hand` (right arrow), fixation 2.0 s,
      cue 4.0 s, rest uniform 1.5–2.5 s, 20 trials per class per run, seeded shuffle,
      4 runs per session (Q4), break between runs operator-controlled.
- [ ] Every value is editable (decision #28): class display names and stored labels, cue
      symbol, each phase duration, rest range, trials per class, runs per session, and
      participant instructions text. Editing produces a new version (`v2`, `basedOn` v1);
      versions are never edited in place, and a version stays listed after a newer one exists.
- [ ] Validation names the rule: durations > 0 and ≤ 30 s, rest min ≤ max, 1–100 trials per
      class, labels unique, non-empty and `[a-z0-9_]`, two classes exactly (this recipe is
      two-class), cue ≥ the pipeline window end (offset + length) or a warning says the
      default evaluation window won't fit inside the cue.
- [ ] A protocol is stored as `protocols/<uuid>/protocol.json` (`ProtocolRecord`); its
      `contentHash` (SHA-256 over canonical JSON of the timing and class fields) is copied to
      every run that uses it.

Trial order
- [ ] Each run's order is a seeded shuffle of exactly N trials per class (Fisher–Yates over
      a documented PRNG); rest durations are drawn from the same seeded stream. The seed is
      stored. The same protocol version + seed gives the same order and rest durations, on any
      Mac and in the worker (golden-vector test in Swift and Python).
- [ ] The run plan (`recordings/<uuid>/runs/<runID>.plan.json`: protocol id/version/hash,
      seed, trial list with id, label, drawn rest, intended offsets) is written atomically
      before the run's first cue. Trial ids are `<runID>-t<nn>`.

Running
- [ ] From the acquisition screen (brief 004) in **streaming** state with a declared or
      explicitly undeclared channel map: **Start run…** picks a protocol version and opens the
      participant window. Each run is a new `runID` in the same recording and session, and
      a new segment.
- [ ] Participant window: its own borderless full-screen window on the chosen display (Q3),
      neutral dark background, centred white fixation cross, arrow cue drawn over it, blank
      during rest; instructions screen before the first trial ("Press Space when ready" —
      operator-side key); optional "Break" screen between runs. No operator controls, no
      health numbers, no feedback (feedback is brief 006). Cursor hidden; never takes focus
      from the operator window on a two-display setup.
- [ ] Operator panel (in the project window): run n of 4, trial k of 40, current phase and
      class, elapsed / remaining run time, the brief 004 health panel, and **Abort trial**,
      **Pause** / **Resume**, **Abort run**. Keyboard: Esc = abort trial, ⌘. = abort run,
      working from either window.
- [ ] Abort trial: the trial is marked aborted (event `trial_abort`), the participant sees rest,
      the run continues with the next planned trial; aborted trials are not re-queued (Q1).
      Abort run: the run ends (`run_end` with `aborted: true`), its segment closes `stopped`,
      completed trials remain evaluable.
- [ ] Disconnect during a run (brief 004 **interrupted**): the current trial is aborted with
      reason `disconnect`, the run pauses, and after reconnect the operator can resume (the
      next planned trial continues in the new segment) or end the run (Q2).
- [ ] Recording stops at the run's end (after the last rest) unless the operator starts the
      next run; the stream and preview keep going between runs.

Events and timing
- [ ] Events per trial, appended to `events.jsonl` as they happen through
      `ChunkWriter.appendEvent`: `fixation`, the class label (`cue_left_hand` /
      `cue_right_hand`), `cue_end`, `rest`, plus `trial_abort` when aborted; per run
      `run_start`, `run_end`, `pause`, `resume`. All with `origin: "protocol"` (operator
      actions `origin: "operator"`), `sessionID`, `runID`, `trialID`.
- [ ] `intendedAtMonotonicNanos` is the scheduled time on `HostMonotonicClock`;
      `presentedAtMonotonicNanos` is the presentation callback of the first frame that drew it
      (converted to the same clock). They are stored separately and never copied from each
      other; a missing callback leaves `presentedAt` null.
- [ ] `sampleAssociation` for every phase event: the sample BrainFlow marked when the app
      inserted a marker at the presentation callback (`method: "brainflow_marker"`, marker
      value per event type, marker row recorded in the manifest's timing). If the marker can't
      be found, `nearest_receipt_timestamp` is used and the method says so.
- [ ] `timingUncertaintyNanos` stays null (not measured; data contracts).
- [ ] After each run the operator panel shows "Cue timing (software)": presented − intended
      p50 / p95 / max, frames late, and the copy "Measured from the app's own callbacks. The
      delay to the screen and to the EEG sample is not measured."

Evaluable result
- [ ] Evaluate on a protocol recording uses the protocol's class labels (not the bundled
      example's `cue_left_fist`), and the protocol's cue window for the default offset/length
      check. A recording with fewer than 3 runs says "Needs at least 3 runs (1 held out, 2
      for cross-validation); this recording has n."
- [ ] Trials are cut at the cue event's sample association. Exclusions add
      `trial_aborted` and `window_spans_detected_gap` (a `sequence_skip`, `stale_half`,
      `invalid_counter` or `overflow_suspected` gap inside the window) to the existing reasons,
      and are listed.
- [ ] A run with more than one segment (reconnect) evaluates: segments are filtered
      separately from zero state; the split still groups by run.
- [ ] `sessionID` on a protocol recording is set, so evaluation evidence is `same-session`
      within it.
- [ ] Export includes `protocol.json` for every version used and every run plan;
      `docs/export-format.md` documents them. Events survive export byte-for-byte as today.

Tests
- [ ] Golden vectors: seed → order and rests, identical in Swift and Python.
- [ ] `ProtocolRunner` with a fake clock and a synthetic or playback board: a full default run
      produces exactly 40 trials × 4 phase events + run events, intended times on schedule.
- [ ] Abort trial, abort run, pause/resume, and disconnect-then-resume produce the documented
      events and segments.
- [ ] An end-to-end synthetic test: record 4 short runs (2 trials/class, short phases) on the
      synthetic board with class-dependent signal injected by the playback fixture, then
      `fit_evaluate_project` returns a record with the protocol labels and no unexpected
      exclusions.
- [ ] Worker: multi-segment runs, `trial_aborted` and `window_spans_detected_gap` exclusions,
      protocol labels — known inputs, expected outputs.

## Timing claims — what we make and what we don't
We record and show: the planned order and intended time of every phase; the app's
presentation callback for the frame that first drew it; the software lateness between the
two; and which EEG sample BrainFlow was writing when the app inserted the marker. We do
**not** claim: when photons left the screen (display latency is not measured), how long
after acquisition a sample reaches the host (radio + USB buffering, bursty by design), or
millisecond onset accuracy. For motor imagery with a 0.5 s window offset, tens of
milliseconds of unmeasured delay don't change what the window contains much; for P300/SSVEP
they would, which is why those stay gated (PRD §6). Every timing surface carries the
one-line caveat above.

## Out of scope
- Live classifier feedback during the run (brief 006).
- More than two classes, rest-as-a-class / idle detection, other paradigms (P300, SSVEP).
- External timing validation (photodiode, trigger box); hardware trigger input.
- Audio cues, custom images, per-trial jitter on fixation or cue.
- Block-randomised or constrained orders (e.g. "no more than 3 in a row").
- A release at the end of this brief: work merges to main and the PM decides on publishing (decision #29).

## Open product questions
1. **What happens to an aborted trial?** — A (marked aborted and excluded; not re-queued, so
   the seeded order stays as planned and the class counts may end up unequal), B (re-queued at
   the end of the run). **Recommendation:** A — the plan stays reproducible from the seed and
   the exclusion is listed; B makes the order depend on when aborts happened.
   → *Answer:*
2. **Disconnect during a run?** — A (abort the current trial, pause, offer Resume after
   reconnect in a new segment), B (end the run). **Recommendation:** A — reconnects are already
   explicit segments (brief 004), and losing a whole run to a bumped dongle is costly.
   → *Answer:*
3. **Which display gets the participant window?** — A (a second display when one is
   connected; with one display, the participant window goes full-screen and the operator uses
   the keyboard shortcuts, then sees the summary after), B (always ask). **Recommendation:** A,
   with a display picker in Start run… that remembers the last choice.
   → *Answer:*
4. **Default runs per session?** — A (4 runs ≈ 21 min of trials: one held out, three for
   training), B (3, the minimum the evaluation accepts), C (6). **Recommendation:** A — three
   training runs give grouped CV at least 3 folds; one held-out run is still a single run, which
   the result already labels.
   → *Answer:*

## Engineering decisions (lead)
- **Contracts** (`Sources/Contracts/Records.swift`): `ProtocolRecord` (protocolID, name,
  version, basedOn, classes [{label, displayName, cue}], phase durations, rest range,
  trialsPerClass, runsPerSession, order `"seeded_shuffle_v1"`, instructions, createdAt,
  contentHash) and `RunPlan`. `TimingSemantics` gains optional `markerRow`. All additive, read
  by older readers as unknown keys or absent files; no format bump.
- **Order**: SplitMix64 seeded with the run seed, Fisher–Yates over the class-balanced list,
  then one uniform draw per trial for rest (`min + u·(max−min)`, rounded to the frame). Run seed
  = session seed + run index, session seed drawn once and stored. Implemented in Swift
  (`ProtocolSchedule`) and mirrored in `worker/src/bciworkspace_worker/protocol_schedule.py`
  for export checks and tests only.
- **Scheduling**: `ProtocolRunner` (new, `Sources/Protocol/`) is an actor driven by an
  injected clock; it schedules phases on `HostMonotonicClock`, never on wall time, and asks the
  participant view to show phase X at time T. The participant view (an `NSView` with
  `displayLink(target:selector:)`, macOS 14+) reports the target presentation timestamp of the
  first frame that drew the phase; that timestamp is on `mach_absolute_time`, which pauses
  during sleep, so it is converted to `CLOCK_MONOTONIC_RAW` by an offset sampled in the same
  callback. The runner then calls `BrainFlowBoard.insertMarker` (from brief 004 PR 1) and
  appends the event.
- **Sample association**: BrainFlow puts the marker on the next sample it writes after the
  call (`brainflow_marker`); the writer looks the marker up in the committed chunk's marker row.
  Fallback `nearest_receipt_timestamp` converts the callback to wall time with a per-chunk
  (monotonic, wall) pair taken at drain, then picks the nearest BrainFlow timestamp. Both are
  software associations; neither is corrected for transport delay.
- **Runs and segments**: each run is a new `runID` and a new segment in the session's
  recording; stopping between runs closes the segment `stopped` while the stream keeps going.
  This loosens "segment = one `start_stream` to stop" to "one contiguous recorded span";
  `docs/data-contracts.md` is updated. Filter warm-up (69 samples ≈ 0.55 s for the 8–30 Hz
  order-4 band-pass at 125 Hz) ends well before the first cue (2 s fixation), so no first-trial
  exclusion is expected.
- **Worker**: `fit_evaluate` groups segments by run instead of requiring one segment per run;
  `project_io` passes detected gaps and abort events to `epoch_segments` for the two new
  exclusion reasons. `fit_evaluate_project` already takes `labels`; the Swift side
  (`ProjectSession` → `EvaluationRunner.Request.leftLabel/rightLabel`) reads them from the
  recording's protocol instead of the worker defaults. Protocol stays v1 (additive).
- **Not verifiable without the board**: marker landing on real Daisy packets (marker only on
  the board half or both?), real software lateness with the board streaming, two-display
  behaviour on the PM's setup. Covered by the appendix.

### PR sequence (after this docs PR and brief 004 PRs 1–3; each ≤ ~400 changed lines)
1. **Swift contracts + store** — `ProtocolRecord`, `RunPlan`, `markerRow`, `protocols/`
   storage (create version, list, used-in count), `ProtocolSchedule` + golden vectors.
2. **Worker** — multi-segment runs, `trial_aborted` / `window_spans_detected_gap`,
   `protocol_schedule.py` golden-vector mirror, tests.
3. **Swift service** — `ProtocolRunner` (phases, pause/resume, aborts, disconnect pause), event
   writing, marker insertion and association; fake-clock and synthetic-board tests.
4. **Swift screens** — Protocols section: list, detail, "New version…" editor with validation
   copy; screen models carry all copy.
5. **Swift screens** — participant cue window with display-link presentation callbacks;
   reachable only behind a Debug flag (`-BCICueWindowPreview`) until PR 6.
6. **Swift screens** — Start run… + operator panel on the acquisition screen; timing summary;
   Evaluate uses protocol labels and the run-count message; flag removed.
7. **Swift service** — export of protocols and run plans (`Export.swift`) + test.
8. **Docs** — `docs/data-contracts.md` (protocols, run plans, segment wording, marker row,
   exclusion reasons), `docs/export-format.md`, README, brief status. Then the PM runs the
   appendix checklist.

## Risks / what could go wrong for users
- A user treats software presentation times as display onset. Every timing surface says it
  isn't, and `timingUncertaintyNanos` stays null.
- One display: the participant window covers the operator panel; aborts work by keyboard only
  and the operator sees the summary afterwards.
- A user with a good offline result on their first session may still fail live (brief 006);
  the protocol makes the data honest, not the decoding easier.
- Marker insertion could fail on some BrainFlow paths; the fallback association is named, so
  a mixed recording is visible.

## Appendix — hand-run checklist on the real Cyton+Daisy (PM, decision #26)
Needs brief 004's checklist passed first. Record date, Mac, displays, app commit, firmware.

| # | Step | Pass when |
|---|---|---|
| P1 | Two displays: Start run… with the default protocol, participant window on the second display. | Instructions, then fixation / arrow / blank in order; operator window keeps focus; Esc and ⌘. work. |
| P2 | Complete one full default run (40 trials, ~5½ min). | 40 trials, events in `events.jsonl`, every phase event has `presentedAt` and a `brainflow_marker` association; timing summary p95 lateness < 1 frame. |
| P3 | Abort one trial, pause and resume, then finish. | `trial_abort`, `pause`, `resume` events; aborted trial listed as excluded on evaluation. |
| P4 | Pull the dongle mid-trial, replug, Resume. | Trial aborted with reason `disconnect`; run continues in a new segment. |
| P5 | Run 4 runs, then Evaluate. | Evaluation runs with `cue_left_hand` / `cue_right_hand`, 1 held-out run, `same-session` evidence; result shows whatever accuracy it is (no target). |
| P6 | One display only: run 2 trials. | Participant window full-screen; Esc aborts; summary visible after. |
| P7 | Export the result. | Export folder holds `protocol.json` and the run plans; seeds reproduce the order (`worker` mirror). |
