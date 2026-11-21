"""Fitted-arrays validation (brief 006): a `.npz` is hostile input and only plain,
documented, finite arrays of consistent shape ever become a model."""

import hashlib
import io
import os
import zipfile

import numpy as np
import pytest

from bciworkspace_worker import pipeline, project_io
from bciworkspace_worker.pipeline import ModelError

SFREQ = 125.0


@pytest.fixture(scope="module")
def arrays():
    segs = pipeline.make_synthetic_runs(n_runs=3, trials_per_run=8, n_channels=8, sfreq=SFREQ, seed=9)
    _, fitted = pipeline.fit_evaluate(segs, seed=9, return_fitted=True)
    out = dict(fitted["reference_csp_rlda"])
    out.update({f"baseline__{k}": v for k, v in fitted["baseline_logvar_rlda"].items()})
    return out


def save(tmp_path, arrays, name="fitted.npz", compressed=False):
    path = tmp_path / name
    with open(path, "wb") as f:
        (np.savez_compressed if compressed else np.savez)(f, **arrays)
    return path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_valid_file_loads_both_models_with_summaries(tmp_path, arrays):
    path = save(tmp_path, arrays)
    ref, summary = project_io.load_model_arrays(path, sha(path), "reference", n_channels=8)
    assert set(ref) == pipeline.MODEL_KEYS["csp_log_power"]
    assert summary["feature_kind"] == "csp_log_power" and summary["n_channels"] == 8 and summary["n_features"] == 4
    assert summary["sha256"] == sha(path) and summary["lda_classes"] == [0, 1]
    assert summary["filter_warmup_samples"] == pipeline.settling_samples(arrays["bandpass_sos"])
    base, bsum = project_io.load_model_arrays(path, None, "baseline")
    assert set(base) == pipeline.MODEL_KEYS["log_variance"] and bsum["n_features"] == 8
    X = np.random.default_rng(0).standard_normal((3, 8, 250))
    np.testing.assert_array_equal(pipeline.score_from_arrays(ref, X), pipeline.score_from_arrays(arrays, X))


def test_hash_mismatch_refuses_the_model(tmp_path, arrays):
    path = save(tmp_path, arrays)
    with pytest.raises(ModelError, match="changed since it was frozen"):
        project_io.load_model_arrays(path, "0" * 64)


def test_pickled_object_array_is_refused_never_unpickled(tmp_path, arrays):
    hostile = dict(arrays, lda_classes=np.array([0, {"evil": 1}], dtype=object))
    path = save(tmp_path, hostile)
    with pytest.raises(ModelError, match="plain arrays"):
        project_io.load_model_arrays(path)


def test_a_pickle_file_is_not_an_npz(tmp_path):
    path = tmp_path / "fitted.npz"
    path.write_bytes(b"\x80\x04\x95" + b"cos\nsystem\n(S'true'\ntR." )
    with pytest.raises(ModelError, match="not an .npz"):
        project_io.load_model_arrays(path)


@pytest.mark.parametrize("mutate, message", [
    (lambda a: a.update(extra=np.zeros(3)), "undocumented"),
    (lambda a: a.update(baseline__extra=np.zeros(3)), "undocumented"),
    (lambda a: a.pop("lda_coef"), "missing"),
    (lambda a: a.update(csp_filters=a["csp_filters"].astype(np.float32)), "not float64"),
    (lambda a: a.update(lda_classes=np.array([0.0, 1.0])), "not an integer"),
    (lambda a: a.update(lda_classes=np.array([1, 1])), "repeats class"),
    (lambda a: a.update(lda_classes=np.array([0, 1, 2])), "lda_classes has shape"),
    (lambda a: a.update(feature_kind=np.array(3)), "not a string"),
    (lambda a: a.update(feature_kind=np.array("riemann")), "unknown feature kind"),
    (lambda a: a.update(csp_patterns=a["csp_patterns"][:, :5]), "csp_patterns has shape"),
    (lambda a: a.update(lda_coef=a["lda_coef"][:, :3]), "lda_coef has shape"),
    (lambda a: a.update(csp_component_indices=np.array([7, 6, 0, 99])), "out of range"),
    (lambda a: a.update(lda_intercept=np.array([np.nan])), "non-finite"),
    (lambda a: a.update(csp_filters=np.full_like(a["csp_filters"], np.inf)), "non-finite"),
    (lambda a: a.update(bandpass_sos=np.array([[1.0, 0, 0, 1.0, -2.5, 1.5]])), "not stable"),
    (lambda a: a.update(bandpass_sos=a["bandpass_sos"] * 2), "normalised"),
    (lambda a: a.update(bandpass_sos=np.zeros((2, 5))), "bandpass_sos has shape"),
    (lambda a: a.update(baseline__lda_coef=a["baseline__lda_coef"].astype(np.float16)), "baseline model"),
])
def test_hostile_arrays_are_refused_with_the_reason(tmp_path, arrays, mutate, message):
    hostile = {k: v.copy() for k, v in arrays.items()}
    mutate(hostile)
    path = save(tmp_path, hostile)
    with pytest.raises(ModelError, match=message):
        project_io.load_model_arrays(path)


def test_channel_count_must_match(tmp_path, arrays):
    with pytest.raises(ModelError, match="expects 8 channels, the recording has 16"):
        project_io.load_model_arrays(save(tmp_path, arrays), n_channels=16)


def test_file_without_a_baseline_cannot_freeze_the_baseline(tmp_path, arrays):
    ref_only = {k: v for k, v in arrays.items() if not k.startswith("baseline__")}
    path = save(tmp_path, ref_only)
    project_io.load_model_arrays(path)
    with pytest.raises(ModelError, match="no baseline model"):
        project_io.load_model_arrays(path, which="baseline")


def test_oversized_and_bomb_files_are_refused_before_loading(tmp_path, arrays):
    big = tmp_path / "big.npz"
    big.write_bytes(b"PK\x03\x04" + b"\0" * (project_io.MAX_MODEL_FILE_BYTES + 1))
    with pytest.raises(ModelError, match="at most"):
        project_io.load_model_arrays(big)
    bomb = save(tmp_path, dict(arrays, csp_eigenvalues=np.zeros(1_000_000)), "bomb.npz", compressed=True)
    assert bomb.stat().st_size < project_io.MAX_MODEL_FILE_BYTES
    with pytest.raises(ModelError, match="unpacks to more than"):
        project_io.load_model_arrays(bomb)


def test_non_array_members_and_truncated_archives_are_refused(tmp_path, arrays):
    path = save(tmp_path, arrays)
    buf = io.BytesIO(path.read_bytes())
    with zipfile.ZipFile(buf, "a") as zf:
        zf.writestr("../evil.txt", b"hi")
    odd = tmp_path / "odd.npz"
    odd.write_bytes(buf.getvalue())
    with pytest.raises(ModelError, match="not arrays"):
        project_io.load_model_arrays(odd)
    cut = tmp_path / "cut.npz"
    cut.write_bytes(path.read_bytes()[: path.stat().st_size // 2])
    with pytest.raises(ModelError, match="plain arrays"):
        project_io.load_model_arrays(cut)


def test_symlinks_and_fifos_are_refused(tmp_path, arrays):
    real = save(tmp_path, arrays)
    link = tmp_path / "link.npz"
    link.symlink_to(real)
    with pytest.raises(ModelError, match="cannot open"):
        project_io.load_model_arrays(link)
    fifo = tmp_path / "fifo.npz"
    os.mkfifo(fifo)
    with pytest.raises(ModelError, match="not a regular file"):
        project_io.load_model_arrays(fifo)
