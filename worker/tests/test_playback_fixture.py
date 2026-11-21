"""The Swift playback-board test (PlaybackBoardTests) reads a committed CSV; it must be
exactly what `tools/make_playback_fixture.py` writes, in BrainFlow's own file layout."""

import importlib.util
from pathlib import Path

import numpy as np
from brainflow.board_shim import BoardIds, BoardShim

REPO = Path(__file__).resolve().parents[2]


def _tool():
    spec = importlib.util.spec_from_file_location("make_playback_fixture", REPO / "worker" / "tools" / "make_playback_fixture.py")
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    return tool


def test_committed_fixture_is_current():
    tool = _tool()
    assert tool.FAULTS_CSV.read_text(encoding="ascii") == tool.render(tool.fault_samples()), \
        "stale: run `uv run python tools/make_playback_fixture.py`"


def test_fixture_matches_brainflows_cyton_daisy_layout():
    tool = _tool()
    board = BoardIds.CYTON_DAISY_BOARD.value
    assert tool.ROWS == BoardShim.get_num_rows(board)
    assert tool.COUNTER_ROW == BoardShim.get_package_num_channel(board)
    assert tool.TIMESTAMP_ROW == BoardShim.get_timestamp_channel(board)
    assert list(tool.EEG_ROWS) == BoardShim.get_eeg_channels(board)
    data = np.loadtxt(tool.FAULTS_CSV, delimiter="\t")
    assert data.shape == (tool.RECEIVED, tool.ROWS)
    assert np.all(np.diff(data[:, tool.TIMESTAMP_ROW]) > 0), "wall-clock stamps only move forward here"
