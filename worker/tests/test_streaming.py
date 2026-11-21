"""Streaming inference vs the offline reference (brief 006): chunkings, startup, segment
reset, detected gaps, cue-locked windows, eligibility and the parity report."""

import numpy as np
import pytest

from bciworkspace_worker import pipeline, streaming
from bciworkspace_worker.streaming import Cue, StreamingPredictor, WindowSpec

SFREQ = 125.0
WINDOW = (0.5, 2.0)
CHUNKINGS = [1, 7, 13, 125, 10**9, "random"]


def sizes_for(chunking):
    if chunking == "random":
        return np.random.default_rng(42).integers(1, 64, size=97).tolist()
    return chunking


@pytest.fixture(scope="module")
def model():
    segs = pipeline.make_synthetic_runs(n_runs=3, trials_per_run=10, n_channels=8, sfreq=SFREQ, seed=3)
    sos = pipeline.BandpassSpec().design(SFREQ)
    ep = pipeline.epoch_segments(segs, sos, WINDOW, pipeline.settling_samples(sos))
    fitted = pipeline.reference_pipeline(4).fit(ep.X, ep.y)
    baseline = pipeline.baseline_pipeline().fit(ep.X, ep.y)
    return {"segs": segs, "sos": sos, "epochs": ep, "sk": fitted, "arrays": pipeline.fitted_arrays(fitted, sos),
            "baseline_sk": baseline, "baseline": pipeline.fitted_arrays(baseline, sos),
            "spec": WindowSpec.make(SFREQ, WINDOW, sos=sos)}


def cues_of(seg, cue_s=4.0):
    return [Cue(s, t, s + int(round(cue_s * SFREQ))) for s, _, t in seg.events]


def run_parity(arrays, spec, data, chunking, gaps=(), cues=(), segment=0):
    ref, ref_filtered = streaming.reference_segment(arrays, spec, data, gaps, cues, segment)
    predictor = StreamingPredictor(arrays, data.shape[0], spec)
    got, got_filtered = streaming.stream_segment(predictor, data, sizes_for(chunking), gaps, cues, segment)
    dev = float(np.max(np.abs(got_filtered - ref_filtered)))
    return streaming.parity_report(got, ref, dev), got, ref


# --- scores from arrays ---------------------------------------------------------------------


@pytest.mark.parametrize("which", ["arrays", "baseline"])
def test_score_and_confidence_from_arrays_agree_with_sklearn(model, which):
    sk = model["sk"] if which == "arrays" else model["baseline_sk"]
    arrays = model[which]
    X = model["epochs"].X
    scores = pipeline.score_from_arrays(arrays, X)
    np.testing.assert_allclose(scores, sk.decision_function(X), rtol=0, atol=1e-10)
    np.testing.assert_allclose(pipeline.confidence_from_score(scores), sk.predict_proba(X).max(axis=1), rtol=0, atol=1e-12)
    np.testing.assert_array_equal(pipeline.class_from_score(arrays, scores), sk.predict(X))


# --- parity over chunkings -----------------------------------------------------------------


@pytest.mark.parametrize("chunking", CHUNKINGS)
def test_streaming_matches_offline_for_every_chunking(model, chunking):
    seg = model["segs"][0]
    report, got, ref = run_parity(model["arrays"], model["spec"], seg.data, chunking, cues=cues_of(seg))
    assert report["passed"], report
    assert report["windows_compared"] == len(ref) == len(got)
    assert report["max_deviation"]["bandpassed_uv"]["observed_max"] <= streaming.TOLERANCES["bandpassed_uv"]
    assert not report["missing_windows"] and not report["extra_windows"]
    n_valid = sum(p.validity == "valid" for p in got)
    assert n_valid > 100
    assert [p.key for p in got] == [p.key for p in ref]          # same order, not just the same set


def test_every_chunking_gives_the_same_predictions(model):
    seg = model["segs"][1]
    runs = [run_parity(model["arrays"], model["spec"], seg.data, c, cues=cues_of(seg))[1] for c in CHUNKINGS]
    for other in runs[1:]:
        assert [(p.key, p.validity, p.detail) for p in other] == [(p.key, p.validity, p.detail) for p in runs[0]]
        np.testing.assert_allclose([p.score or 0 for p in other], [p.score or 0 for p in runs[0]], rtol=0, atol=1e-8)


# --- startup ------------------------------------------------------------------------------------


