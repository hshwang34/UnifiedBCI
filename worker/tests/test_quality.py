"""Signal-quality checks (brief 002): known inputs, expected results (PRD §4).

Synthetic pink-noise channels with one injected fault each. Each fault must be flagged
by exactly its rule, and the clean channels by none. The fault sizes are chosen so a
fault trips its own rule without crossing another (e.g. the high-variance channel gets
its variance from a slow drift, which leaves 1 s peak-to-peak and 20-45 Hz power alone).
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import numpy as np
import pytest
from scipy.signal import butter, sosfilt

from bciworkspace_worker import main as worker_main
from bciworkspace_worker import pipeline, project_io, quality
from bciworkspace_worker.protocol import ProtocolError, Request

REPO = Path(__file__).resolve().parents[2]
TINY = REPO / "Tests" / "Fixtures" / "tiny.bciproj"
EXAMPLE = REPO / "App" / "Resources" / "ExampleProject" / "S001-motor-imagery.bciproj"
RULE_IDS = [r["id"] for r in quality.rules()]
BASE_UV = 25.0


def clean(rng, n_channels, sfreq, seconds):
    return BASE_UV * pipeline._pink_noise(rng, (n_channels, int(seconds * sfreq)))


def with_faults(sfreq: float, mains_hz: float, seconds: float = 60.0, seed: int = 0):
    """Six clean channels then six faulty ones; returns (data, expected rule per channel)."""
    rng = np.random.default_rng(seed)
    n = int(seconds * sfreq)
    t = np.arange(n) / sfreq
    data = clean(rng, 12, sfreq, seconds)
    expected: list[str | None] = [None] * 6
    # 6: flat for 8 s (tiny noise, so no sample repeats and nothing is pinned)
    start = int(20 * sfreq)
    data[6, start:start + int(8 * sfreq)] = 0.1 * rng.standard_normal(int(8 * sfreq))
    # 7: clipped at +/- 2 SD, so it sits at its segment max/min for runs of samples
    data[7] = np.clip(data[7], -2 * BASE_UV, 2 * BASE_UV)
    # 8: mains sinusoid
    data[8] += 20.0 * np.sin(2 * np.pi * mains_hz * t)
    # 9: high variance from a 0.05 Hz drift (about 9x the median variance)
    data[9] += 112.0 * np.sin(2 * np.pi * 0.05 * t)
    # 10: extra 22-40 Hz noise
    band = sosfilt(butter(4, [22.0, 40.0], btype="band", fs=sfreq, output="sos"), rng.standard_normal(n))
    data[10] += 0.8 * BASE_UV * band / band.std()
    # 11: one 3-sample spike of 300 uV in every 4th second (25 % of windows)
    for s in range(1, int(seconds), 4):
        i = int((s + 0.5) * sfreq)
        data[11, i - 1:i + 2] += np.array([150.0, 300.0, 150.0])
    expected += ["flatline", "pinned", "mains_line", "outlier_amplitude", "outlier_high_frequency", "large_deflection"]
    return data, expected


def flagged(channel):
    return [c["rule"] for c in channel["checks"] if c["flagged"]]


def check(channel, rule):
    return next(c for c in channel["checks"] if c["rule"] == rule)


@pytest.mark.parametrize("sfreq,mains_hz", [(160.0, 60.0), (125.0, 50.0), (160.0, 50.0)])
def test_each_fault_flagged_by_exactly_its_rule(sfreq, mains_hz):
    data, expected = with_faults(sfreq, mains_hz)
    out = quality.inspect_segment(data, sfreq, ["eeg"] * 12, ["uV"] * 12)
    for i, (channel, rule) in enumerate(zip(out, expected)):
        assert flagged(channel) == ([] if rule is None else [rule]), (i, rule, channel["checks"])
        assert [c["rule"] for c in channel["checks"]] == RULE_IDS


def test_flatline_reports_flat_seconds_of_total():
    data, _ = with_faults(160.0, 60.0)
    m = check(quality.inspect_segment(data, 160.0, ["eeg"] * 12, ["uV"] * 12)[6], "flatline")["measured"]
    assert m["flat_windows"] == 8 and m["flat_s"] == 8.0 and m["total_s"] == 60.0


def test_mains_60_not_assessable_at_125_hz_but_50_is():
    data, _ = with_faults(125.0, 50.0)
    mains = check(quality.inspect_segment(data, 125.0, ["eeg"] * 12, ["uV"] * 12)[8], "mains_line")
    lines = {line["hz"]: line for line in mains["measured"]["lines"]}
    assert lines[60.0]["assessable"] is False and lines[60.0]["reason"] == "not assessable at 125 Hz"
    assert lines[60.0]["db"] is None
    assert lines[50.0]["assessable"] is True and lines[50.0]["db"] > quality.MAINS_DB
    assert mains["flagged"] is True


def test_mains_not_assessable_when_no_line_fits():
    data = clean(np.random.default_rng(1), 4, 100.0, 20)
    mains = check(quality.inspect_segment(data, 100.0, ["eeg"] * 4, ["uV"] * 4)[0], "mains_line")
    assert mains["assessable"] is False and mains["reason"] == "not assessable at 100 Hz"


def test_non_microvolt_unit_skips_amplitude_rules_only():
    data, _ = with_faults(160.0, 60.0)
    units = ["uV"] * 12
    units[6] = "mV"
    out = quality.inspect_segment(data, 160.0, ["eeg"] * 12, units)
    for rule in ("flatline", "large_deflection", "outlier_amplitude", "outlier_high_frequency"):
        c = check(out[6], rule)
        assert c["assessable"] is False and c["reason"] == "not assessed (unit mV)" and c["flagged"] is False
    assert check(out[6], "pinned")["assessable"] and check(out[6], "mains_line")["assessable"]
    assert quality.is_microvolt("µV") and quality.is_microvolt("uV") and not quality.is_microvolt("V")


def test_non_eeg_channels_are_inspected_but_left_out_of_the_medians():
    data, expected = with_faults(160.0, 60.0)
    data[0] *= 100.0  # would drag the median if it were counted
    kinds = ["eeg"] * 12
    kinds[0] = "accel"
    out = quality.inspect_segment(data, 160.0, kinds, ["uV"] * 12)
    assert check(out[0], "outlier_amplitude")["assessable"] is False
    assert "kind accel" in check(out[0], "outlier_amplitude")["reason"]
    assert check(out[0], "large_deflection")["assessable"]
    for channel, rule in zip(out[1:], expected[1:]):
        assert flagged(channel) == ([] if rule is None else [rule])


def test_fewer_than_three_eeg_channels_makes_outliers_not_assessable():
    data = clean(np.random.default_rng(2), 3, 160.0, 20)
    out = quality.inspect_segment(data, 160.0, ["eeg", "eeg", "emg"], ["uV"] * 3)
    for rule in ("outlier_amplitude", "outlier_high_frequency"):
        c = check(out[0], rule)
        assert c["assessable"] is False and c["reason"] == "fewer than 3 EEG channels to compare"
    assert check(out[0], "flatline")["assessable"]


def test_short_segment_uses_its_own_length():
    sfreq = 160.0
    data = clean(np.random.default_rng(3), 4, sfreq, 1.8)
    out = quality.inspect_segment(data, sfreq, ["eeg"] * 4, ["uV"] * 4)
    assert check(out[0], "flatline")["measured"]["windows"] == 1
    psd = out[0]["psd"]
    assert psd["processed"] is not None and psd["processed_reason"] is None
    assert len(psd["freqs"]) == len(psd["raw"]) == len(psd["processed"])
    # Below one window nothing windowed is assessable and the band-passed PSD says why.
    tiny = quality.inspect_segment(data[:, :120], sfreq, ["eeg"] * 4, ["uV"] * 4)
    assert check(tiny[0], "flatline")["reason"] == "segment shorter than 1 s"
    assert tiny[0]["psd"]["processed"] is None and "warm-up" in tiny[0]["psd"]["processed_reason"]
    json.dumps(tiny, allow_nan=False)


def test_psd_is_bounded_and_spans_1_hz_to_nyquist():
    for sfreq, native in ((160.0, True), (1000.0, False)):
        data = clean(np.random.default_rng(4), 3, sfreq, 10)
        psd = quality.inspect_segment(data, sfreq, ["eeg"] * 3, ["uV"] * 3)[0]["psd"]
        freqs = psd["freqs"]
        assert len(freqs) <= quality.PSD_MAX_BINS and freqs[0] >= 1.0 and freqs[-1] <= sfreq / 2
        if native:  # 0.5 Hz bins from 1 Hz to 80 Hz
            assert len(freqs) == 159 and freqs[0] == 1.0 and freqs[-1] == 80.0


def test_band_passed_psd_attenuates_outside_the_pass_band():
    data = clean(np.random.default_rng(5), 3, 160.0, 30)
    psd = quality.inspect_segment(data, 160.0, ["eeg"] * 3, ["uV"] * 3)[0]["psd"]
    f, raw, proc = np.array(psd["freqs"]), np.array(psd["raw"]), np.array(psd["processed"])
    assert np.all(proc[f < 3] < raw[f < 3] - 20) and np.all(proc[f > 60] < raw[f > 60] - 20)
    assert np.all(np.abs(proc[(f > 12) & (f < 25)] - raw[(f > 12) & (f < 25)]) < 3)


def test_peak_frequency_finds_a_rhythm():
    rng = np.random.default_rng(6)
    sfreq = 160.0
    data = clean(rng, 3, sfreq, 30)
    data[0] += 15.0 * np.sin(2 * np.pi * 10.0 * np.arange(data.shape[1]) / sfreq)
    out = quality.inspect_segment(data, sfreq, ["eeg"] * 3, ["uV"] * 3)
    assert out[0]["peak_hz"] == 10.0


def test_constant_and_non_finite_channels_produce_no_nan():
    data, _ = with_faults(160.0, 60.0)
    data[0] = 3.0
    data[1, 100] = np.nan
    out = quality.inspect_segment(data, 160.0, ["eeg"] * 12, ["uV"] * 12)
    json.dumps(out, allow_nan=False)
    assert {"flatline", "pinned"} <= set(flagged(out[0]))
    assert out[0]["peak_hz"] is None and all(v is None for v in out[0]["psd"]["raw"])
    assert all(c["reason"] == "channel contains non-finite samples" for c in out[1]["checks"])


def test_rules_descriptor_matches_the_brief():
    rules = quality.rules()
    assert [r["id"] for r in rules] == ["flatline", "pinned", "large_deflection", "mains_line",
                                        "outlier_amplitude", "outlier_high_frequency"]
    assert rules[0]["rule"] == "window standard deviation < 0.5 µV" and rules[0]["flag_when"] == "≥ 1 window"
    assert all(set(r) == {"id", "title", "rule", "flag_when"} for r in rules)


# --- through the worker ------------------------------------------------------------------


def recording_id(project: Path) -> str:
    (only,) = [p.name for p in (project / "recordings").iterdir() if p.is_dir()]
    return only


def run_in_process(project: Path):
    events: list[tuple[str, dict]] = []
    ctx = worker_main.Context(emit=lambda n, d: events.append((n, d)), check_cancelled=lambda: None)
    req = Request(id="q", method="inspect_recording",
                  params={"project_dir": str(project), "recording_id": recording_id(project)})
    return worker_main.handle_inspect_recording(req, ctx), events


class Feed:
    def __init__(self):
        self.lines: list[str] = []
        self.cv = threading.Condition()
        self.closed = False

    def push(self, obj):
        with self.cv:
            self.lines.append(json.dumps(obj) + "\n")
            self.cv.notify_all()

    def close(self):
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def __iter__(self):
        i = 0
        while True:
            with self.cv:
                while i >= len(self.lines) and not self.closed:
                    self.cv.wait()
                if i >= len(self.lines):
                    return
                line = self.lines[i]
            i += 1
            yield line


def test_inspect_tiny_fixture_through_the_server():
    feed, out = Feed(), []
    done = threading.Event()

    def write(line):
        out.append(json.loads(line))
        if out[-1].get("id") == "q" and "ok" in out[-1]:
            done.set()

    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": write}, daemon=True)
    t.start()
    feed.push({"v": 1, "id": "q", "method": "inspect_recording",
               "params": {"project_dir": str(TINY), "recording_id": recording_id(TINY)}})
    assert done.wait(60)
    feed.push({"v": 1, "id": "s", "method": "shutdown"})
    t.join(10)
    feed.close()

    assert "inspect_recording" in out[0]["data"]["methods"]
    resp = next(m for m in out if m.get("id") == "q" and "ok" in m)
    assert resp["ok"], resp
    result = resp["result"]
    assert result["rules"] == quality.rules()
    assert [s["run_id"] for s in result["segments"]] == ["S001R04", "S001R08", "S001R12"]
    progress = [m["data"] for m in out if m.get("event") == "progress" and m.get("id") == "q"]
    assert progress[0] == {"stage": "loading"}
    assert [p["segment"] for p in progress[1:]] == [1, 2, 3] and all(p["of"] == 3 for p in progress[1:])
    assert any(m.get("event") == "done" and m.get("id") == "q" for m in out)
    seg = result["segments"][0]
    assert seg["index"] == 0 and seg["sfreq"] == 160.0 and seg["duration_s"] == 42.0
    ch = seg["channels"][0]
    assert (ch["id"], ch["label"], ch["kind"], ch["unit"]) == ("ch00", "FC3", "eeg", "uV")
    assert [c["rule"] for c in ch["checks"]] == RULE_IDS
    assert len(ch["psd"]["freqs"]) == len(ch["psd"]["raw"]) == len(ch["psd"]["processed"]) <= 256


def test_inspect_needs_no_events_file(tmp_path):
    import shutil
    project = tmp_path / "p.bciproj"
    shutil.copytree(TINY, project)
    (project / "recordings" / recording_id(project) / "events.jsonl").unlink()
    result, _ = run_in_process(project)
    assert len(result["segments"]) == 3


def test_inspect_cancelled_between_segments():
    calls = {"n": 0}

    def check_cancelled():
        calls["n"] += 1
        if calls["n"] == 2:
            raise worker_main.Cancelled()

    ctx = worker_main.Context(emit=lambda n, d: None, check_cancelled=check_cancelled)
    req = Request(id="q", method="inspect_recording",
                  params={"project_dir": str(TINY), "recording_id": recording_id(TINY)})
    with pytest.raises(worker_main.Cancelled):
        worker_main.handle_inspect_recording(req, ctx)


def test_inspect_missing_recording_is_a_bad_request():
    ctx = worker_main.Context(emit=lambda n, d: None, check_cancelled=lambda: None)
    req = Request(id="q", method="inspect_recording",
                  params={"project_dir": str(TINY), "recording_id": "00000000-0000-0000-0000-000000000000"})
    with pytest.raises(ProtocolError) as err:
        worker_main.handle_inspect_recording(req, ctx)
    assert err.value.code == "bad_request"


def test_inspect_bundled_example_runtime():
    t0 = time.monotonic()
    result, _ = run_in_process(EXAMPLE)
    elapsed = time.monotonic() - t0
    assert len(result["segments"]) == 3 and len(result["segments"][0]["channels"]) == 16
    json.dumps(result, allow_nan=False)
    assert elapsed < 2.0, f"inspection took {elapsed:.2f} s"
