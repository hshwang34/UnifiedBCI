import json

import numpy as np
import pytest

from bciworkspace_worker import pipeline

SFREQ = 125.0


def small_runs(**kw):
    defaults = dict(n_runs=4, trials_per_run=12, n_channels=8, sfreq=SFREQ, seed=0)
    defaults.update(kw)
    return pipeline.make_synthetic_runs(**defaults)


# --- synthetic data ---------------------------------------------------------------------


def test_synthetic_runs_are_continuous_with_events_at_known_samples():
    segs = small_runs(n_runs=3, trials_per_run=5)
    assert [s.run_id for s in segs] == ["run00", "run01", "run02"]
    for s in segs:
        assert s.data.shape[0] == 8 and s.data.dtype == np.float64
        assert len(s.events) == 5
        onsets = [e[0] for e in s.events]
        assert onsets == sorted(onsets) and onsets[0] >= 3 * SFREQ
        assert all(0 <= e[0] < s.data.shape[1] for e in s.events)
        assert {e[1] for e in s.events} <= {0, 1}
        assert len({e[2] for e in s.events}) == 5


# --- filter-state parity (train/serve) ------------------------------------------------------


def test_segment_filter_then_epoch_equals_streaming_filter_then_epoch():
    """Offline path: filter the whole segment once, then epoch. Online path: stream the
    same segment through CausalFilterState in arbitrary chunk sizes, then epoch. The
    epochs must be identical; this is the parity the PRD demands."""
    seg = small_runs(n_runs=1, trials_per_run=6, seed=4)[0]
    sos = pipeline.BandpassSpec().design(SFREQ)
    warm = pipeline.settling_samples(sos)
    offline = pipeline.epoch_segments([seg], sos, (0.5, 2.0), warm)

    rng = np.random.default_rng(1)
    cuts = np.sort(rng.choice(np.arange(1, seg.data.shape[1]), size=40, replace=False))
    state = pipeline.CausalFilterState(sos, seg.data.shape[0])
    streamed = np.concatenate([state.process(c) for c in np.split(seg.data, cuts, axis=-1)], axis=-1)

    online = pipeline.Segment(data=streamed, sfreq=SFREQ, events=seg.events, run_id=seg.run_id)
    # The streamed data is already filtered; epoch it through an identity filter.
    identity = np.array([[1.0, 0.0, 0.0, 1.0, 0.0, 0.0]])
    online_epochs = pipeline.epoch_segments([online], identity, (0.5, 2.0), warm)
    np.testing.assert_allclose(online_epochs.X, offline.X, rtol=1e-10, atol=1e-12)
    assert online_epochs.trial_ids.tolist() == offline.trial_ids.tolist()


def test_per_trial_zero_state_filtering_differs_from_segment_filtering():
    """The defect this PR fixes: filtering a pre-cut trial from zero state produces a
    start transient the online path never sees."""
    seg = small_runs(n_runs=1, trials_per_run=3, seed=5)[0]
    seg.data += 500.0  # raw Cyton EEG carries large DC offsets; the band-pass removes them online
    sos = pipeline.BandpassSpec().design(SFREQ)
    warm = pipeline.settling_samples(sos)
    cue = seg.events[1][0]
    start, stop = cue + int(0.5 * SFREQ), cue + int(2.5 * SFREQ)
    continuous = pipeline.filter_segment(sos, seg.data)[:, start:stop]
    per_trial = pipeline.filter_segment(sos, seg.data[:, start:stop])
    scale = np.std(continuous)
    # During the warm-up the per-trial path is dominated by the step response ...
    assert np.max(np.abs(per_trial[:, :warm] - continuous[:, :warm])) > 10 * scale
    # ... and only after the warm-up do the two paths agree (settling is geometric:
    # 1e-3 of the step at `warm`, 1e-6 at twice that).
    assert np.max(np.abs(per_trial[:, warm:] - continuous[:, warm:])) < 0.2 * scale
    assert np.max(np.abs(per_trial[:, 2 * warm:] - continuous[:, 2 * warm:])) < 1e-3 * scale


