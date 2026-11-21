"""`protocol_schedule` mirrors Swift's `ProtocolSchedule` (brief 005): the golden vectors
both sides test against are regenerated here byte for byte."""

from __future__ import annotations

from pathlib import Path

import pytest

from bciworkspace_worker import protocol_schedule as ps

GOLDEN = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "protocol_schedule_golden.json"


def test_golden_vectors_reproduce_byte_for_byte():
    assert ps.golden_bytes() == GOLDEN.read_bytes(), "run tools/make_protocol_golden.py only for a deliberate change"


def test_splitmix64_matches_the_published_reference():
    rng = ps.SplitMix64(0)
    assert [rng.next() for _ in range(3)] == [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F]


def test_default_schedule_is_balanced_seeded_and_on_the_1_ms_grid():
    args = (["cue_left_hand", "cue_right_hand"], 20, 2000, 4000, 1500, 2500)
    a = ps.schedule(*args, seed=9, run_id="R")
    assert a == ps.schedule(*args, seed=9, run_id="R")
    assert a != ps.schedule(*args, seed=10, run_id="R")
    assert len(a) == 40 and sum(t["label"] == "cue_left_hand" for t in a) == 20
    assert all(1500 <= t["restMs"] <= 2500 for t in a)
    assert [t["trialID"] for t in a[:2]] == ["R-t01", "R-t02"] and a[-1]["trialID"] == "R-t40"
    assert all(t["cueOffsetMs"] - t["fixationOffsetMs"] == 2000 and t["cueEndOffsetMs"] - t["cueOffsetMs"] == 4000 for t in a)
    assert all(nxt["fixationOffsetMs"] == cur["endOffsetMs"] for cur, nxt in zip(a, a[1:]))


def test_default_content_hash_matches_the_swift_default():
    assert ps.content_hash(ps.DEFAULT_CLASSES, ps.DEFAULT_TIMING, 20) == \
        "88d54bfc113dd88ae0c091a9dfde6e6411d3486b17468add5221e1f69e557c49"


def test_bad_inputs_are_refused():
    with pytest.raises(ValueError):
        ps.SplitMix64(-1)
    with pytest.raises(ValueError):
        ps.SplitMix64(1 << 64)
    with pytest.raises(ValueError):
        ps.SplitMix64(0).below(-1)
    assert ps.SplitMix64(0).below(0) == 0xE220A8397B1DCDAF, "n = 0 is 2**64, as in Swift"
