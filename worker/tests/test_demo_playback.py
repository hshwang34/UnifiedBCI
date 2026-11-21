"""The Demo playback file (`tools/make_demo_playback.py`, decision #42): BrainFlow's
Cyton+Daisy layout, clean counters, exact 125 Hz timestamps, deterministic bytes, and the
EEG's spectrum preserved by the 160 -> 125 Hz resampling."""

import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import pytest
from brainflow.board_shim import BoardIds, BoardShim, BrainFlowInputParams
from scipy.signal import welch

REPO = Path(__file__).resolve().parents[2]
BOARD = BoardIds.CYTON_DAISY_BOARD.value


def _tool():
    spec = importlib.util.spec_from_file_location("make_demo_playback", REPO / "worker" / "tools" / "make_demo_playback.py")
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    return tool


@pytest.fixture(scope="module")
def tool():
    return _tool()


@pytest.fixture(scope="module")
def built(tool):
    csv, side = tool.build()
    data = np.loadtxt(io.StringIO(csv.decode("ascii")), delimiter="\t")
    return csv, side, data, json.loads(side)


def test_layout_matches_brainflows_cyton_daisy(tool, built):
    _, _, data, _ = built
    assert tool.BOARD_ID == BOARD
    assert tool.ROWS == BoardShim.get_num_rows(BOARD)
    assert tool.COUNTER_ROW == BoardShim.get_package_num_channel(BOARD)
    assert tool.TIMESTAMP_ROW == BoardShim.get_timestamp_channel(BOARD)
    assert tool.MARKER_ROW == BoardShim.get_marker_channel(BOARD)
    assert list(tool.EEG_ROWS) == BoardShim.get_eeg_channels(BOARD)
    assert tool.RATE == BoardShim.get_sampling_rate(BOARD)
    assert data.shape[1] == tool.ROWS
    zero_rows = sorted(set(range(tool.ROWS)) - {tool.COUNTER_ROW, tool.TIMESTAMP_ROW, *tool.EEG_ROWS})
    assert set(BoardShim.get_accel_channels(BOARD)) <= set(zero_rows)
    assert set(BoardShim.get_other_channels(BOARD)) <= set(zero_rows)
    assert np.all(data[:, zero_rows] == 0), "accel/other/analog and marker rows are 0"


def test_counters_step_two_mod_256_without_gaps(built):
    _, _, data, _ = built
    counters = data[:, 0].astype(int)
    assert counters[0] == 0
    assert np.all(counters % 2 == 0)
    assert np.all(np.diff(counters) % 256 == 2), "no gaps, no repeats (stale halves)"
    assert np.array_equal(data[:, 0], counters), "integers only"


def test_loop_seam_is_detectable_by_counters(tool, built):
    _, _, data, meta = built
    assert data[-1, 0] == 16 and data[0, 0] == 0
    assert (data[0, 0] - data[-1, 0]) % 256 != 2, "a restart must not look like a clean step"
    assert meta["file"]["loopSeam"] == tool.LOOP_SEAM and "loopable" not in meta["file"]


def test_rate_is_125_with_exact_deterministic_timestamps(tool, built):
    csv, _, data, meta = built
    n = data.shape[0]
    # 125 s of source at 160 Hz -> 125 s at 125 Hz.
    assert n == meta["source"]["segments"][0]["sampleCount"] * 25 // 32 == 15625
    lines = csv.decode("ascii").splitlines()
    stamps = [line.split("\t")[tool.TIMESTAMP_ROW] for line in lines]
    assert stamps[0] == f"{tool.BASE_TIMESTAMP_S}.000"
    ms = [int(s.replace(".", "")) for s in stamps]
    assert set(np.diff(ms)) == {8}, "exactly 1/125 s per sample"
    assert meta["resampledRateHz"] == 125 and meta["originalRateHz"] == 160


def test_output_is_byte_deterministic(tool, built, tmp_path):
    csv, side, _, meta = built
    again_csv, again_side = tool.build()
    assert again_csv == csv and again_side == side
    assert meta["file"]["sha256"] == hashlib.sha256(csv).hexdigest()
    # The script entry point writes the same bytes.
    subprocess.run([sys.executable, str(REPO / "worker" / "tools" / "make_demo_playback.py"), "--out", str(tmp_path)],
                   check=True, capture_output=True)
    assert (tmp_path / tool.CSV_NAME).read_bytes() == csv
    assert (tmp_path / tool.SIDECAR_NAME).read_bytes() == side


