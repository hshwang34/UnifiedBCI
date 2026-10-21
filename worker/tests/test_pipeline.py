import json

import numpy as np

from bciworkspace_worker import pipeline


def test_synthetic_shapes_and_groups():
    X, y, g = pipeline.make_synthetic_mi(n_runs=3, trials_per_run=5, n_channels=8, sfreq=125.0)
    assert X.shape == (15, 8, 375)
    assert set(y) <= {0, 1}
    assert list(np.unique(g)) == [0, 1, 2]


def test_fit_evaluate_is_seeded_and_json_serializable():
    X, y, g = pipeline.make_synthetic_mi(seed=1)
    a = pipeline.fit_evaluate(X, y, g, sfreq=125.0, seed=1)
    b = pipeline.fit_evaluate(X, y, g, sfreq=125.0, seed=1)
    assert a == b
    json.dumps(a, allow_nan=False)
    ref = a["models"]["reference_csp_rlda"]["holdout"]
    assert ref["n_test_trials"] == 20  # one of four runs held out
    assert sum(map(sum, ref["confusion_matrix"])) == ref["n_test_trials"]
    assert 0.0 <= ref["accuracy_ci95"][0] <= ref["accuracy"] <= ref["accuracy_ci95"][1] <= 1.0


def test_reference_beats_chance_on_separable_synthetic_data():
    X, y, g = pipeline.make_synthetic_mi(effect=0.8, seed=2)
    rec = pipeline.fit_evaluate(X, y, g, sfreq=125.0, seed=2)
    assert rec["models"]["reference_csp_rlda"]["holdout"]["balanced_accuracy"] > 0.75


def test_holdout_runs_never_appear_in_training_folds():
    X, y, g = pipeline.make_synthetic_mi(n_runs=4, trials_per_run=4, seed=3)
    rec = pipeline.fit_evaluate(X, y, g, sfreq=125.0, seed=3, n_components=2)
    assert rec["split_policy"]["grouping"] == "run"
    assert rec["class_counts"]["train"][0] + rec["class_counts"]["train"][1] == 12


def test_causal_bandpass_matches_streaming_application():
    """Filtering a trial in one call must equal filtering it chunk-by-chunk with carried state."""
    from scipy.signal import sosfilt, sosfilt_zi

    bp = pipeline.CausalBandpass(sfreq=125.0).fit(None)
    x = np.random.default_rng(0).standard_normal((2, 400))
    whole = bp.transform(x)
    zi = np.zeros((bp.sos_.shape[0], 2, 2))
    pieces = []
    for chunk in np.split(x, [50, 125, 300], axis=-1):
        out, zi = sosfilt(bp.sos_, chunk, axis=-1, zi=zi)
        pieces.append(out)
    np.testing.assert_allclose(np.concatenate(pieces, axis=-1), whole, rtol=1e-10, atol=1e-12)
