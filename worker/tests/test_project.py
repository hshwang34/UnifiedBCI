"""`fit_evaluate_project`: evaluation over a `.bciproj` on disk.

Fixture F1 is `Tests/Fixtures/tiny.bciproj` (EEGMMIDB S001, 8 channels, first 42 s of
three runs). The bundled example is used by one slow test only.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from bciworkspace_worker import main as worker_main
from bciworkspace_worker import pipeline, project_io
from bciworkspace_worker.protocol import ProtocolError, Request

REPO = Path(__file__).resolve().parents[2]
TINY = REPO / "Tests" / "Fixtures" / "tiny.bciproj"
EXAMPLE = REPO / "App" / "Resources" / "ExampleProject" / "S001-motor-imagery.bciproj"


def recording_id(project: Path) -> str:
    (only,) = [p.name for p in (project / "recordings").iterdir() if p.is_dir()]
    return only


def params(project: Path, **extra) -> dict:
    base = {"project_dir": str(project), "recording_id": recording_id(project), "seed": 0,
            "window": {"offset_s": 0.5, "length_s": 3.5},
            "labels": {"left": "cue_left_fist", "right": "cue_right_fist"}, "csp_components": 4}
    base.update(extra)
    return base


def run_in_process(p: dict) -> tuple[dict, list[tuple[str, dict]]]:
    events: list[tuple[str, dict]] = []
    ctx = worker_main.Context(emit=lambda n, d: events.append((n, d)), check_cancelled=lambda: None)
    out = worker_main.handle_fit_evaluate_project(Request(id="t", method="fit_evaluate_project", params=p), ctx)
    return out, events


def run_in_subprocess(p: dict, **env_overrides: str) -> tuple[bytes, dict]:
    """One request through a fresh worker process. Returns the raw `evaluation` bytes
    exactly as the worker framed them (what the app stores) and the parsed response."""
    env = dict(os.environ, PYTHONUNBUFFERED="1", **env_overrides)
    proc = subprocess.Popen(
        [sys.executable, "-m", "bciworkspace_worker"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
    )
    try:
        assert json.loads(proc.stdout.readline())["event"] == "ready"
        proc.stdin.write((json.dumps({"v": 1, "id": "e", "method": "fit_evaluate_project", "params": p}) + "\n").encode())
        proc.stdin.flush()
        while True:
            line = proc.stdout.readline()
            assert line, proc.stderr.read().decode()
            if line.startswith(b'{"v":1,"id":"e","ok":'):
                break
        proc.stdin.write((json.dumps({"v": 1, "id": "s", "method": "shutdown"}) + "\n").encode())
        proc.stdin.flush()
        _, err = proc.communicate(timeout=120)
        assert proc.returncode == 0, err.decode()
    finally:
        proc.kill()
    obj = json.loads(line)
    assert obj["ok"], obj
    # Slice the `evaluation` member out of the line without re-encoding it.
    start = line.index(b'"evaluation":') + len(b'"evaluation":')
    depth, i = 0, start
    while True:
        c = line[i: i + 1]
        if c == b"{":
            depth += 1
        elif c == b"}":
            depth -= 1
            if depth == 0:
                break
        elif c == b'"':
            i += 1
            while line[i: i + 1] != b'"':
                i += 2 if line[i: i + 1] == b"\\" else 1
        i += 1
    raw = line[start: i + 1]
    assert json.loads(raw) == obj["result"]["evaluation"]
    return raw, obj


# --- reading the project -------------------------------------------------------------------


def test_tiny_fixture_loads_three_runs_with_verified_chunks():
    rec = project_io.open_recording(TINY, recording_id(TINY))
    segs = project_io.load_segments(rec, {"cue_left_fist": 0, "cue_right_fist": 1})
    assert [s.run_id for s in segs] == ["S001R04", "S001R08", "S001R12"]
    assert all(s.session_id is None for s in segs), "the dataset defines no session; none may be claimed"
    assert all(s.data.shape == (8, 42 * 160) for s in segs)
    assert sum(len(s.events) for s in segs) == 15
    assert rec.manifest["source"]["kind"] == "public_dataset"
    assert rec.manifest["channels"][0]["unit"] == "uV"
    # Values are the file's integer microvolts, not a float-scaled approximation.
    assert np.all(segs[0].data == np.round(segs[0].data))


def test_integrity_error_on_corrupt_chunk(tmp_path):
    project = tmp_path / "p.bciproj"
    shutil.copytree(TINY, project)
    rid = recording_id(project)
    chunk = project / "recordings" / rid / "chunks" / "000003.f64"
    raw = bytearray(chunk.read_bytes())
    raw[8] ^= 0x01
    chunk.write_bytes(bytes(raw))
    ctx = worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None)
    with pytest.raises(ProtocolError) as exc:
        worker_main.handle_fit_evaluate_project(Request(id="c", method="fit_evaluate_project", params=params(project)), ctx)
    assert exc.value.code == "integrity"
    assert "000003.f64" in exc.value.message
    # Not repaired: the bytes on disk are exactly what we wrote.
    assert chunk.read_bytes() == bytes(raw)


def test_missing_recording_is_a_bad_request_not_internal():
    ctx = worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None)
    with pytest.raises(ProtocolError) as exc:
        worker_main.handle_fit_evaluate_project(
            Request(id="m", method="fit_evaluate_project", params=params(TINY, recording_id="nope")), ctx)
    assert exc.value.code == "bad_request"


# --- the evaluation ---------------------------------------------------------------------------


def test_progress_stages_then_done_with_timing_outside_the_result():
    out, events = run_in_process(params(TINY))
    stages = [d["stage"] for n, d in events if n == "progress"]
    assert stages[0] == "loading"
    assert "fit" in stages and "holdout" in stages
    assert stages.index("fit") < stages.index("holdout")
    fits = [d for n, d in events if n == "progress" and d["stage"] == "fit"]
    assert all({"model", "fold", "of", "step", "steps"} <= set(d) for d in fits)
    assert events[-1][0] == "done" and set(events[-1][1]["stages"]) == {"loading", "fit"}
    text = json.dumps(out["evaluation"])
    assert "elapsed" not in text and "seconds_elapsed" not in text, "timing must never enter evaluation.json"
    ev = out["evaluation"]
    assert ev["split_policy"]["evidence"] == "unknown-session"
    assert ev["data_source"]["kind"] == "public_dataset"
    assert ev["data_source"]["warning"].startswith("Public dataset")
    assert ev["models"]["reference_csp_rlda"]["holdout"]["n_test_trials"] > 0
    pipe = out["pipeline"]
    assert pipe["recipe"] == "csp_rlda_v1"
    assert pipe["expectedChannelIDs"] == [f"ch{i:02d}" for i in range(8)]
    assert pipe["expectedSampleRateHz"] == 160.0
    assert len(pipe["configHash"]) == 64
    assert json.loads(pipe["splitManifest"]) == ev["split_manifest"]


def test_config_hash_is_over_canonical_inputs_not_results():
    a, _ = run_in_process(params(TINY, seed=0))
    b, _ = run_in_process(params(TINY, seed=1))
    assert a["pipeline"]["configHash"] == b["pipeline"]["configHash"], "the seed is not part of the config hash"
    c, _ = run_in_process(params(TINY, csp_components=2))
    assert c["pipeline"]["configHash"] != a["pipeline"]["configHash"]


def test_fitted_arrays_written_to_caller_path_and_reproduce_predictions(tmp_path):
    target = tmp_path / "fitted.npz"
    out, _ = run_in_process(params(TINY, fitted_arrays_path=str(target)))
    assert out["fitted_arrays_file"] == str(target)
    with np.load(target, allow_pickle=False) as z:
        arrays = {k: z[k] for k in z.files}
    assert str(arrays["feature_kind"]) == "csp_log_power"
    assert str(arrays["baseline__feature_kind"]) == "log_variance"
    rec = project_io.open_recording(TINY, recording_id(TINY))
    segs = project_io.load_segments(rec, {"cue_left_fist": 0, "cue_right_fist": 1})
    sos = arrays["bandpass_sos"]
    epochs = pipeline.epoch_segments(segs, sos, (0.5, 3.5), pipeline.settling_samples(sos))
    preds = pipeline.predict_from_arrays(arrays, epochs.X)
    assert preds.shape == epochs.y.shape and set(preds.tolist()) <= {0, 1}


def test_no_group_leaks_between_train_and_test():
    out, _ = run_in_process(params(TINY))
    m = out["evaluation"]["split_manifest"]
    assert not set(m["holdout_runs"]) & set(m["training_runs"])
    covered = [r for f in m["folds"] for r in f["test_runs"]]
    assert sorted(covered) == sorted(m["training_runs"])
    assert all(not set(f["test_runs"]) & set(m["holdout_runs"]) for f in m["folds"])
    rec = project_io.open_recording(TINY, recording_id(TINY))
    segs = project_io.load_segments(rec, {"cue_left_fist": 0, "cue_right_fist": 1})
    holdout_trials = {t for s in segs if s.run_id in m["holdout_runs"] for _, _, t in s.events}
    assert set(m["holdout_trials"]) == holdout_trials


def test_rescoring_a_supplied_split_manifest_ignores_seed():
    a, _ = run_in_process(params(TINY, seed=0))
    b, _ = run_in_process(params(TINY, seed=7, split_manifest=a["evaluation"]["split_manifest"]))
    assert b["evaluation"]["split_manifest"]["holdout_runs"] == a["evaluation"]["split_manifest"]["holdout_runs"]
    assert b["evaluation"]["models"]["reference_csp_rlda"]["holdout"]["confusion_matrix"] == \
        a["evaluation"]["models"]["reference_csp_rlda"]["holdout"]["confusion_matrix"]


# --- determinism (the byte-identity rule) ------------------------------------------------------


def test_same_seed_byte_identical_evaluation_json():
    a, _ = run_in_subprocess(params(TINY, seed=3), PYTHONHASHSEED="1")
    b, _ = run_in_subprocess(params(TINY, seed=3), PYTHONHASHSEED="4242")
    assert hashlib.sha256(a).hexdigest() == hashlib.sha256(b).hexdigest()
    assert a == b


def test_different_seed_differs():
    a, _ = run_in_subprocess(params(TINY, seed=3))
    b, _ = run_in_subprocess(params(TINY, seed=4))
    assert a != b
    assert json.loads(a)["split_policy"]["seed"] == 3 and json.loads(b)["split_policy"]["seed"] == 4


def test_thread_count_invariant():
    """BLAS thread count must not change the bytes. The worker pins one thread by
    default; this proves an operator override to 4 still reproduces the same record."""
    a, _ = run_in_subprocess(params(TINY, seed=3), BCI_WORKER_THREADS="1")
    b, _ = run_in_subprocess(params(TINY, seed=3), BCI_WORKER_THREADS="4")
    assert a == b


# --- the bundled example -----------------------------------------------------------------------


@pytest.mark.slow
def test_evaluate_full_example_within_budget():
    import time

    t0 = time.monotonic()
    out, events = run_in_process(params(EXAMPLE))
    elapsed = time.monotonic() - t0
    assert elapsed < 60, f"took {elapsed:.1f} s"
    ev = out["evaluation"]
    h = ev["models"]["reference_csp_rlda"]["holdout"]
    assert 0.0 <= h["balanced_accuracy"] <= 1.0
    assert h["n_test_trials"] > 0
    assert h["accuracy_ci95"][0] <= h["accuracy"] <= h["accuracy_ci95"][1]
    assert sum(map(sum, h["confusion_matrix"])) == h["n_test_trials"]
    assert ev["data_source"]["n_trials"] == 45 and ev["data_source"]["n_channels"] == 16
    print(f"\nS001 example seed 0: reference balanced accuracy {h['balanced_accuracy']:.3f}, accuracy {h['accuracy']:.3f} "
          f"CI {h['accuracy_ci95']}, n={h['n_test_trials']}; baseline "
          f"{ev['models']['baseline_logvar_rlda']['holdout']['balanced_accuracy']:.3f}; {elapsed:.2f} s")