def test_trials_inside_filter_warmup_are_excluded_and_listed():
    seg = small_runs(n_runs=1, trials_per_run=4, pre_seconds=0.1, seed=6)[0]
    sos = pipeline.BandpassSpec().design(SFREQ)
    warm = pipeline.settling_samples(sos)
    assert warm > 0.1 * SFREQ
    ep = pipeline.epoch_segments([seg], sos, (0.0, 2.0), warm)
    assert len(ep.exclusions) == 1
    assert ep.exclusions[0]["reason"] == "window_starts_before_filter_warmup"
    assert ep.exclusions[0]["trial_id"] == "run00-t000"
    assert ep.X.shape[0] == 3


def test_window_past_segment_end_is_excluded_not_padded():
    seg = small_runs(n_runs=1, trials_per_run=2, seed=7)[0]
    sos = pipeline.BandpassSpec().design(SFREQ)
    seg.data = seg.data[:, : seg.events[1][0] + int(1.0 * SFREQ)]
    ep = pipeline.epoch_segments([seg], sos, (0.5, 2.0), 0)
    assert [e["reason"] for e in ep.exclusions] == ["window_exceeds_segment"]
    assert ep.X.shape[0] == 1


# --- evaluation record -----------------------------------------------------------------------


def test_fit_evaluate_is_seeded_and_json_serializable():
    segs = small_runs(seed=1)
    a = pipeline.fit_evaluate(segs, seed=1)
    b = pipeline.fit_evaluate(segs, seed=1)
    assert a == b
    json.dumps(a, allow_nan=False)
    ref = a["models"]["reference_csp_rlda"]["holdout"]
    assert ref["n_test_trials"] == 12 and ref["n_test_runs"] == 1
    assert sum(map(sum, ref["confusion_matrix"])) == ref["n_test_trials"]
    assert 0.0 <= ref["accuracy_ci95"][0] <= ref["accuracy"] <= ref["accuracy_ci95"][1] <= 1.0
    assert a["exclusions"] == []
    assert a["config"]["filter_warmup_samples"] == pipeline.settling_samples(pipeline.BandpassSpec().design(SFREQ))


def test_reference_beats_chance_on_separable_synthetic_data():
    segs = small_runs(n_channels=16, trials_per_run=20, effect=0.8, seed=2)
    rec = pipeline.fit_evaluate(segs, seed=2)
    assert rec["models"]["reference_csp_rlda"]["holdout"]["balanced_accuracy"] > 0.75
    assert rec["models"]["reference_csp_rlda"]["cv_balanced_accuracy_mean"] > 0.75


def test_shuffled_labels_score_at_chance():
    """Negative control: with labels permuted there is nothing to learn, so the
    holdout must sit inside the chance band and the trial interval must cover 0.5."""
    segs = small_runs(n_runs=5, trials_per_run=20, n_channels=16, effect=0.8, seed=3)
    rng = np.random.default_rng(3)
    for s in segs:
        labels = rng.permutation([e[1] for e in s.events])
        s.events = [(e[0], int(l), e[2]) for e, l in zip(s.events, labels)]
    rec = pipeline.fit_evaluate(segs, seed=3)
    for name in ("reference_csp_rlda", "baseline_logvar_rlda"):
        h = rec["models"][name]["holdout"]
        assert abs(h["balanced_accuracy"] - 0.5) < 0.25, (name, h)
        assert h["accuracy_ci95"][0] <= 0.5 <= h["accuracy_ci95"][1], (name, h)


