# 006 — Frozen model, replay parity, and live feedback

**Status:** shipped (code) — awaiting PM hardware checklist · **Owner:** PM · **PR:** #40, #42, #43, #44, #45, #46, #47, #48, #49, #50, #51 · **Updated:** 2026-11-21

## Problem
The app can evaluate a recording offline and stores the fitted arrays of every evaluation
(`pipelines/<uuid>/fitted.npz`), but nothing can use them afterwards. There is no way to
check that the transforms a live system would run give the same answers as the offline
evaluation, and no way to run the model during a session and see feedback. The worker has
the pieces in isolation — `CausalFilterState` (the streaming band-pass, tested against
`filter_segment`) and `predict_from_arrays` (class only, no score) — but no streaming
windowing, no validity rules, no inference method and no live data path. PRD §5 makes this
P0 twice: "Replay through the same streaming transforms used online — recorded chunks
produce matching features/predictions within declared numerical tolerances, including
startup and discontinuity behavior", and "Provide cued in-app live feedback — abstention,
invalid input, stale data, and disconnection are explicit states. Predictions and displayed
feedback are logged separately." Phase 3's exit is "demonstrate the complete loop with
measured limitations".

## Who it's for
The developer who has recorded and evaluated a session (briefs 004–005) and now wants to
(1) confirm the model behaves the same when fed chunk by chunk, then (2) run a new cued
session with feedback, and (3) see honestly how that fresh session went.

## What success looks like
- From a result, **Freeze for live use…** turns its fitted model into a named, frozen model
  that says what it expects (channels, rate, window) and where its evidence came from.
- **Replay** runs any compatible recording through the frozen model chunk by chunk and shows
  "Streaming matches offline within tolerance" — or exactly where and by how much it doesn't.
- In a live cued run, the participant sees a bar grow left or right from the centre with the
  classifier's confidence (decision #27); whenever the app can't give a valid, confident
  prediction the bar disappears and the state is named in words.
- Afterwards, Results shows the live run as fresh-session evidence next to the offline
  result it came from: per-trial balanced accuracy with its interval, abstentions, invalid
  windows, and measured software latency — including when it's bad.

