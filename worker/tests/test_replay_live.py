"""`validate_model`, `replay_recording` and `live_open/push/close` (brief 006): parity on
recorded data, refusals, bounded in-band samples, and live results equal to replay."""

from __future__ import annotations

import base64
import hashlib
import json

import numpy as np
import pytest

from bciworkspace_worker import main as worker_main
from bciworkspace_worker import project_io, streaming
from bciworkspace_worker.protocol import ProtocolError, Request
from test_project import TINY, params, recording_id, run_in_process
from test_protocol_recordings import LABELS, write_protocol_project


def call(method, p, ctx=None):
    ctx = ctx or worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None)
    return worker_main.HANDLERS[method](Request(id="t", method=method, params=p), ctx)


def freeze(tmp_path, project, rid, **extra):
    """Evaluate, then name the reference fit as a model the way the app will."""
    target = tmp_path / "fitted.npz"
    out, _ = run_in_process({"project_dir": str(project), "recording_id": rid, "seed": 0,
                             "fitted_arrays_path": str(target), **extra})
    pipe = out["pipeline"]
    model = {"arrays_path": str(target), "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "which": "reference"}
    window = {"offset_s": float(pipe["configuration"]["window_offset_s"]),
              "length_s": float(pipe["configuration"]["window_length_s"])}
    return out, model, window, pipe


@pytest.fixture(scope="module")
def tiny(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("tiny")
    out, model, window, pipe = freeze(tmp, TINY, recording_id(TINY), labels=params(TINY)["labels"],
                                      window={"offset_s": 0.5, "length_s": 2.0})
    return {"tmp": tmp, "out": out, "model": model, "window": window, "pipe": pipe}


def replay_params(project, rid, fx, path, **extra):
    return {"project_dir": str(project), "recording_id": rid, "model": fx["model"], "window": fx["window"],
            "expected_channel_ids": fx["pipe"]["expectedChannelIDs"], "expected_sample_rate_hz": fx["pipe"]["expectedSampleRateHz"],
            "labels": {"left": fx["pipe"]["configuration"]["label_left"], "right": fx["pipe"]["configuration"]["label_right"]},
            "predictions_path": str(path), **extra}


def expect(code, method, p, match=None):
    with pytest.raises(ProtocolError) as err:
        call(method, p)
    assert err.value.code == code, err.value.message
    if match:
        assert match in err.value.message, err.value.message
    return err.value.message


# --- validate_model -----------------------------------------------------------------------------


def test_validate_model_summarises_and_refuses(tiny):
    summary = call("validate_model", {"model": tiny["model"], "n_channels": 8})
    assert summary["feature_kind"] == "csp_log_power" and summary["sha256"] == tiny["model"]["sha256"]
    expect("invalid_model", "validate_model", {"model": {**tiny["model"], "sha256": "ab" * 32}}, "changed since it was frozen")
    expect("invalid_model", "validate_model", {"model": tiny["model"], "n_channels": 16}, "expects 8 channels")
    expect("bad_request", "validate_model", {"model": {"arrays_path": 3}})


# --- replay_recording ---------------------------------------------------------------------------


def test_replay_of_the_tiny_fixture_passes_at_every_chunking(tiny):
    path = tiny["tmp"] / "predictions.jsonl"
    report = call("replay_recording", replay_params(TINY, recording_id(TINY), tiny, path))
    assert report["passed"], json.dumps(report)[:2000]
    assert [c["chunking"] for c in report["chunkings"]] == [1, 7, 13, 125, "random"]
    assert report["tolerances"] == streaming.TOLERANCES
    for q in ("bandpassed_uv", "features", "score"):
        assert report["max_deviation"][q]["within"]
    assert set(report["first_valid_window_stop"]) == {"0", "1", "2"}
    lines = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(lines) == report["n_predictions"] == report["windows_compared"]
    assert all(line["offline"]["validity"] == line["validity"] for line in lines)

    # The cue-locked windows carry exactly the held-out scores of the evaluation they came from.
    locked = {line["trial_id"]: line for line in lines if line["kind"] == "cue_locked" and line["validity"] == "valid"}
    holdout = set(tiny["out"]["evaluation"]["split_manifest"]["holdout_trials"])
    assert holdout <= set(locked)
    excluded = {e["trial_id"] for e in tiny["out"]["evaluation"]["exclusions"]}
    assert not excluded & set(locked)


def test_replay_of_a_protocol_recording_with_reconnect_gap_and_abort(tmp_path):
    project, rid, facts = write_protocol_project(tmp_path)
    out, model, window, pipe = freeze(tmp_path, project, rid, labels=LABELS, window={"offset_s": 0.5, "length_s": 2.0})
    fx = {"model": model, "window": window, "pipe": pipe}
    path = tmp_path / "p.jsonl"
    report = call("replay_recording", replay_params(project, rid, fx, path, cue_length_s=4.0, chunkings=[1, 125, "random"]))
    assert report["passed"], json.dumps(report)[:2000]
    assert len(report["first_valid_window_stop"]) == 5                     # one per segment, reset at the reconnect
    lines = [json.loads(line) for line in path.read_text().splitlines()]
    gap_trial = next(line for line in lines if line["kind"] == "cue_locked" and line["trial_id"] == facts["gap"])
    assert gap_trial["detail"] == "window_spans_detected_gap"
    assert any(line["feedback_eligible"] for line in lines)
    # Without a cue length (and no cue_end events) nothing is eligible: no imagery span is known.
    bare = call("replay_recording", replay_params(project, rid, fx, tmp_path / "q.jsonl", chunkings=[125]))
    assert bare["passed"]
    assert not any(json.loads(line)["feedback_eligible"] for line in (tmp_path / "q.jsonl").read_text().splitlines())


def test_cue_end_events_define_the_imagery_span(tmp_path):
    project, rid, _ = write_protocol_project(tmp_path)
    events_path = project / "recordings" / rid / "events.jsonl"
    events = [json.loads(line) for line in events_path.read_text().splitlines()]
    extra = []
    for ev in events:
        if ev.get("label") in LABELS.values():
            a = ev["sampleAssociation"]
            extra.append({"eventID": ev["eventID"] + "-end", "runID": ev["runID"], "trialID": ev["trialID"], "label": "cue_end",
                          "sampleAssociation": {**a, "sampleIndex": a["sampleIndex"] + 375}})
    events_path.write_text("".join(json.dumps(e) + "\n" for e in events + extra))
    ends = project_io.cue_end_samples(project_io.open_recording(project, rid))
    assert len(ends) == len(extra)
    out, model, window, pipe = freeze(tmp_path, project, rid, labels=LABELS, window={"offset_s": 0.5, "length_s": 2.0})
    path = tmp_path / "p.jsonl"
    call("replay_recording", replay_params(project, rid, {"model": model, "window": window, "pipe": pipe}, path, chunkings=[7]))
    eligible = [json.loads(line) for line in path.read_text().splitlines() if json.loads(line)["feedback_eligible"]]
    first_trial = [e for e in eligible if e["trial_id"] == eligible[0]["trial_id"]]
    # 3 s imagery span, 0.5 s offset, 2 s window: eligible stops cover 0.5 s.
    assert (first_trial[-1]["window_stop"] - first_trial[0]["window_stop"]) / 125 <= 0.5


@pytest.mark.parametrize("change, match", [
    (lambda ids: ids[::-1], "different order"),
    (lambda ids: ids[:-1], "missing"),
    (lambda ids: ids + ["X9"], "unexpected"),
])
def test_replay_refuses_channel_mismatch_without_reordering(tiny, change, match):
    p = replay_params(TINY, recording_id(TINY), tiny, tiny["tmp"] / "x.jsonl")
    p["expected_channel_ids"] = change(list(p["expected_channel_ids"]))
    expect("channel_mismatch", "replay_recording", p, match)


def test_replay_refuses_rate_mismatch_bad_chunking_and_changed_model(tiny):
    base = replay_params(TINY, recording_id(TINY), tiny, tiny["tmp"] / "x.jsonl")
    expect("channel_mismatch", "replay_recording", {**base, "expected_sample_rate_hz": 125.0}, "sample rate")
    expect("bad_request", "replay_recording", {**base, "chunkings": [0]})
    expect("invalid_model", "replay_recording", {**base, "model": {**tiny["model"], "sha256": "00" * 32}})


# --- live sessions ------------------------------------------------------------------------------


def live_ctx():
    return worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None, sessions={})


def open_params(fx, **extra):
    ids = fx["pipe"]["expectedChannelIDs"]
    rate = fx["pipe"]["expectedSampleRateHz"]
    return {"model": fx["model"], "window": fx["window"], "channel_ids": ids, "sample_rate_hz": rate,
            "expected_channel_ids": ids, "expected_sample_rate_hz": rate, **extra}


def b64(chunk):
    return base64.b64encode(np.ascontiguousarray(chunk, dtype="<f8").tobytes()).decode()


def test_live_session_matches_replay_window_for_window(tiny):
    rec = project_io.open_recording(TINY, recording_id(TINY))
    segs = project_io.load_segments(rec, {"cue_left_fist": 0, "cue_right_fist": 1})
    ctx = live_ctx()
    opened = call("live_open", open_params(tiny), ctx)
    sid = opened["session"]
    assert opened["window"]["hop_samples"] == 16
    live = []
    for seg in segs[:2]:
        cues = sorted(seg.events)
        sizes = streaming.chunk_sizes([6, 5, 7])
        pos = 0
        while pos < seg.data.shape[1]:
            n = min(next(sizes), seg.data.shape[1] - pos)
            due = [c for c in cues if pos <= c[0] < pos + n]
            r = call("live_push", {"session": sid, "segment": seg.segment_index, "first_sample": pos, "n_samples": n,
                                   "samples": b64(seg.data[:, pos:pos + n]),
                                   "cues": [{"sample": c[0], "trial_id": c[2]} for c in due]}, ctx)
            assert r["worker_compute_nanos"] >= 0 and r["n_samples"] == pos + n
            live += r["predictions"]
            pos += n
    live += call("live_close", {"session": sid}, ctx)["predictions"]
    assert ctx.sessions == {}

    spec = streaming.WindowSpec.make(rec.sfreq, (0.5, 2.0), sos=project_io.load_model_arrays(tiny["model"]["arrays_path"])[0]["bandpass_sos"])
    arrays, _ = project_io.load_model_arrays(tiny["model"]["arrays_path"])
    ref = []
    for seg in segs[:2]:
        ref += streaming.reference_segment(arrays, spec, seg.data, seg.gaps,
                                           [streaming.Cue(s, t) for s, _, t in seg.events], seg.segment_index)[0]
    assert [(p["segment"], p["kind"], p["window_stop"], p["validity"]) for p in live] == \
           [(p.segment, p.kind, p.window_stop, p.validity) for p in ref]
    for got, want in zip(live, ref):
        if want.score is not None:
            assert abs(got["score"] - want.score) <= streaming.TOLERANCES["score"]
            assert 0.5 <= got["confidence"] <= 1.0
    json.dumps(live, allow_nan=False)                                       # responses must frame


def test_live_push_is_bounded_ordered_and_atomic(tiny):
    ctx = live_ctx()
    sid = call("live_open", open_params(tiny), ctx)["session"]
    ok = {"session": sid, "segment": 0, "first_sample": 0, "n_samples": 4, "samples": b64(np.zeros((8, 4)))}
    call("live_push", ok, ctx)

    def refused(p, match):
        with pytest.raises(ProtocolError) as err:
            call("live_push", p, ctx)
        assert err.value.code == "bad_request" and match in err.value.message, err.value.message

    refused({**ok, "first_sample": 0}, "expects 4")                         # a replayed push
    refused({**ok, "first_sample": 9}, "expects 4")                         # a lost push
    nxt = {**ok, "first_sample": 4}
    refused({**nxt, "n_samples": worker_main.MAX_PUSH_SAMPLES + 1}, "per-push limit")
    refused({**nxt, "samples": b64(np.zeros((8, 5)))}, "base64 of 8 x 4")
    refused({**nxt, "samples": "!" * len(ok["samples"])}, "bad samples")
    refused({**nxt, "gaps": [{"after_sample": 0, "evidence": "sequence_skip"}]}, "not in this push")
    refused({**nxt, "cues": [{"sample": 1}] * 2}, "bad samples, gaps or cues")
    refused({**nxt, "cues": [{"sample": 1, "trial_id": "t"}] * (worker_main.MAX_PUSH_EVENTS + 1)}, "at most")
    refused({**nxt, "segment": 1}, "expects 0")                             # a new segment starts at 0
    refused({**nxt, "session": "nope"}, "no open live session")
    assert ctx.sessions[sid].n_samples == 4 and ctx.sessions[sid].segment == 0   # refusals changed nothing
    call("live_push", nxt, ctx)
    r = call("live_push", {**ok, "segment": 1}, ctx)                        # a new segment resets
    assert r["segment"] == 1 and r["n_samples"] == 4


def test_live_open_refuses_mismatch_and_caps_sessions(tiny):
    ctx = live_ctx()
    with pytest.raises(ProtocolError) as err:
        call("live_open", open_params(tiny, channel_ids=tiny["pipe"]["expectedChannelIDs"][::-1]), ctx)
    assert err.value.code == "channel_mismatch"
    with pytest.raises(ProtocolError) as err:
        call("live_open", open_params(tiny, sample_rate_hz=250.0), ctx)
    assert err.value.code == "channel_mismatch"
    for _ in range(worker_main.MAX_LIVE_SESSIONS):
        call("live_open", open_params(tiny), ctx)
    with pytest.raises(ProtocolError, match="at most"):
        call("live_open", open_params(tiny), ctx)


def test_live_methods_through_the_server_and_hello(tiny):
    lines: list[str] = []
    ids = tiny["pipe"]["expectedChannelIDs"]
    server = worker_main.Server(iter([]), lines.append)
    hello = worker_main.hello()
    assert {"validate_model", "replay_recording", "live_open", "live_push", "live_close"} <= set(hello["methods"])
    assert hello["protocol"] == 1
    server._register("o")
    server._run(Request.parse(json.dumps({"v": 1, "id": "o", "method": "live_open", "params": open_params(tiny)})))
    opened = json.loads(lines[-1])
    assert opened["ok"], opened
    sid = opened["result"]["session"]
    push = {"v": 1, "id": "p", "method": "live_push", "params": {"session": sid, "segment": 0, "first_sample": 0,
            "n_samples": 6, "samples": b64(np.ones((len(ids), 6)))}}
    server._register("p")
    server._run(Request.parse(json.dumps(push)))
    pushed = json.loads(lines[-1])
    assert pushed["ok"] and pushed["result"]["n_samples"] == 6
    assert "samples" not in pushed["result"]                                # nothing large comes back


def test_live_push_refuses_non_finite_samples_and_backward_segments(tiny):
    ctx = live_ctx()
    sid = call("live_open", open_params(tiny), ctx)["session"]
    ok = {"session": sid, "segment": 1, "first_sample": 0, "n_samples": 4, "samples": b64(np.zeros((8, 4)))}
    call("live_push", ok, ctx)
    for bad in (np.nan, np.inf, -np.inf):
        chunk = np.zeros((8, 4))
        chunk[2, 1] = bad
        with pytest.raises(ProtocolError, match="non-finite") as err:
            call("live_push", {**ok, "first_sample": 4, "samples": b64(chunk)}, ctx)
        assert err.value.code == "bad_request"
    with pytest.raises(ProtocolError, match="before the session's current segment"):
        call("live_push", {**ok, "segment": 0}, ctx)
    predictor = ctx.sessions[sid]
    assert (predictor.segment, predictor.n_samples) == (1, 4)
    assert np.all(np.isfinite(predictor._filter._zi))                        # state untouched
    call("live_push", {**ok, "first_sample": 4}, ctx)


def test_live_push_bounds_cue_samples_and_open_cues(tiny):
    ctx = live_ctx()
    opened = call("live_open", open_params(tiny), ctx)
    sid, length = opened["session"], opened["window"]["length_samples"]
    ok = {"session": sid, "segment": 0, "first_sample": 0, "n_samples": 4, "samples": b64(np.zeros((8, 4)))}
    ahead = 3 + length + worker_main.CUE_AHEAD_MARGIN_SAMPLES

    def refused(cues, match):
        with pytest.raises(ProtocolError, match=match):
            call("live_push", {**ok, "cues": cues}, ctx)

    refused([{"sample": -1, "trial_id": "a"}], "outside 0")
    refused([{"sample": ahead + 1, "trial_id": "a"}], "outside 0")
    refused([{"sample": 10, "trial_id": "a", "end_sample": 9}], "ends at 9")
    refused([{"sample": 10, "trial_id": "a", "end_sample": 10 + worker_main.MAX_CUE_SPAN_SAMPLES + 1}], "ends at")
    assert ctx.sessions[sid].open_cues == 0 and ctx.sessions[sid].segment is None
    call("live_push", {**ok, "cues": [{"sample": ahead, "trial_id": "edge", "end_sample": ahead + 500}]}, ctx)
    pos = 4
    for k in range(1, worker_main.MAX_OPEN_CUES):                           # fill to the cap
        call("live_push", {**ok, "first_sample": pos, "cues": [{"sample": 600, "trial_id": f"t{k}", "end_sample": 1100}]}, ctx)
        pos += 4
    assert ctx.sessions[sid].open_cues == worker_main.MAX_OPEN_CUES
    with pytest.raises(ProtocolError, match="at most 64 cues"):
        call("live_push", {**ok, "first_sample": pos, "cues": [{"sample": 600, "trial_id": "one-too-many"}]}, ctx)
    assert ctx.sessions[sid].n_samples == pos                               # refused push changed nothing
    # Cues close once their imagery span and trial window are past, freeing room.
    while pos < 1100 + length + 600:
        call("live_push", {**ok, "first_sample": pos, "n_samples": 512, "samples": b64(np.zeros((8, 512)))}, ctx)
        pos += 512
    assert ctx.sessions[sid].open_cues == 0


def test_replay_checks_for_cancellation_inside_the_reference_pass(tiny):
    calls = []

    class Stop(Exception):
        pass

    def check():
        calls.append(1)
        if len(calls) > 1:
            raise Stop()

    ctx = worker_main.Context(emit=lambda n, d: None, check_cancelled=check)
    p = replay_params(TINY, recording_id(TINY), tiny, tiny["tmp"] / "c.jsonl", chunkings=[1])
    with pytest.raises(Stop):
        call("replay_recording", p, ctx)
    assert len(calls) == 2                                                  # stopped in the reference pass's first segment

    seen = []
    rec = project_io.open_recording(TINY, recording_id(TINY))
    seg = project_io.load_segments(rec, None)[0]
    arrays, _ = project_io.load_model_arrays(tiny["model"]["arrays_path"])
    spec = streaming.WindowSpec.make(rec.sfreq, (0.5, 2.0), sos=arrays["bandpass_sos"])
    streaming.stream_segment(streaming.StreamingPredictor(arrays, 8, spec), seg.data, 1, check=lambda: seen.append(1))
    assert len(seen) == -(-seg.data.shape[1] // streaming.CHECK_EVERY)        # every CHECK_EVERY pushes
