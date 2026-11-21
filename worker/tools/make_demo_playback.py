"""Build-time generator for the "Demo" playback file (brief 004, decision #42).

Turns one run of the bundled example (PhysioNet EEGMMIDB S001, 160 Hz) into a BrainFlow
playback CSV in Cyton+Daisy's layout (board 2, 125 Hz over the radio), so the app can
stream it through the playback-file board (-3) with Cyton+Daisy as master board and run
the whole live path on real EEG without hardware.

This is an explicitly labelled *derived demo input*, not a recording. The "never
interpolate raw data" rule is about recordings; here the source is resampled 160 -> 125 Hz
on purpose, because the master board's layout fixes the rate. The sidecar JSON written
next to the CSV says so, names the source and the method, and later PRs use it to label
recordings made from the Demo as derived playback.

What happens to the samples, and nothing else:

- one stream segment (run S001R04, the first imagery run, 125 s) is read with the
  worker's own verified readers (`project_io`: every chunk's SHA-256 is checked);
- `scipy.signal.resample_poly(x, 25, 32)` per channel, with its default Kaiser-windowed
  anti-aliasing FIR and default zero padding, over that one continuous segment only
  (never across a segment boundary);
- EEG values are written in µV with 2 decimals (the EDF's own resolution is coarser).

File layout (rows from `BoardShim.get_*_channels(2)`, checked by the tests): one line per
sample, 32 tab-separated values. Row 0 the package counter (0, 2, 4, ... mod 256: the
Daisy averaging convention, no gaps, no stale halves), rows 1-16 EEG in the example's
channel order, accel/other/analog rows 0, row 30 the timestamp (a fixed epoch plus exactly
1/125 s per sample, written as exact milliseconds; the app plays it with old_timestamps),
row 31 the marker row: 0. BrainFlow 5.23.0's playback board zeroes the file's marker row
and only carries markers inserted at play time, so the cue events go in the sidecar
(`cues`, at their resampled sample index) instead.

Loop seam: each restart is a discontinuity; the app records it as a gap and starts no join.
The file is not trimmed to make the counters wrap cleanly: the last counter is 16 and the
first 0, so the restart shows as a counter step other than 2 (and the timestamps go back).

The output is byte-deterministic for a given input and locked environment: no clock, no
randomness, fixed number formatting, sorted JSON. About 2.3 MB, so it is generated at
build time into the app bundle rather than committed.

Usage (from `worker/`):

    uv run python tools/make_demo_playback.py --out ../build/demo
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import scipy
from scipy.signal import resample_poly

from bciworkspace_worker import project_io

REPO = Path(__file__).resolve().parents[2]
EXAMPLE = REPO / "App" / "Resources" / "ExampleProject" / "S001-motor-imagery.bciproj"
RECORDING_ID = "b957806a-b565-5bda-b852-2bc61e23be9d"
SEGMENT = 0  # S001R04

CSV_NAME = "S001R04-demo-cyton-daisy-125hz.csv"
SIDECAR_NAME = "S001R04-demo-cyton-daisy-125hz.json"
TOOL_VERSION = "make_demo_playback.py v1"

# Cyton+Daisy (BrainFlow board 2). The tests check every constant against BoardShim.
BOARD_ID = 2
ROWS = 32
COUNTER_ROW, TIMESTAMP_ROW, MARKER_ROW = 0, 30, 31
EEG_ROWS = range(1, 17)
SOURCE_RATE, RATE = 160, 125
UP, DOWN = 25, 32  # 125 / 160 in lowest terms
COUNTER_STEP = 2
BASE_TIMESTAMP_S = 1_763_600_000  # fixed epoch (whole seconds); never now()
PERIOD_MS = 8  # 1000 / 125, exact
EEG_DECIMALS = 2
LOOP_SEAM = "each restart is a discontinuity; the app records it as a gap and starts no join"

# Cue labels -> nominal codes listed in the sidecar, for when markers are inserted at play
# time by a later PR. 0 means "no marker" to BrainFlow, so codes start at 1.
CUE_CODES = {"cue_left_fist": 1, "cue_right_fist": 2, "rest": 3}


def load_source(project: Path = EXAMPLE) -> tuple[project_io.Recording, Any]:
    rec = project_io.open_recording(project, RECORDING_ID)
    project_io.validate(rec)
    (segment,) = project_io.load_segments(rec, labels=CUE_CODES, only=SEGMENT)
    units = {c["label"]: c.get("unit") for c in rec.manifest["channels"]}
    wrong = {label: unit for label, unit in units.items() if unit != "uV"}
    if wrong:
        raise SystemExit(f"every source channel must be in uV; got {wrong}")
    if segment.sfreq != SOURCE_RATE:
        raise SystemExit(f"expected a {SOURCE_RATE} Hz source, got {segment.sfreq}")
    return rec, segment


def resample(data: np.ndarray) -> np.ndarray:
    """(channels, samples) at 160 Hz -> (channels, samples) at 125 Hz, one continuous segment."""
    return resample_poly(np.asarray(data, dtype=np.float64), UP, DOWN, axis=1)


def resampled_index(i: int) -> int:
    """Nearest output sample to source sample `i` (integer arithmetic, no rounding ties)."""
    return (i * UP + DOWN // 2) // DOWN


def _timestamp(i: int) -> str:
    ms = i * PERIOD_MS
    return f"{BASE_TIMESTAMP_S + ms // 1000}.{ms % 1000:03d}"


def render_csv(eeg: np.ndarray) -> str:
    if not np.all(np.isfinite(eeg)):
        raise ValueError("resampled EEG has NaN or infinite values")
    n_ch, n = eeg.shape
    if n_ch != len(EEG_ROWS):
        raise ValueError(f"expected {len(EEG_ROWS)} EEG channels, got {n_ch}")
    # + 0.0 turns -0.00 into 0.00 after rounding, so the text never depends on a sign bit.
    text = np.char.mod(f"%.{EEG_DECIMALS}f", np.round(eeg, EEG_DECIMALS) + 0.0)
    lines = []
    for i in range(n):
        row = ["0"] * ROWS
        row[COUNTER_ROW] = str((i * COUNTER_STEP) % 256)
        for k, r in enumerate(EEG_ROWS):
            row[r] = text[k, i]
        row[TIMESTAMP_ROW] = _timestamp(i)
        lines.append("\t".join(row))
    return "\n".join(lines) + "\n"


def _cues(segment: Any, n_out: int) -> list[dict[str, Any]]:
    by_code = {code: label for label, code in CUE_CODES.items()}
    out = []
    for sample, code, trial_id in segment.events:
        j = resampled_index(sample)
        if j < n_out:
            out.append({"label": by_code[code], "code": code, "trialID": trial_id,
                        "sourceSampleIndex": sample, "sampleIndex": j})
    return out


def sidecar(rec: project_io.Recording, segment: Any, n_out: int, csv_sha256: str) -> dict[str, Any]:
    manifest = rec.manifest
    src = manifest.get("source", {})
    seg_meta = next(s for s in manifest["segments"] if int(s["index"]) == SEGMENT)
    channels = [{"id": c["id"], "label": c["label"], "kind": c["kind"], "unit": c["unit"], "fileRow": row}
                for c, row in zip(manifest["channels"], EEG_ROWS)]
    return {
        "kind": "derived_playback",
        "warning": "Derived demo input: real EEG resampled from 160 Hz to 125 Hz for playback. "
                   "Not a raw recording and not from a device.",
        "generator": TOOL_VERSION,
        "file": {"name": CSV_NAME, "sha256": csv_sha256, "sampleCount": n_out,
                 "loopSeam": LOOP_SEAM, "markerRow": "all 0; cue events are listed under cues"},
        "layout": {"masterBoardID": BOARD_ID, "masterBoard": "Cyton+Daisy", "rows": ROWS,
                   "packageNumRow": COUNTER_ROW, "packageNumStep": COUNTER_STEP,
                   "eegRows": list(EEG_ROWS), "timestampRow": TIMESTAMP_ROW, "markerRow": MARKER_ROW,
                   "otherRows": "0", "timestampBase": BASE_TIMESTAMP_S,
                   "timestampPeriod": f"1/{RATE} s", "timestamps": "synthetic, play with old_timestamps"},
        "source": {
            "project": EXAMPLE.name,
            "recordingID": rec.recording_id,
            "segments": [{"index": SEGMENT, "runID": segment.run_id,
                          "sampleCount": int(segment.data.shape[1]),
                          "startedAtWall": seg_meta.get("startedAtWall")}],
            "dataset": src.get("dataset"),
            "license": src.get("license"),
            "attribution": src.get("attribution"),
        },
        "originalRateHz": SOURCE_RATE,
        "resampledRateHz": RATE,
        "method": "scipy.signal.resample_poly up=25 down=32, default Kaiser FIR",
        "methodDetails": {"scipyVersion": scipy.__version__, "padtype": "constant (scipy default)",
                          "scope": "one continuous segment; never across segment boundaries",
                          "eegDecimals": EEG_DECIMALS},
        "channels": channels,
        "montage": manifest.get("montage"),
        "reference": manifest.get("reference"),
        "cues": _cues(segment, n_out),
        "cueCodes": CUE_CODES,
    }


def build(project: Path = EXAMPLE) -> tuple[bytes, bytes]:
    rec, segment = load_source(project)
    eeg = resample(segment.data)
    csv = render_csv(eeg).encode("ascii")
    meta = sidecar(rec, segment, eeg.shape[1], hashlib.sha256(csv).hexdigest())
    side = (json.dumps(meta, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    return csv, side


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="directory to write the CSV and sidecar into")
    parser.add_argument("--project", type=Path, default=EXAMPLE, help="source .bciproj (default: the bundled example)")
    args = parser.parse_args()
    csv, side = build(args.project)
    args.out.mkdir(parents=True, exist_ok=True)
    for name, data in ((CSV_NAME, csv), (SIDECAR_NAME, side)):
        path = args.out / name
        # Rewrite only on change, so build systems that compare mtimes see no work.
        if not path.exists() or path.read_bytes() != data:
            tmp = path.with_suffix(path.suffix + ".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
        print(f"{path} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