def test_split_manifest_is_group_disjoint_and_lists_ids():
    segs = small_runs(n_runs=6, trials_per_run=6, seed=8)
    rec = pipeline.fit_evaluate(segs, seed=8)
    m = rec["split_manifest"]
    assert set(m["holdout_runs"]).isdisjoint(m["training_runs"])
    assert set(m["holdout_runs"]) | set(m["training_runs"]) == {s.run_id for s in segs}
    trials_in_holdout = {e[2] for s in segs if s.run_id in m["holdout_runs"] for e in s.events}
    assert set(m["holdout_trials"]) == trials_in_holdout
    for fold in m["folds"]:
        assert set(fold["test_runs"]) <= set(m["training_runs"])
        assert set(fold["test_runs"]).isdisjoint(m["holdout_runs"])
    assert rec["split_policy"]["evidence"] == "same-session"
    assert rec["class_counts"]["train"][0] + rec["class_counts"]["train"][1] == 6 * len(m["training_runs"])


def test_supplied_manifest_rescoring_ignores_seed_for_the_split():
    segs = small_runs(n_runs=6, trials_per_run=6, seed=9)
    first = pipeline.fit_evaluate(segs, seed=9)
    redraw = pipeline.fit_evaluate(segs, seed=10)
    assert redraw["split_manifest"]["holdout_runs"] != first["split_manifest"]["holdout_runs"] or \
        redraw["split_manifest"]["folds"] != first["split_manifest"]["folds"]
    rescored = pipeline.fit_evaluate(segs, seed=10, split_manifest=first["split_manifest"])
    assert rescored["split_manifest"] == first["split_manifest"]
    for name in first["models"]:
        a, b = first["models"][name], rescored["models"][name]
        assert a["cv_balanced_accuracy_per_fold"] == b["cv_balanced_accuracy_per_fold"]
        assert a["holdout"]["confusion_matrix"] == b["holdout"]["confusion_matrix"]
        assert a["holdout"]["per_run"] == b["holdout"]["per_run"]
    assert rescored["split_policy"]["holdout"].startswith("re-scored")


def test_manifest_that_does_not_match_the_data_is_refused():
    segs = small_runs(n_runs=4, trials_per_run=4, seed=11)
    rec = pipeline.fit_evaluate(segs, seed=11)
    bad = dict(rec["split_manifest"], holdout_runs=["run99"])
    with pytest.raises(ValueError, match="absent"):
        pipeline.fit_evaluate(segs, seed=11, split_manifest=bad)
    leaky = dict(rec["split_manifest"], training_runs=rec["split_manifest"]["training_runs"] + rec["split_manifest"]["holdout_runs"])
    with pytest.raises(ValueError, match="leaks"):
        pipeline.fit_evaluate(segs, seed=11, split_manifest=leaky)


def test_evidence_label_is_derived_from_session_ids():
    segs = small_runs(n_runs=4, trials_per_run=6, seed=12)
    for s in segs:
        s.session_id = "A" if s.run_id in ("run00", "run01") else "B"
    manifest = {
        "holdout_runs": ["run02", "run03"], "training_runs": ["run00", "run01"],
        "holdout_trials": sorted(e[2] for s in segs[2:] for e in s.events),
        "folds": [{"fold": 1, "test_runs": ["run00"]}, {"fold": 2, "test_runs": ["run01"]}],
    }
    rec = pipeline.fit_evaluate(segs, seed=12, split_manifest=manifest)
    assert rec["split_policy"]["evidence"] == "cross-session"
    assert rec["models"]["reference_csp_rlda"]["holdout"]["n_test_runs"] == 2


def test_missing_session_ids_report_unknown_session_not_same_session():
    segs = small_runs(n_runs=4, trials_per_run=6, seed=19)
    for s in segs:
        s.session_id = None
    assert pipeline.fit_evaluate(segs, seed=19)["split_policy"]["evidence"] == "unknown-session"
    segs[0].session_id = "A"  # one missing id is still unknown
    assert pipeline.fit_evaluate(segs, seed=19)["split_policy"]["evidence"] == "unknown-session"


def test_duplicate_run_ids_are_rejected():
    segs = small_runs(n_runs=4, trials_per_run=6, seed=20)
    segs[1].run_id = segs[0].run_id
    with pytest.raises(ValueError, match="duplicate run ids"):
        pipeline.fit_evaluate(segs, seed=20)


