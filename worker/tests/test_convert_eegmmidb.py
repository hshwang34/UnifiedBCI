"""The dev-time EDF converter: deterministic output, manifest that validates.

Skipped unless the raw PhysioNet files are present (they are downloaded by hand into
build/datasets/eegmmidb and never committed)."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
RAW = Path(os.environ.get("EEGMMIDB_RAW_DIR", REPO / "build" / "datasets" / "eegmmidb"))
TOOL = REPO / "worker" / "tools" / "convert_eegmmidb.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("convert_eegmmidb", TOOL)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["convert_eegmmidb"] = mod
    spec.loader.exec_module(mod)
    return mod


pytestmark = pytest.mark.skipif(
    not all((RAW / f"{r}.edf").exists() for r in ("S001R04", "S001R08", "S001R12")),
    reason="raw EEGMMIDB files not present under build/datasets/eegmmidb (or $EEGMMIDB_RAW_DIR)",
)


def tree_digest(root: Path) -> dict[str, str]:
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}


def test_converter_is_byte_deterministic(tmp_path):
    tool = load_tool()
    a = tool.write_project(RAW, tmp_path / "a.bciproj", tool.PRESETS["tiny"])
    b = tool.write_project(RAW, tmp_path / "b.bciproj", tool.PRESETS["tiny"])
    assert tree_digest(a) == tree_digest(b)
    # And matches the committed fixture, so the fixture cannot drift from the tool.
    assert tree_digest(a) == tree_digest(REPO / "Tests" / "Fixtures" / "tiny.bciproj")


def test_converted_manifest_is_valid(tmp_path):
    tool = load_tool()
    out = tool.write_project(RAW, tmp_path / "t.bciproj", tool.PRESETS["tiny"])
    project = json.loads((out / "project.json").read_text())
    assert project["formatVersion"] == 1
    (rec_dir,) = [p for p in (out / "recordings").iterdir() if p.is_dir()]
    m = json.loads((rec_dir / "recording.json").read_text())
    assert m["formatVersion"] == 1 and m["recordingID"] == rec_dir.name
    assert m["sessionID"] is None and all(s["sessionID"] is None for s in m["segments"])
    assert [s["runID"] for s in m["segments"]] == ["S001R04", "S001R08", "S001R12"]
    assert m["timing"]["nominalSampleRateHz"] == 160.0
    assert [c["label"] for c in m["channels"]] == tool.TINY_CHANNELS
    assert all(c["unit"] == "uV" and c["sourceRow"] == i for i, c in enumerate(m["channels"]))
    src = m["source"]
    assert src["kind"] == "public_dataset" and src["license"] == "ODC-BY 1.0" and src["doi"] == "10.13026/C28G6P"
    assert {c["doi"] for c in src["attribution"]} == {"10.13026/C28G6P", "10.1109/TBME.2004.827072", "10.1161/01.CIR.101.23.e215"}
    assert any("cropped" in d for d in src["derivations"]) and not any("resampl" in d and "not" not in d for d in src["derivations"])
    assert {f["name"]: f["sha256"] for f in src["sourceFiles"]} == tool.EXPECTED_SHA256
    # Every chunk hashes, tiles its segment from 0, and has the declared shape.
    for seg in m["segments"]:
        entries = sorted((c for c in m["chunks"] if c["segment"] == seg["index"]), key=lambda c: c["firstSampleIndex"])
        expected = 0
        for c in entries:
            raw = (rec_dir / c["fileName"]).read_bytes()
            assert hashlib.sha256(raw).hexdigest() == c["sha256"]
            assert len(raw) == c["rowCount"] * c["sampleCount"] * 8
            assert c["firstSampleIndex"] == expected
            expected += c["sampleCount"]
        assert expected == 42 * 160
    events = [json.loads(l) for l in (rec_dir / "events.jsonl").read_text().splitlines() if l.strip()]
    cues = [e for e in events if e["label"] in ("cue_left_fist", "cue_right_fist")]
    assert len(cues) == 15 and all(e["trialID"] for e in cues) and all(e["origin"] == "protocol" for e in events)
    assert all(e["timingUncertaintyNanos"] is None for e in events)
    assert all(e["sampleAssociation"]["recordingID"] == m["recordingID"] for e in events)
    assert (out / "README.md").read_text().count("doi:") >= 3


def test_converter_refuses_a_tampered_input(tmp_path):
    tool = load_tool()
    raw = tmp_path / "raw"
    raw.mkdir()
    for r in ("S001R04", "S001R08", "S001R12"):
        (raw / f"{r}.edf").write_bytes((RAW / f"{r}.edf").read_bytes())
    data = bytearray((raw / "S001R08.edf").read_bytes())
    data[-1] ^= 0x01
    (raw / "S001R08.edf").write_bytes(bytes(data))
    with pytest.raises(SystemExit, match="SHA-256"):
        tool.write_project(raw, tmp_path / "x.bciproj", tool.PRESETS["tiny"])