def test_no_nan_and_eeg_in_plausible_microvolts(built):
    _, _, data, _ = built
    assert np.all(np.isfinite(data))
    eeg = data[:, 1:17]
    assert 1 < np.std(eeg) < 500, "µV scale, not V"


def test_spectrum_is_preserved(tool, built):
    _, _, data, _ = built
    _, segment = tool.load_source()
    f0, p0 = welch(segment.data, 160, nperseg=640)  # 0.25 Hz bins at both rates
    f1, p1 = welch(data[:, 1:17].T, 125, nperseg=500)
    f0, p0 = f0[: len(f1)], p0[:, : len(f1)]  # compare up to the new Nyquist
    assert np.array_equal(f0, f1)
    band = (f1 >= 8) & (f1 <= 13)
    for ch in range(16):
        peak0, peak1 = f1[band][np.argmax(p0[ch][band])], f1[band][np.argmax(p1[ch][band])]
        assert abs(peak0 - peak1) <= 0.5, f"channel {ch}: alpha/mu peak {peak0} -> {peak1} Hz"
    # Power well below the anti-aliasing transition band is kept within 2 %.
    keep = (f1 >= 1) & (f1 <= 40)
    ratio = p1[:, keep].sum(axis=1) / p0[:, keep].sum(axis=1)
    assert np.all(np.abs(ratio - 1) < 0.02), ratio


def test_sidecar_labels_the_file_as_derived(tool, built):
    _, _, _, meta = built
    assert meta["kind"] == "derived_playback"
    assert "not a raw recording" in meta["warning"].lower()
    assert meta["method"] == "scipy.signal.resample_poly up=25 down=32, default Kaiser FIR"
    assert meta["source"]["recordingID"] == tool.RECORDING_ID
    assert [s["runID"] for s in meta["source"]["segments"]] == ["S001R04"]
    assert meta["montage"] and meta["source"]["license"]
    manifest = json.loads((tool.EXAMPLE / "recordings" / tool.RECORDING_ID / "recording.json").read_text())
    assert [c["label"] for c in meta["channels"]] == [c["label"] for c in manifest["channels"]]
    assert [c["fileRow"] for c in meta["channels"]] == list(tool.EEG_ROWS)
    cues = meta["cues"]
    assert len(cues) == 30 and {c["label"] for c in cues} == {"rest", "cue_left_fist", "cue_right_fist"}
    for c in cues:
        # resample_poly keeps t = 0 aligned: output j sits at j / 125 s. Nearest sample, ties up.
        assert abs(c["sampleIndex"] - c["sourceSampleIndex"] * 125 / 160) <= 0.5


def test_brainflow_plays_the_file_back_unchanged(tool, built, tmp_path):
    """Short real playback: BrainFlow parses the compact number format and returns the
    file's rows untouched (timestamps included, with old_timestamps)."""
    csv, _, data, _ = built
    path = tmp_path / tool.CSV_NAME
    path.write_bytes(csv)
    params = BrainFlowInputParams()
    params.file, params.master_board = str(path), BOARD
    board = BoardShim(BoardIds.PLAYBACK_FILE_BOARD.value, params)
    board.prepare_session()
    try:
        board.config_board("old_timestamps")
        board.start_stream()
        chunks, count = [], 0
        deadline = time.monotonic() + 10
        while count < 50 and time.monotonic() < deadline:
            time.sleep(0.05)
            chunk = board.get_board_data()
            chunks.append(chunk)
            count += chunk.shape[1]
        got = np.concatenate(chunks, axis=1)
        board.stop_stream()
    finally:
        board.release_session()
    n = got.shape[1]
    # The loop stops once 50 samples arrived, so exactly 50 is a pass (it was `> 50`,
    # which failed whenever playback delivered in multiples of 50).
    assert 50 <= n <= data.shape[0]
    assert np.array_equal(got, data[:n].T)
