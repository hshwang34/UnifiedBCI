# 001 — Replay to report: reproduce a motor-imagery result with no hardware

**Status:** building (PR #1 foundations merged; PR #2 data path merged; PR 3 screens building) · **Owner:** PM · **PR:** #1, #2 merged · **Updated:** 2026-10-22

## Problem
A developer who wants to know "does my CSP/LDA experiment actually work?" today assembles
loaders, event tables, cross-validation, and plots by hand in a notebook, and the result is
hard to trust or repeat (PRD §3: header mismatches blocking import, tutorials with shape
errors, promising public-dataset results that do not transfer). Phase 0 proved the app can
link BrainFlow and run a leakage-safe pipeline in a bundled worker, but there is nothing a
user can open yet.

## Who it's for
A Mac-using student/independent BCI developer, at the moment they install the app for the
first time — before any hardware is connected. Also the owner, replaying their own future
recordings.

## What success looks like
- From a clean install, a new user opens the bundled example and reaches a reproducible
  evaluation (balanced accuracy with uncertainty, confusion matrix, baseline comparison,
  split policy) in under 15 minutes without a terminal (PRD gate "Basic usability").
- Running the same evaluation twice gives byte-identical results; the evidence can be
  exported and read outside the app.
- The user can tell at a glance what the data is (public dataset, not their device), how it
  was split, and what would make the number misleading.

## Acceptance criteria
- [x] Welcome window offers **Open project**, **Explore an example**, **Connect hardware**
      (the last is present but disabled with an explanation until phase 2).
- [x] "Explore an example" creates a project on disk from the bundled recording and opens it;
      creation reads only from the app bundle (no network code on that path), no terminal, no hardware.
- [x] Project window: sidebar with Recordings · Protocols · Pipelines · Results · Live Test
      (Protocols/Live Test present but empty with "coming in phase 2/3" copy).
- [x] Recording detail shows source (dataset, subject, runs, license/citation), channel map
      with declared labels and units, sample rate, segment list (one per run), and the event
      table (cue label, onset, run). Labels and units are displayed exactly as stored; a recording
      without declared labels shows "undeclared", never a 10-20 guess.
- [x] "Evaluate" runs the reference CSP+rLDA and the log-variance baseline in the worker with a
      determinate progress indicator updated at least once per stage (fit, CV, holdout); the result view shows balanced accuracy, accuracy with a 95 % trial-level
      interval, confusion matrix, class counts per split, grouped-by-run split policy, seed,
      exclusions, evidence type (same-session), and the dataset warning.
- [x] Re-running with the same recording, pipeline config and seed produces a byte-identical
      `evaluation.json` (same machine, same bundled worker) and is stored as a *reproduction*
      linked to the original; changing the seed creates a new result record. All remain listed.
- [x] Export writes a folder with samples (documented binary), `events.jsonl`, channel map,
      pipeline config, model arrays (`.npz`), and `evaluation.json`; a Python one-liner in the
      docs reads it without the app.
- [x] Project directory survives force-quit mid-evaluation: reopening shows the recording and
      any completed results; nothing corrupted.
- [x] Worker death during evaluation shows an explicit "analysis unavailable" state with a
      retry; the recording stays usable.
- [x] Attribution for the bundled dataset (PhysioNet / Schalk 2004 / Goldberger 2000, ODC-BY)
      is shown in the example's info panel and in the export.

## Out of scope
Live acquisition, cue protocol, signal-quality inspection view (brief 002), external-format
import, LSL, idle/abstention policy, signing/notarization (separate fast-lane track),
band-power recipe, any claim about the user's own motor imagery.

## Open product questions
1. **Which bundled example?** — Options: A (PhysioNet EEGMMIDB subject S001, imagery runs
   4/8/12, cropped to 16 sensorimotor channels, ~22 trials per class, ~7 MB, labeled honestly
   with wide uncertainty), B (two subjects pooled, ~44/class, subject becomes the CV group;
   ~15 MB), C (synthetic only for now). **Recommendation:** A — smallest honest example;
   the UI must show the uncertainty anyway, and a wide interval on a real recording teaches
   the right lesson.
   → *Answer:* A — EEGMMIDB S001, runs 4/8/12, 16 channels, ~22 trials/class, honest uncertainty (DECISIONS #4).
2. **Intel Macs?** — Options: A (Apple Silicon only for v0.x; the bundled Python is per-arch
   and the owner's Mac is arm64), B (universal: ship two workers, ~2× bundle). **Recommendation:**
   A — PRD says support the owner's Mac first, publish an honest support matrix later.
   → *Answer:* A — Apple Silicon only for v0.x (DECISIONS #5).
3. **Phase 1 split** — Options: A (this brief = store + example + evaluate + export; signal
   inspection becomes brief 002 right after), B (include PSD/clipping/flatline inspection
   here; bigger PR). **Recommendation:** A — evaluation is the promise; inspection deserves
   its own acceptance criteria about named quality rules.
   → *Answer:* A — inspection view is brief 002 (DECISIONS #6).
4. **Example on first launch** — Options: A (welcome window with three choices, nothing
   auto-opens), B (auto-open the example project the first time). **Recommendation:** A —
   matches PRD §4 and keeps "Connect hardware" visible as the second entry point.
   → *Answer:* A — welcome window, nothing auto-opens (DECISIONS #7).

## Engineering decisions (filled in by the lead while building)
- Research done before building (2026-10-20): packaging/signing, BrainFlow Cyton+Daisy
  semantics, dataset, adversarial code review. Corrections folded in; see below and
  `docs/phase-0-results.md` revisions.
- **Drop MNE from the shipped worker; keep it as a dev/test dependency.** Port CSP
  (~50 lines, generalized eigenvalue with Ledoit-Wolf shrinkage) and validate against
  `mne.decoding.CSP` in tests. Saves ~70 MB (mne + matplotlib + PIL + fontTools) and removes
  a hard matplotlib dependency from a headless worker. EDF reading for the one-time dataset
  conversion also happens at dev time, not in the app.
- **Trim BrainFlow in the worker to darwin/arm64 libs** (87 MB → ~10 MB); the worker never
  opens a board, it only needs the package importable for version parity.
- **Sequence accounting for Cyton+Daisy is +2 mod 256**, not +1 (BrainFlow commits one
  output sample per Daisy/Cyton packet pair and writes the even packet's counter). Delta 0
  = stale half-sample; other deltas = gap. Contracts updated to say so; the synthetic board
  stays +1.
- **BrainFlow receipt timestamps are `gettimeofday` wall clock, not monotonic.** Contract
  renamed accordingly; backward steps logged as `clock_anomaly`; the app records its own
  monotonic drain time.
- **Ring-buffer overflow is silent (drops oldest).** Drain loop emits `overflow_suspected`
  when `count ≥ bufferSize − margin`.
- Signing plan (fast-lane track, not this brief): sign every Mach-O in the worker with the
  personal Team ID, `--options runtime --timestamp`, no `--deep`; hardened runtime on; no
  entitlements unless the smoke test crashes; notarize + staple. Location under `Resources/`
  is fine — my earlier "must move to Frameworks" note was wrong.

- PR 1 (foundations) engineering decisions by the writer, 2026-10-20:
  - Worker API takes continuous `Segment`s (`run_id`, optional `session_id`, events as
    `(sample_index, label, trial_id)`); the band-pass has no fitted parameters, so it runs once
    per segment before the split — exactly the online path — then epochs; warm-up (0.55 s from
    the slowest pole) exclusions are listed.
  - Split is frozen by `split_manifest`; with a supplied manifest the seed only affects the
    bootstrap draws.
  - Dev venv launches Python with `-I`; bundled with `-s -P` + explicit PYTHONPATH; both
    `-u -B -X utf8`. BLAS single-threaded by default (`BCI_WORKER_THREADS` override) so repeats
    are byte-identical.
  - Result bytes pass through the client verbatim (no re-encoding) so `evaluation.json` can be
    stored byte-for-byte.
  - BrainFlow log level `warn`; remaining darwin BrainFlow dylibs (33 MB) kept in the worker
    bundle until trimming has its own smoke test. Bundle 358 MB → 157 MB.
- Test plan: `001-test-plan.md`. Design requirements it imposes: `evaluation.json` contains
  no wall-clock/UUID/duration fields (those go to `result.meta.json`) so byte-identity is
  testable; the project store exposes a `CommitHook` seam (afterTmpWrite / afterFsync /
  afterRename / afterManifestAppend) so crash tests kill a helper process at a named point
  instead of sleeping; export concatenates chunks per segment into `samples.f64` + header so
  a numpy one-liner (extracted from the docs by the test itself) reads it.
- Same-seed rerun: we *do* re-run (that is the reproducibility evidence the PRD wants), verify
  byte-identity, and store it as a reproduction record pointing at the original.
- "Under 15 minutes without a terminal" is PRD gate 2 (five testers); not ticked from a PR.

- PR 2 (data path) gate, 2026-10-22: reviewer found one blocker (worker trusted `recording.json`:
  path escape, FIFO hang, silent negative-row wraparound) plus eight durability/race issues; two fix
  rounds + one security-review fix. Decisions: worker validates manifests with the same rules as Swift
  and reports `integrity`, never `internal`; cancel means nothing saved, and is a no-op once storing
  starts; 120 s progress-silence watchdog → "analysis unavailable"; open-sweep spares locked or
  < 10 min old staging dirs (PR 3 also allows one window per project); export refuses any symlinked
  path component. Debug builds signed with the personal Apple Development identity (team V56DG94ZL5)
  so macOS keeps the Documents grant across rebuilds. No CI in the repo; gate run locally.

## Risks / what could go wrong for users
- ~22 trials per class gives a ±15-point interval; a user could read 70 % as "it works".
  Mitigation: interval shown beside every accuracy, "evidence: same-session, one subject"
  label, and the PRD's "what would make this misleading" panel.
- A bundled public recording is not Cyton data; a user might expect their device to behave
  the same. Mitigation: source panel says so in the first line.
- 150–200 MB download because of the bundled scientific stack. Acceptable for a developer
  tool; documented.

## Resume 2026-10-21
- **PR #1 merged** (foundations). **PR 2 (data path) is code-complete** on branch `feature-replay-data`
  (pushed, 5 commits `8628060..f3a9885`, worktree `.claude/worktrees/feature-replay-data`), check green
  in the lead's hands (52 pytest + 3 skipped, 59 XCTest, 0 warnings). Real S001 numbers, seed 0, untuned:
  reference BA 0.625 (acc 0.60, CI 0.32–0.84, n = 15, holdout run S001R12), baseline BA 0.536;
  evidence `unknown-session` (PhysioNet does not define sessions). Bundled example 7.5 MB.
- **Gate for PR 2 was started, not finished:** a tester and a fresh reviewer were launched at the pause
  and stopped; their reports, if any arrived, are in the session transcript only. **Single next step:**
  re-run the PR 2 gate (tester probes per `001-test-plan.md` + fresh reviewer on `git diff main...feature-replay-data`),
  fix round if needed, open PR 2 with the PM-facing body, then start PR 3 (screens) from `001-ui-spec.md`
  stacked on PR 2 if unmerged.
- Writer deviations to carry into PR 3 copy: evidence reads `unknown-session`, not `same-session`;
  `.failed(reason)` state exists beside `analysisUnavailable`; reproduction stores `reproductionOf` or
  `divergedFrom`; `fitted.npz` holds both models.
- Out of scope until the PM picks them up: signing/notarization, clean-machine launch, live Cyton+Daisy smoke.