@pytest.mark.parametrize("chunking", [1, 7, 125])
def test_first_valid_window_is_full_and_past_warmup_in_both_paths(model, chunking):
    spec, seg = model["spec"], model["segs"][0]
    report, got, ref = run_parity(model["arrays"], spec, seg.data, chunking)
    expected = next(stop for stop in range(spec.hop, 10**6, spec.hop) if stop - spec.length >= spec.warmup)
    assert report["first_valid_window_stop"] == {"0": expected}
    first_streamed = next(p for p in got if p.validity == "valid")
    assert first_streamed.window_stop == expected
    hops = [p for p in got if p.kind == "hop"]
    assert [p.window_stop for p in hops[:3]] == [spec.hop, 2 * spec.hop, 3 * spec.hop]
    before = [p for p in hops if p.window_stop < expected]
    assert before and all(p.validity == "insufficient_window" and p.score is None for p in before)
    assert {p.detail for p in before} == {"window_starts_before_segment", "window_starts_before_filter_warmup"}


# --- segment reset -------------------------------------------------------------------------------


def test_new_segment_resets_filter_and_buffer(model):
    arrays, spec = model["arrays"], model["spec"]
    a, b = model["segs"][0].data, model["segs"][1].data
    predictor = StreamingPredictor(arrays, a.shape[0], spec)
    streaming.stream_segment(predictor, a, 7, segment=0)
    second, _ = streaming.stream_segment(predictor, b, 7, segment=1)
    fresh, _ = streaming.stream_segment(StreamingPredictor(arrays, b.shape[0], spec), b, 7, segment=1)
    assert [(p.key, p.validity, p.score) for p in second] == [(p.key, p.validity, p.score) for p in fresh]
    ref, _ = streaming.reference_segment(arrays, spec, b, segment=1)
    first_valid = next(p.window_stop for p in second if p.validity == "valid")
    assert first_valid == next(p.window_stop for p in ref if p.validity == "valid")
    assert first_valid - spec.length >= spec.warmup        # warm-up + window length after the reset

    # Without the reset the filter would carry segment a's state: the scores would differ.
    joined = np.concatenate([a, b], axis=1)
    _, carried = streaming.stream_segment(StreamingPredictor(arrays, a.shape[0], spec), joined, 7)
    stop = a.shape[1] + first_valid
    carried_score = pipeline.score_from_arrays(arrays, carried[None, :, stop - spec.length:stop])[0]
    assert abs(carried_score - next(p.score for p in fresh if p.window_stop == first_valid)) > 1e-6


# --- detected gaps -------------------------------------------------------------------------------


@pytest.mark.parametrize("chunking", [1, 13, "random"])
def test_window_spanning_a_detected_gap_is_insufficient_in_both_paths(model, chunking):
    arrays, spec, seg = model["arrays"], model["spec"], model["segs"][2]
    gaps = [(2000, "sequence_skip"), (3500, "stale_half"), (4100, "receipt_interval")]
    report, got, ref = run_parity(arrays, spec, seg.data, chunking, gaps=gaps, cues=cues_of(seg))
    assert report["passed"], report
    hit = [p for p in got if p.detail == "window_spans_detected_gap"]
    assert hit and all(p.validity == "insufficient_window" and p.score is None for p in hit)
    assert {p.gap for p in hit} == {(2000, "sequence_skip"), (3500, "stale_half")}   # receipt_interval is provenance only
    for p in got:
        affected = any(p.window_start - spec.warmup < a + 1 < p.window_stop for a, _ in gaps[:2])
        assert (p.detail == "window_spans_detected_gap") == (affected and p.window_start >= spec.warmup)


def test_gap_must_be_declared_with_its_chunk(model):
    predictor = StreamingPredictor(model["arrays"], 8, model["spec"])
    predictor.push(np.zeros((8, 50)))
    with pytest.raises(ValueError, match="not in this chunk"):
        predictor.push(np.zeros((8, 10)), [(10, "sequence_skip")])
    with pytest.raises(ValueError, match="chunk must be"):
        predictor.push(np.zeros((7, 10)))


# --- cue-locked windows and eligibility ------------------------------------------------------


