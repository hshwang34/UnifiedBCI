"""`signal_window` (brief 002 trace view): known inputs, expected results (PRD §4)."""

from __future__ import annotations

import json
import threading
from pathlib import Path

import numpy as np
import pytest

from bciworkspace_worker import main as worker_main
from bciworkspace_worker import pipeline, signal_window
from bciworkspace_worker.protocol import ProtocolError, Request
from test_quality import Feed

REPO = Path(__file__).resolve().parents[2]
TINY = REPO / "Tests" / "Fixtures" / "tiny.bciproj"
TINY_RECORDING = "3e2e07c7-ba7a-5111-9cee-57a4e2990416"
CTX = worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None)


def sine(sfreq=250.0, seconds=60.0, hz=10.0, amp=100.0, n_channels=2, seed=0):
    rng = np.random.default_rng(seed)
    t = np.arange(int(sfreq * seconds)) / sfreq
    return amp * np.sin(2 * np.pi * hz * t) + 0.01 * rng.standard_normal((n_channels, t.size))


def test_response_is_bounded_at_30_s_and_2000_points():
    out = signal_window.window(sine(), 250.0, 0.0, 30.0)
    assert out["samples"] == 7500 and out["points"] == 2000 and len(out["t_s"]) == 2000
    for ch in out["channels"]:
        for trace in ("raw", "bandpassed"):
            assert len(ch[trace]["min"]) == len(ch[trace]["max"]) == 2000


def test_sinusoid_amplitude_and_a_one_sample_spike_survive_the_envelope():
    data = sine(hz=12.5, amp=100.0)     # 20 samples per cycle, so samples land on the peaks
    data[1, 4321] = 500.0
    out = signal_window.window(data, 250.0, 0.0, 30.0, "raw", max_points=100)   # 75 samples per point
    c0, c1 = out["channels"]
    assert min(c0["raw"]["max"]) > 99.0 and max(c0["raw"]["min"]) < -99.0
    assert c0["raw"]["hi"] == pytest.approx(100.0, abs=0.1) and c0["raw"]["lo"] == pytest.approx(-100.0, abs=0.1)
    assert max(c1["raw"]["max"]) == c1["raw"]["hi"] == 500.0
    # Each point is the min/max of its own samples, at its own start time.
    starts = (np.arange(100) * 7500) // 100
    assert out["t_s"] == [s / 250.0 for s in starts]
    assert c0["raw"]["max"][7] == pytest.approx(data[0, starts[7]:starts[8]].max())


def test_short_window_returns_every_sample():
    data = sine(seconds=5.0)
    out = signal_window.window(data, 250.0, 1.0, 2.0, "raw")
    assert out["points"] == out["samples"] == 500
    assert out["channels"][0]["raw"]["min"] == out["channels"][0]["raw"]["max"] == list(data[0, 250:750])


@pytest.mark.parametrize("start,duration,kept", [
    (-5.0, 10.0, (0.0, 10.0)),     # before the start: slides to 0
    (55.0, 10.0, (50.0, 10.0)),    # past the end: slides back
    (20.0, 10.0, (20.0, 10.0)),
    (3.0, 30.0, (3.0, 30.0)),
])
def test_window_is_clamped_inside_the_segment(start, duration, kept):
    out = signal_window.window(sine(), 250.0, start, duration, "raw")
    assert (out["start_s"], out["duration_s"]) == kept
    assert out["t_s"][0] == kept[0] and out["segment_duration_s"] == 60.0


def test_window_longer_than_the_segment_is_the_segment():
    out = signal_window.window(sine(seconds=12.0), 250.0, 4.0, 30.0, "raw")
    assert (out["start_s"], out["duration_s"], out["samples"]) == (0.0, 12.0, 3000)


@pytest.mark.parametrize("kwargs", [
    {"duration_s": 30.5}, {"duration_s": 0.0}, {"duration_s": -1.0}, {"duration_s": float("nan")},
    {"start_s": float("inf")}, {"which": "filtered"}, {"max_points": 1}, {"max_points": 2001},
])
def test_refuses_bad_parameters(kwargs):
    args = {"start_s": 0.0, "duration_s": 10.0, "which": "both", "max_points": 2000} | kwargs
    with pytest.raises(ValueError):
        signal_window.window(sine(), 250.0, **args)


