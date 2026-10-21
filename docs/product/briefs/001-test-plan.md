# 001 — acceptance test plan (from the tester agent, 2026-10-20)

Fixtures: **F1** `tiny.bciproj` (EEGMMIDB-derived, 8 ch, ~6 trials/class, built by a dev script using mne; the full S001 example is used in one slow test + manual steps) · **F2** `FakeWorker` Python script (exits mid-request, or emits progress then hangs, by env var) · **F3** per-test temp dir.

| # | Criterion | How | Test / assertion |
|---|---|---|---|
| 1 | Welcome actions, hardware disabled | unit on `WelcomeModel` + manual | `testWelcomeActions_hardwareDisabledWithReason`: actions = [open, example, hardware]; hardware disabled with non-empty phase-2 explanation |
| 2 | Example creates project from bundle only | XCTest integration | `testExploreExample_createsValidProjectFromBundle`: project.json decodes, format version matches, one recording, every chunk SHA-256 verifies; bundle injection point explicit; manual run with Wi-Fi off |
| 3 | Sidebar sections | unit + manual | `testSidebarSections_orderAndPlaceholders` |
| 4 | Recording detail shows stored metadata | unit on view model | `testRecordingDetail_showsDeclaredMetadataOnly`; `testChannelLabels_notInferredFromCount` (arbitrary labels pass through; `montage == "unspecified"`) |
| 5 | Evaluate with progress, complete result | integration via real worker + pytest | `testEvaluate_emitsMonotonicProgressThenResult`; `testResult_containsAllRequiredFields` (CI lo<acc<hi, confusion sum = n_test, grouping == run, evidence, warning); `test_no_group_leaks_between_train_and_test`; `test_csp_matches_mne` |
| 6 | Determinism / new seed | pytest + integration | `test_same_seed_byte_identical_evaluation_json` (separate subprocesses, varied PYTHONHASHSEED, sort_keys, sha256 equal); `test_different_seed_differs`; `test_thread_count_invariant` (OMP 1 vs 4); Swift `testRerunSameSeed_storesReproductionLinkedToOriginal`; `testNewSeed_addsSecondResultAndBothListed` |
| 7 | Export readable outside app | integration + pytest | `testExport_layoutAndHashes` (samples.f64 + header, events.jsonl, channels.json, pipeline.json, model.npz, evaluation.json byte-equal, attribution); `test_export_readable_with_numpy_only` runs the docs one-liner (regex-extracted from docs) in a numpy-only venv with `python -I`; `np.load(allow_pickle=False)` |
| 8 | Force-quit survival | deterministic crash injection | `CommitHook` seam + helper process, `CRASH_AT=<point>:<n>` → `_exit(9)`: `testCrashAtEachCommitPoint_reopenIsConsistent` (parameterized); `testKillDuringEvaluation_keepsCompletedResults` (results written to `results/.tmp-<uuid>` then renamed); `testCorruptChunk_reportedNotRepaired`; `testIndexSqliteDeleted_rebuilds`; manual: force-quit from Activity Monitor mid-evaluate |
| 9 | Worker death → unavailable + retry | integration with F2 + manual | `testWorkerExitDuringEvaluate_surfacesUnavailableAndRetrySucceeds`; `testRecordingStillOpensWhileWorkerDown`; manual `kill -9` of worker pid |
| 10 | Attribution shown + exported | unit + export test | `testExampleInfo_includesAttribution` ("Schalk", "Goldberger", "ODC-BY" from manifest, not hard-coded); `testExport_containsAttributionFile` |

Not PR-testable: "under 15 minutes without a terminal" (PRD gate 2, five testers). Gaps to schedule: disk-full injection, signing smoke test (separate track), slow-tagged full-S001 timing budget, accessibility pass.