def test_cue_locked_windows_reproduce_offline_epochs(model):
    """The per-trial window (decision #41) is the exact window offline evaluation cut."""
    arrays, spec, segs = model["arrays"], model["spec"], model["segs"]
    ep = model["epochs"]
    offline = dict(zip(ep.trial_ids, pipeline.score_from_arrays(arrays, ep.X)))
    got = []
    for i, seg in enumerate(segs):
        got += streaming.stream_segment(StreamingPredictor(arrays, 8, spec), seg.data, 13, cues=cues_of(seg), segment=i)[0]
    locked = {p.trial_id: p for p in got if p.kind == "cue_locked"}
    assert set(locked) == set(offline)
    for trial_id, score in offline.items():
        assert locked[trial_id].validity == "valid"
        assert abs(locked[trial_id].score - score) <= streaming.TOLERANCES["score"]


def test_cue_locked_exclusions_match_offline_reasons(model):
    arrays, spec, seg = model["arrays"], model["spec"], model["segs"][0]
    n = seg.data.shape[1]
    cues = [Cue(5, "early"), Cue(n - 10, "late"), Cue(800, "ok", 800 + 500)]
    report, got, _ = run_parity(arrays, spec, seg.data, 7, cues=cues)
    assert report["passed"], report
    locked = {p.trial_id: p.detail for p in got if p.kind == "cue_locked"}
    assert locked == {"early": "window_starts_before_filter_warmup", "late": "window_exceeds_segment", "ok": None}


def test_cue_registered_after_its_window_is_reported_late(model):
    predictor = StreamingPredictor(model["arrays"], 8, model["spec"])
    predictor.push(model["segs"][0].data[:, :1000])
    late = predictor.add_cue(Cue(100, "t-late"))
    assert [(p.kind, p.detail, p.trial_id) for p in late] == [("cue_locked", "cue_registered_late", "t-late")]


def test_feedback_eligible_only_wholly_inside_the_imagery_period(model):
    arrays, spec, seg = model["arrays"], model["spec"], model["segs"][0]
    cues = cues_of(seg)
    got, _ = streaming.stream_segment(StreamingPredictor(arrays, 8, spec), seg.data, 7, cues=cues)
    by_trial = {c.trial_id: c for c in cues}
    eligible = [p for p in got if p.feedback_eligible]
    assert eligible
    for p in got:
        if p.kind != "hop":
            assert not p.feedback_eligible
            continue
        inside = [c for c in cues if p.window_start >= c.sample + spec.offset and p.window_stop <= c.end_sample]
        assert p.feedback_eligible == bool(inside)
        if inside:
            assert by_trial[p.trial_id] in inside
    # 4 s cue, 0.5 s offset, 2 s window: eligible stops span the last 1.5 s of the cue.
    first = [p for p in eligible if p.trial_id == cues[0].trial_id]
    span = (first[-1].window_stop - first[0].window_stop) / SFREQ
    assert 1.5 - spec.hop / SFREQ <= span <= 1.5


# --- invalid input and the parity report --------------------------------------------------------


def test_non_finite_input_is_invalid_not_scored(model):
    data = model["segs"][0].data.copy()
    data[3, 1200] = np.nan
    got, _ = streaming.stream_segment(StreamingPredictor(model["arrays"], 8, model["spec"]), data, 25)
    after = [p for p in got if p.window_stop > 1200 and p.validity != "insufficient_window"]
    assert after and all(p.validity == "invalid_input" and p.score is None for p in after)
    assert all(np.isfinite(p.score) for p in got if p.validity == "valid")


def _pred(stop, score, validity="valid"):
    conf = float(pipeline.confidence_from_score(score)) if score is not None else None
    cls = None if score is None else int(score > 0)
    return streaming.Prediction(0, "hop", stop - 10, stop, validity, score=score, confidence=conf,
                                predicted_class=cls, features=np.zeros(4) if score is not None else None)