def test_band_passed_is_the_whole_segment_filtered_from_zero_state_with_warm_up_marked():
    data = sine(sfreq=160.0, seconds=40.0) + 500.0     # a DC offset the band-pass removes
    sos = pipeline.BandpassSpec().design(160.0)
    settle = pipeline.settling_samples(sos)
    expected = pipeline.filter_segment(sos, data)
    for start in (0.0, 20.0):
        out = signal_window.window(data, 160.0, start, 10.0, "bandpassed")
        first = int(start * 160)
        assert out["points"] == out["samples"] == 1600   # one sample per point: exact values
        assert out["channels"][0]["bandpassed"]["max"] == pytest.approx(list(expected[0, first:first + 1600]))
        assert out["channels"][0]["raw"] is None
        assert out["bandpass"] == {"low_hz": 8.0, "high_hz": 30.0, "order": 4,
                                   "warmup_samples": settle, "warmup_end_s": settle / 160.0}
    # The warm-up is returned, not dropped: the window's first samples are its transient.
    assert 0.0 < out["bandpass"]["warmup_end_s"] < 1.0


def test_raw_only_skips_the_band_pass():
    out = signal_window.window(sine(), 250.0, 0.0, 10.0, "raw")
    assert out["bandpass"] is None and out["bandpassed_reason"] is None
    assert all(c["bandpassed"] is None and c["bandpassed_reason"] is None for c in out["channels"])


def test_low_rate_and_non_finite_channels_say_why():
    data = sine(sfreq=50.0, seconds=20.0)
    out = signal_window.window(data, 50.0, 0.0, 10.0, "both", 20)
    assert out["bandpass"] is None
    assert out["bandpassed_reason"] == "band-pass 8–30 Hz does not fit below Nyquist at 50 Hz"
    assert all(c["raw"] is not None and c["bandpassed"] is None for c in out["channels"])

    data = sine(sfreq=160.0, seconds=20.0)
    data[1, 160:320] = np.nan
    out = signal_window.window(data, 160.0, 0.0, 10.0, "both", 100)
    good, bad = out["channels"]
    assert good["bandpassed"] is not None and bad["bandpassed"] is None
    assert bad["bandpassed_reason"] == signal_window.NON_FINITE
    assert bad["raw"]["min"][10:20] == [None] * 10 and bad["raw"]["min"][0] is not None
    json.dumps(out, allow_nan=False)


# --- through the worker ------------------------------------------------------------------


def request(**params):
    base = {"project_dir": str(TINY), "recording_id": TINY_RECORDING, "segment": 0}
    return Request(id="w", method="signal_window", params=base | params)


def test_tiny_fixture_through_the_server():
    lines: list[dict] = []
    done, feed = threading.Event(), Feed()

    def write(line):
        lines.append(json.loads(line))
        if lines[-1].get("id") == "w" and "ok" in lines[-1]:
            done.set()

    req = {"v": 1, "id": "w", "method": "signal_window",
           "params": {"project_dir": str(TINY), "recording_id": TINY_RECORDING, "segment": 2, "start_s": 40.0, "duration_s": 10.0}}
    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": write}, daemon=True)
    t.start()
    feed.push(req)
    assert done.wait(30)
    feed.close()
    t.join(10)
    assert "signal_window" in lines[0]["data"]["methods"]
    resp = next(m for m in lines if m.get("id") == "w" and "ok" in m)
    assert resp["ok"], resp
    r = resp["result"]
    assert (r["segment"], r["run_id"], r["sfreq"]) == (2, "S001R12", 160.0)
    assert (r["start_s"], r["duration_s"], r["points"]) == (32.0, 10.0, 1600)
    assert [c["label"] for c in r["channels"]][:1] == ["FC3"] and len(r["channels"]) == 8
    assert all(c["raw"]["lo"] <= c["raw"]["hi"] for c in r["channels"])


@pytest.mark.parametrize("params,message", [
    ({"duration_s": 31.0}, "at most 30"),
    ({"segment": 9}, "no segment 9"),
    ({"segment": "0"}, "integers"),
    ({"segment": True}, "integers"),
    ({"max_points": 1.5}, "integers"),
    ({"start_s": "soon"}, "bad parameter"),
    ({"recording_id": "00000000-0000-0000-0000-000000000000"}, ""),
])
def test_handler_refuses_with_bad_request(params, message):
    with pytest.raises(ProtocolError) as err:
        worker_main.handle_signal_window(request(**params), CTX)
    assert err.value.code == "bad_request" and message in err.value.message


def test_handler_needs_a_segment():
    req = Request(id="w", method="signal_window", params={"project_dir": str(TINY), "recording_id": TINY_RECORDING})
    with pytest.raises(ProtocolError) as err:
        worker_main.handle_signal_window(req, CTX)
    assert "missing parameter 'segment'" in err.value.message