def test_manifest_schema_errors_are_value_errors_with_clear_messages():
    segs = small_runs(n_runs=4, trials_per_run=4, seed=21)
    good = pipeline.fit_evaluate(segs, seed=21)["split_manifest"]
    cases = [
        ({k: v for k, v in good.items() if k != "holdout_trials"}, "missing required key 'holdout_trials'"),
        ({k: v for k, v in good.items() if k != "folds"}, "missing required key 'folds'"),
        (dict(good, folds=[{"fold": 1, "test_runs": []}] + good["folds"][1:]), "non-empty 'test_runs'"),
        (dict(good, folds=good["folds"][:1]), "at least 2 folds"),
        (dict(good, folds=[dict(f, test_runs=good["training_runs"][:1]) for f in good["folds"]]), "cover each training run exactly once"),
        (dict(good, holdout_runs="run00"), "must be a list"),
        ("not a dict", "must be a JSON object"),
    ]
    for bad, message in cases:
        with pytest.raises(ValueError, match=message):
            pipeline.fit_evaluate(segs, seed=21, split_manifest=bad)


def test_uncertainty_blocks_per_run_bootstrap_and_paired_comparison():
    segs = small_runs(n_runs=8, trials_per_run=8, n_channels=16, effect=0.8, seed=13)
    rec = pipeline.fit_evaluate(segs, seed=13)
    h = rec["models"]["reference_csp_rlda"]["holdout"]
    assert h["n_test_runs"] == 2 and len(h["per_run"]) == 2
    lo, hi = h["balanced_accuracy_run_bootstrap_ci95"]
    assert 0.0 <= lo <= h["balanced_accuracy"] <= hi <= 1.0
    cmp = rec["comparison"]
    assert {d["run_id"] for d in cmp["per_run_difference"]} == set(rec["split_manifest"]["holdout_runs"])
    assert cmp["difference_run_bootstrap_ci95"][0] <= cmp["mean_difference"] <= cmp["difference_run_bootstrap_ci95"][1]
    paired = cmp["paired_trials"]
    assert sum(paired.values()) == h["n_test_trials"]
    assert "independent" in rec["uncertainty_notes"]


def test_single_holdout_run_reports_null_bootstrap_not_a_fake_interval():
    segs = small_runs(n_runs=4, trials_per_run=8, seed=14)
    rec = pipeline.fit_evaluate(segs, seed=14)
    h = rec["models"]["reference_csp_rlda"]["holdout"]
    assert h["n_test_runs"] == 1
    assert h["balanced_accuracy_run_bootstrap_ci95"] is None
    assert rec["comparison"]["difference_run_bootstrap_ci95"] is None


def test_config_is_derived_from_fitted_objects():
    segs = small_runs(n_runs=4, trials_per_run=6, seed=15)
    rec = pipeline.fit_evaluate(segs, seed=15, n_components=2, bandpass=pipeline.BandpassSpec(10.0, 24.0, 3))
    c = rec["config"]
    assert c["bandpass_hz"] == [10.0, 24.0] and c["bandpass_order"] == 3 and c["bandpass_sections"] == 3
    assert c["csp_components"] == 2 and sorted(c["csp_component_indices"]) == [0, 7]
    assert len(c["csp_shrinkage_per_class"]) == 2 and all(0 <= a <= 1 for a in c["csp_shrinkage_per_class"])
    assert c["window_samples"] == 250 and c["n_channels"] == 8


def test_cancellation_checkpoint_between_folds():
    segs = small_runs(n_runs=4, trials_per_run=6, seed=16)
    calls = {"n": 0}

    def check():
        calls["n"] += 1
        if calls["n"] == 3:
            raise RuntimeError("stop here")

    with pytest.raises(RuntimeError, match="stop here"):
        pipeline.fit_evaluate(segs, seed=16, check_cancelled=check)
    assert calls["n"] == 3