## Acceptance criteria
Freeze
- [ ] A result's detail has **Freeze for live use…**. The sheet names the model it freezes
      (Q1), its training runs and session, expected channel ids in order, rate, band-pass,
      window (offset, length), class labels, and "Feedback can show for X s of each cue" (from
      the window and the protocol's cue length, Q3).
- [ ] Freezing writes `models/<uuid>/model.json` (`ModelRecord`): modelID, name, source
      pipelineID and resultID, recipe, expected channel ids / rate, window, warm-up samples,
      class labels in LDA class order, SHA-256 of `fitted.npz`, configHash, worker versions,
      frozenAt. The arrays stay in the immutable pipeline directory and are referenced by hash.
- [ ] The worker validates the arrays before a model is frozen or used: loaded with
      `allow_pickle=False`, only the documented keys, float64 (labels int, `feature_kind` str),
      shapes consistent with the channel count; anything else is refused with the reason.
      A hash mismatch at load time refuses the model ("model file changed since it was frozen").
- [ ] Pipelines section lists frozen models with name, source result and "used in n live runs".

Replay parity
- [ ] **Replay…** on a model + recording (same channel ids, order and rate, else
      `channel_mismatch` refusal naming the difference; never reordered or resampled) runs the
      streaming path over the committed chunks and the offline reference side by side.
- [ ] The streaming path re-chunks the recording at several sizes (1, 7, 13, 125 samples and a
      seeded random mix) and every chunking must give the same results within tolerance.
- [ ] Declared tolerances (float64, both paths in the worker), shown on the parity view:
      band-passed samples ≤ 1 × 10⁻⁸ µV absolute; features ≤ 1 × 10⁻⁹; LDA score ≤ 1 × 10⁻⁸;
      validity identical for every window; decision (class / abstain) identical except windows
      whose offline score is within 1 × 10⁻⁶ of the decision boundary or whose confidence is
      within 1 × 10⁻⁹ of the threshold — counted and listed as "on the boundary", not hidden.
- [ ] Startup: windows are due every hop (16 samples = 128 ms at 125 Hz) from segment start; a
      window is `insufficient_window` until it is full **and** starts at or after the filter
      warm-up (`settling_samples`, the same rule as the offline `window_starts_before_filter_warmup`
      exclusion). Both paths agree on the first valid window, tested.
- [ ] Discontinuity: a new segment resets filter state and the window buffer
      (`reset_on_segment_start`), so the next valid window is warm-up + window length later. A
      window containing a detected gap (`sequence_skip`, `stale_half`, `invalid_counter`,
      `overflow_suspected`) is `insufficient_window` with detail `window_spans_detected_gap`
      (same rule as brief 005's exclusion). Tested with injected gaps and multi-segment runs.
- [ ] The parity view reports: windows compared, max deviation per quantity vs its tolerance,
      boundary windows, first valid window per segment, and pass/fail. A replay is stored
      (`live/<uuid>/` with kind `replay`) with its predictions, so it can be reopened.

Live feedback
- [ ] **Live Test** sidebar section (placeholder today): pick a frozen model and a protocol
      version, see the abstention threshold and feedback span, then **Start live run**, which
      starts a brief 005 run with feedback on. Start is refused, before anything runs, when the
      connected recording's channel ids/order or rate don't match the model
      (`channel_mismatch`, one record logged) or the model fails validation.
- [ ] Feedback bar (decision #27) in the participant window: horizontal, centred under the
      fixation cross, grows toward the predicted class's side; length = (confidence − 0.5) / 0.5
      of the half-width. Confidence = the LDA posterior of the predicted class, max(σ(s), 1 − σ(s))
      for score s. It is labelled to the operator as "classifier confidence", never as
      probability of intent.
- [ ] The bar is shown only during the feedback span of each cue (Q3) and only for a `valid`,
      non-abstained prediction. Otherwise it is hidden and one line of words is shown instead:
      abstain "Model unsure" (shipped wording; drafted as "Not confident"), `insufficient_window` "Waiting for enough signal",
      `stale` "Signal delayed", `disconnected` "Board disconnected", `worker_unavailable`
      "Analysis stopped". The operator panel shows the same state plus the raw score.
- [ ] Abstention: a valid prediction with confidence below the threshold (default 0.6, Q2) is
      `action: abstain`. The threshold is stored with the live run.
- [ ] Validity rules: `stale` when the prediction for a window reaches the app more than
      250 ms after the window's last sample was drained, or no sample has been drained for
      250 ms; `disconnected` from brief 004's interrupted/failed states (feedback is
      invalidated immediately, PRD §7); `worker_unavailable` when the inference worker exits or
      doesn't answer within 1 s — acquisition and recording continue, with a visible warning.
- [ ] Predictions and displayed feedback are logged separately (PRD §5):
      `live/<uuid>/predictions.jsonl` — one `PredictionRecord` per due window, every validity
      included, with input sample range, score, validity (+ detail), action,
      `emittedAtMonotonicNanos`; and `live/<uuid>/feedback.jsonl` — what the participant was
      shown (bar side and length, or hidden + the words) and the presentation-callback time of
      the frame that first showed it, keyed by prediction sequence number.
- [ ] Latency: per prediction the app stores acquisition receipt (drain time of the chunk
      holding the window's last sample), worker compute time, and emission; per feedback frame
      its presentation callback. The live summary reports receipt → emission p50 / p95 / max
      (PRD §8 initial target p95 < 100 ms after the window is available), separately from window
      length, BrainFlow buffer wait (BrainFlow receipt → drain) and emission → presentation. It
      says plainly that radio/USB transport and display delay are not measured.
- [ ] During a live run Evaluate and Replay are disabled ("Paused during a live run") so
      training never competes with inference (PRD §7).

Fresh-session evidence
- [ ] Per trial, the live outcome is the prediction for the cue-locked window that matches the
      model's training window (Q4). Results shows the live run as a result card: balanced
      accuracy and accuracy with a 95 % Clopper-Pearson interval over trials (decision #8
      wording), confusion matrix, abstained trials, invalid trials and why, n trials / runs,
      and the larger-class rate marker (decision #12).
- [ ] Evidence label from stored session ids: `cross-session` when the live session differs
      from every training session of the model, `same-session` otherwise, `unknown-session`
      if any is null. The card links to the offline result it came from.
- [ ] After the run the app replays the new recording through the frozen model and compares
      with what was logged live: "Live matched replay: n of n windows within tolerance", or the
      differing windows listed (a mismatch here is a bug report, not a result).
- [ ] Nothing in Results calls a live run "working" or "successful"; a chance-level result is
      shown the same way as a good one.

Tests
- [ ] Worker: streaming vs offline across chunkings, startup, segment reset, in-window gaps,
      boundary cases; score/confidence from arrays agree with the sklearn objects; array
      validation refuses pickles, extra keys, wrong dtypes and shapes.
- [ ] Swift: `LiveInferenceRunner` on the synthetic and playback boards with a fake clock —
      each validity state is reached and logged (stall the source → `stale`, interrupt →
      `disconnected`, kill the worker → `worker_unavailable`, wrong channel map →
      `channel_mismatch` refusal).
- [ ] Swift: `FeedbackPolicy` — bar shown only for valid, confident predictions inside the span.
- [ ] End-to-end on the synthetic board with the playback fixture's class-dependent signal:
      record → evaluate → freeze → live run → result card with cross-session evidence and a
      passing live-vs-replay check. Latency numbers are reported in the test log, not gated in CI
      (shared runners are noisy); the p95 target is checked on the PM's Mac (appendix).

## Out of scope
- Smoothing or dwell over several predictions; continuous control; external actions or
  outputs (LSL, keystrokes). The bar is in-app feedback only.
- Idle / "no intent" detection — a two-class classifier doesn't detect it, and abstention is a
  policy (PRD §6); collecting idle data is a later brief.
- Adaptive or co-adaptive retraining during or between live runs.
- A Swift (or Core ML) inference engine; inference stays in the worker (PRD §7).
- Editing the abstention threshold per trial; more than two classes.
- A release at the end of this brief: work merges to main and the PM decides on publishing (decision #29).

## Open product questions
1. **Which fit does "Freeze" freeze?** — A (the evaluation's fit on its training runs only —
   the exact model whose held-out score is on screen), B (a new fit on all runs of the
   recording, more data but no held-out evidence of its own). **Recommendation:** A — the
   frozen model's evidence is the result it came from; B can follow as an explicit "Refit on
   all runs" that is labelled as having no held-out score.
   → *Answer:* A — the evaluation's fit on its training runs (PM, 2026-11-20; decision #38)
2. **Default abstention threshold?** — A (0.6 confidence), B (0.7), C (none: always show the
   bar when valid). **Recommendation:** A — hides near-coin-flip outputs without hiding most
   predictions of a modest model; editable per live run and stored. C makes every output look
   like a decision.
   → *Answer:* A — 0.6, editable per live run and stored (PM, 2026-11-20; decision #39)
3. **When does the bar show during a trial?** — A (only for windows lying wholly inside the
   imagery period, i.e. from cue + offset + window length to cue end — with a 0.5 s offset and a
   2 s window that is the last 1.5 s of the 4 s cue; a model trained on the 3.5 s default window
   would show feedback only at the very end), B (continuously through the cue, with early windows
   that still contain fixation data), C (one decision at cue end). **Recommendation:** A, and the
   Freeze sheet suggests evaluating with a 2 s window for feedback use; B shows feedback driven
   by pre-cue data.
   → *Answer:* A — only windows wholly inside the imagery period; Freeze sheet suggests a 2 s window (PM, 2026-11-20; decision #40)
4. **What is the live per-trial outcome?** — A (the one cue-locked window that matches the
   training window, so live and offline numbers measure the same thing; time-on-correct-side
   shown as a secondary figure), B (fraction of feedback frames on the correct side as the
   headline). **Recommendation:** A — comparable to the offline held-out score and has an
   honest trial-level interval; B counts correlated windows as if independent.
   → *Answer:* A — the cue-locked window matching the training window; time on the correct side secondary (PM, 2026-11-20; decision #41)

## Engineering decisions (lead)
- **Worker streaming engine** (`worker/src/bciworkspace_worker/streaming.py`):
  `StreamingPredictor(arrays, n_channels, sfreq, window, hop, warmup)` owns a
  `CausalFilterState`, a ring buffer of the window length, gap and segment bookkeeping, and
  emits `(window_end_sample, score, confidence, validity, detail)` every hop. `score_from_arrays`
  joins `predict_from_arrays` (same einsum/log-power/LDA arrays, returns the decision value);
  the offline reference cuts the same windows from `filter_segment` output. Tolerance constants
  live in one place and are echoed into every parity report.
- **Confidence is not calibrated**: the worker's `confidence` is the shrinkage-LDA posterior
  of the predicted class, σ(|s|) for decision value s, so it is always ≥ 0.5. No calibration
  step is fitted, and its scale comes from the LDA's equal-covariance Gaussian model. The UI
  calls it "model confidence", never a probability of intent (worker `protocol.py` docstring).
- **Model validation** (`pipeline.validate_model_arrays`): explicit key list per `feature_kind`;
  the baseline's `baseline__*` arrays can be frozen too, as a separate model.
- **Protocol** (still v1, additive; `hello` lists the methods): `replay_recording` (references
  the recording by id like evaluation; writes predictions to an app-supplied staging path, never
  over the pipe) and `live_open` / `live_push` / `live_close`. `live_push` is the one place
  samples cross the pipe: the window's channel rows only, base64 little-endian float64, one
  drained chunk per call (~50 ms, ~6 samples × 16 channels ≈ 1 KB) — bounded and small, so the
  "large data never crosses the pipe" rule holds; the `protocol.py` docstring and
  `WorkerClient.swift` say so.
- **Separate inference worker**: `LiveInferenceRunner` (new, `Sources/Evaluation/`) starts its
  own `WorkerClient` process so a long fit can never block a prediction; it consumes the
  `AcquisitionSession` fan-out (brief 004) as a fourth consumer with a newest-wins policy — a
  late prediction is marked `stale`, never queued behind others. Validity, abstention and the
  bar's shown/hidden state are decided in Swift (`FeedbackPolicy`, pure, unit-tested); the
  worker only computes scores.
- **Contracts** (`Records.swift`): `ModelRecord`, `LiveRunRecord` (kind `live` | `replay`,
  modelID, recordingID, runIDs, hop, threshold, stale limit, summary, latency summary, replay
  check), `FeedbackRecord`; `PredictionRecord` gains optional `sequence`, `validityDetail`,
  `acquisitionReceiptMonotonicNanos`, `workerComputeNanos`. In live logs
  `feedbackPresentedAtMonotonicNanos` stays null on the prediction and the presentation time
  lives in `feedback.jsonl` (append-only files are never rewritten). New top-level `models/` and
  `live/` directories are ignored by older readers, and `results/` is untouched, so no format
  bump (data-contracts and export docs updated).
- **Latency clocks**: everything on `HostMonotonicClock`; display-link timestamps converted as in
  brief 005; BrainFlow buffer wait uses the per-chunk (monotonic, wall) pair, since BrainFlow
  timestamps are wall clock.
- **Can start now**: PRs 1–5 need only recorded data (bundled example, tiny fixture) and don't
  wait for briefs 004–005; PRs 6–8 need their acquisition and protocol services.
- **Not verifiable without the board** (decision #26): real-board latency on the PM's Mac, how
  often radio bursts trip the 250 ms stale rule, and live feedback on a real participant. The
  appendix covers them; nothing in the app or README reports a hardware latency until then.

### PR sequence (after this docs PR; each ≤ ~400 changed lines, each leaves main working)
1. **Worker** — `streaming.py` (`StreamingPredictor`, offline reference), `score_from_arrays`,
   tolerance constants; parity tests over chunkings, startup, segment reset, gaps.
2. **Worker** — `validate_model_arrays`, `replay_recording`, `live_open/push/close`, protocol
   docstring; tests incl. hostile `.npz` files.
3. **Swift contracts + store** — `ModelRecord`, `LiveRunRecord`, `FeedbackRecord`, new
   `PredictionRecord` fields; `ProjectStore.freeze(pipeline:)`, `models/` and `live/` storage,
   append-only writers; tests.
4. **Swift service** — `ReplayRunner` + `WorkerClient` wrappers; screen models for freeze and
   parity copy; tests on the tiny fixture.
5. **Swift screens** — Freeze for live use… sheet, frozen models in Pipelines, Replay… and the
   parity view.
6. **Swift service** — `LiveInferenceRunner` (own worker, validity state machine, latency stamps,
   logging) and `FeedbackPolicy`; synthetic/playback tests, killed-worker test.
7. **Swift screens** — feedback bar in the participant window and the Live Test operator view;
   reachable only behind a Debug flag (`-BCILiveFeedbackPreview`) until PR 8 (removed there).
8. **Swift screens** — Live Test setup and Start live run, Results live-run card with
   fresh-session evidence, latency summary and live-vs-replay check; flag removed.
9. **Swift service** — export of models and live runs (`Export.swift`, `docs/export-format.md`
   entries) + test.
10. **Docs** — `docs/data-contracts.md` (models/, live/, feedback.jsonl, prediction fields, live
    protocol methods and the bounded in-band samples), README, brief status. Then the PM runs
    the appendix checklist.

## Risks / what could go wrong for users
- A user reads the bar as "the system reads my mind". The operator copy calls it classifier
  confidence; the bar can't express "no intent", and the Results card states the trial count
  and interval.
- A model that does well offline may do poorly live (new session, feedback changes behaviour).
  That is a legitimate result and is shown as one (PRD §6: a negative result is legitimate).
- Feedback windows from a 3.5 s-window model barely fit the cue (Q3); the Freeze sheet says how
  long feedback will show before the user starts.
- Radio bursts could make many predictions `stale` at 250 ms; the live summary shows the stale
  share so the limit can be revisited with data.
- Two worker processes plus acquisition on a 16 GB Mac; evaluation is paused during live runs.

## Appendix — hand-run checklist on the real Cyton+Daisy (PM, decision #26)
Needs briefs 004 and 005 checklists passed. Record date, Mac, app commit, firmware, model used.

| # | Step | Pass when |
|---|---|---|
| L1 | Evaluate a 4-run session (brief 005 P5) with a 2 s window; Freeze for live use. | Model listed; sheet shows channels, window, "feedback can show for 1.5 s of each cue". |
| L2 | Replay that model over the same recording. | Parity pass; boundary windows (if any) listed. |
| L3 | New sitting (cap re-applied): Start live run with the default protocol. | Bar appears only in the feedback span; hidden with words otherwise; operator panel shows state and score. |
| L4 | During the run, pull the dongle for ~5 s. | Bar hides immediately, "Board disconnected"; after reconnect "Waiting for enough signal" until a full window past warm-up. |
| L5 | During a run, `kill` the inference worker (Activity Monitor). | "Analysis stopped"; recording continues; run can finish. |
| L6 | Finish the run, open Results. | Live card with `cross-session`, trial-level interval, abstained/invalid counts; live matched replay n of n; latency p50/p95/max listed — note p95 against the 100 ms target, pass or not. |
| L7 | Export the live run. | Folder holds model.json, predictions.jsonl, feedback.jsonl, readable outside the app. |