def test_parity_report_lists_boundary_windows_and_fails_real_mismatches():
    at_threshold = float(np.log(0.6 / 0.4))            # confidence exactly 0.6
    ref = [_pred(16, at_threshold + 1e-10), _pred(32, 2.0), _pred(48, None, "insufficient_window"), _pred(64, 1e-9)]
    flipped = [_pred(16, at_threshold - 1e-10), _pred(32, 2.0), _pred(48, None, "insufficient_window"), _pred(64, -1e-9)]
    assert streaming.decide(ref[0].score, ref[0].confidence, 1) != streaming.decide(flipped[0].score, flipped[0].confidence, 1)
    report = streaming.parity_report(flipped, ref, 0.0)
    assert report["passed"] and [b["window_stop"] for b in report["boundary_windows"]] == [16, 64]
    assert report["max_deviation"]["score"]["within"]
    ref, flipped = ref[:3], flipped[:3]

    wrong = [_pred(16, at_threshold + 1e-10), _pred(32, -2.0), _pred(48, None, "insufficient_window")]
    report = streaming.parity_report(wrong, ref, 0.0)
    assert not report["passed"] and report["decision_mismatches"][0]["window_stop"] == 32

    invalid = [_pred(16, at_threshold + 1e-10), _pred(32, 2.0), _pred(48, 1.0)]
    report = streaming.parity_report(invalid, ref, 0.0)
    assert not report["passed"] and report["validity_mismatches"][0]["window_stop"] == 48

    assert not streaming.parity_report(ref[:2], ref, 0.0)["passed"]                  # a missing window
    assert not streaming.parity_report(ref, ref, 1e-6)["passed"]                     # band-pass out of tolerance
    assert streaming.parity_report(ref, ref, 0.0)["tolerances"] == streaming.TOLERANCES


def test_abstention_is_a_threshold_on_confidence():
    assert streaming.decide(0.1, float(pipeline.confidence_from_score(0.1)), 1) == "abstain"
    assert streaming.decide(3.0, float(pipeline.confidence_from_score(3.0)), 1) == 1
    assert streaming.decide(None, None, None) is None
    assert streaming.DEFAULT_ABSTAIN_THRESHOLD == 0.6


def test_report_shows_observed_deviation_next_to_each_tolerance(model):
    seg = model["segs"][0]
    report, _, _ = run_parity(model["arrays"], model["spec"], seg.data, 7)
    for q, d in report["max_deviation"].items():
        assert d["tolerance"] == streaming.TOLERANCES[q] and 0.0 <= d["observed_max"] <= d["tolerance"] and d["within"]


def test_streamed_confidence_equals_sklearn_predict_proba(model):
    """The independent check: both paths share _judge/_score_window, so their agreement
    alone can't catch an error in the scoring; the sklearn objects can."""
    sk, arrays, spec, ep = model["sk"], model["arrays"], model["spec"], model["epochs"]
    proba = dict(zip(ep.trial_ids, sk.predict_proba(ep.X).max(axis=1)))
    decision = dict(zip(ep.trial_ids, sk.decision_function(ep.X)))
    cls = dict(zip(ep.trial_ids, sk.predict(ep.X)))
    got = []
    for i, seg in enumerate(model["segs"]):
        got += streaming.stream_segment(StreamingPredictor(arrays, 8, spec), seg.data, 7, cues=cues_of(seg), segment=i)[0]
    locked = [p for p in got if p.kind == "cue_locked"]
    assert len(locked) == len(proba)
    for p in locked:
        assert abs(p.confidence - proba[p.trial_id]) <= 1e-12
        assert abs(p.score - decision[p.trial_id]) <= streaming.TOLERANCES["score"]
        assert p.predicted_class == cls[p.trial_id]


def test_late_cue_outside_the_segment_gets_the_reference_reason(model):
    predictor = StreamingPredictor(model["arrays"], 8, model["spec"])
    predictor.push(model["segs"][0].data[:, :1000])
    (before,) = predictor.add_cue(Cue(-model["spec"].length - 100, "neg"))
    assert before.window_stop <= 0 and before.detail == "window_starts_before_segment"
    (warm,) = predictor.add_cue(Cue(0, "warm"))
    assert warm.detail == "window_starts_before_filter_warmup"
    ref, _ = streaming.reference_segment(model["arrays"], model["spec"], model["segs"][0].data[:, :1000],
                                         cues=[Cue(-model["spec"].length - 100, "neg"), Cue(0, "warm")])
    assert {p.trial_id: p.detail for p in ref if p.kind == "cue_locked"} == {"neg": before.detail, "warm": warm.detail}


def test_push_does_not_copy_the_window_buffer(model, monkeypatch):
    calls = []
    real = np.concatenate
    monkeypatch.setattr(streaming.np, "concatenate", lambda *a, **k: calls.append(1) or real(*a, **k))
    predictor = StreamingPredictor(model["arrays"], 8, model["spec"])
    for k in range(0, 160):
        predictor.push(model["segs"][0].data[:, k:k + 1])
    assert len(calls) <= 160 // model["spec"].hop                         # only per due window