# --- fitted arrays and CSP parity -------------------------------------------------------------


def test_fitted_arrays_round_trip_npz_and_reproduce_predictions(tmp_path):
    segs = small_runs(n_runs=4, trials_per_run=8, seed=17)
    rec, fitted = pipeline.fit_evaluate(segs, seed=17, return_fitted=True)
    sos = pipeline.BandpassSpec().design(SFREQ)
    ep = pipeline.epoch_segments(segs, sos, (0.5, 2.0), rec["config"]["filter_warmup_samples"])
    for name in ("reference_csp_rlda", "baseline_logvar_rlda"):
        path = tmp_path / f"{name}.npz"
        np.savez(path, **fitted[name])
        loaded = dict(np.load(path))
        assert "bandpass_sos" in loaded and "lda_coef" in loaded
        if name.startswith("reference"):
            assert loaded["csp_filters"].shape == (4, 8) and loaded["csp_patterns"].shape == (4, 8)
        model = pipeline.reference_pipeline(4) if name.startswith("reference") else pipeline.baseline_pipeline()
        train = np.isin(ep.groups, rec["split_manifest"]["training_runs"])
        model.fit(ep.X[train], ep.y[train])
        np.testing.assert_array_equal(pipeline.predict_from_arrays(loaded, ep.X), model.predict(ep.X))


def test_csp_matches_mne_subspace_and_classifier_outputs():
    mne = pytest.importorskip("mne")
    mne.set_log_level("ERROR")
    segs = small_runs(n_runs=3, trials_per_run=16, n_channels=8, effect=0.7, seed=18)
    sos = pipeline.BandpassSpec().design(SFREQ)
    ep = pipeline.epoch_segments(segs, sos, (0.5, 2.0), pipeline.settling_samples(sos))
    X, y = ep.X, ep.y
    n_ch = X.shape[1]

    ours = pipeline.CSP(n_components=n_ch).fit(X, y)
    theirs = mne.decoding.CSP(n_components=n_ch, reg="ledoit_wolf", log=True, norm_trace=False).fit(X, y)

    # Same generalized eigenvalues (MNE restricts to the principal subspace first; for
    # full-rank data that is a change of basis and leaves the spectrum intact).
    np.testing.assert_allclose(np.sort(ours.eigenvalues_), np.sort(theirs.evals_), rtol=1e-6, atol=1e-8)
    # Each of our filters is parallel (up to sign and scale) to one of MNE's.
    def cos(a, b):
        return abs(a @ b) / (np.linalg.norm(a) * np.linalg.norm(b))
    for f in ours.filters_:
        assert max(cos(f, g) for g in theirs.filters_) > 1 - 1e-6
    # Same top/bottom components when both keep four.
    ours4 = pipeline.CSP(n_components=4).fit(X, y)
    theirs4 = mne.decoding.CSP(n_components=4, reg="ledoit_wolf", log=True, norm_trace=False).fit(X, y)
    assert sorted(np.round(ours4.eigenvalues_[ours4.component_indices_], 8)) == sorted(np.round(theirs4.evals_[:4], 8))

    # Log-power features differ only by a per-component offset (filter scale) and a
    # permutation; shrinkage LDA is invariant to both, so predictions agree.
    from sklearn.discriminant_analysis import LinearDiscriminantAnalysis as LDA
    pred_ours = LDA(solver="lsqr", shrinkage="auto").fit(ours.transform(X), y).predict(ours.transform(X))
    pred_theirs = LDA(solver="lsqr", shrinkage="auto").fit(theirs.transform(X), y).predict(theirs.transform(X))
    np.testing.assert_array_equal(pred_ours, pred_theirs)


def test_csp_rejects_more_than_two_classes():
    X = np.random.default_rng(0).standard_normal((9, 4, 50))
    with pytest.raises(ValueError, match="two classes"):
        pipeline.CSP(2).fit(X, np.array([0, 1, 2] * 3))
