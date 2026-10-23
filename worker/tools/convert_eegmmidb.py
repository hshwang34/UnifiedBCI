"""Dev-time converter: PhysioNet EEGMMIDB EDF runs -> a `.bciproj` directory.

Not shipped. Runs once, at development time, with the `mne` dev dependency; the app
never reads EDF. The output is committed as the bundled example (16 channels, three
imagery runs of subject S001) and, cropped further, as the test fixture `tiny.bciproj`.

Everything the converter does to the samples is listed in `source.derivations` of the
manifest it writes; nothing else happens to them. In particular the data stay at
160 Hz and in the file's own physical unit (microvolts, read from the EDF header,
never assumed).

The output is byte-deterministic: ids are UUIDv5 over fixed names, dates are the EDF
header start date or a fixed conversion stamp, JSON is sorted and pretty-printed.
`tests/test_convert_eegmmidb.py` re-runs this converter twice and compares bytes.

Usage (from `worker/`):

    uv run python tools/convert_eegmmidb.py --raw-dir ../build/datasets/eegmmidb \
        --out ../App/Resources/ExampleProject/S001-motor-imagery.bciproj
    uv run python tools/convert_eegmmidb.py --raw-dir ../build/datasets/eegmmidb \
        --out ../Tests/Fixtures/tiny.bciproj --preset tiny
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import numpy as np

FORMAT_VERSION = 1
CONVERTER_VERSION = "convert_eegmmidb.py v1"
SFREQ = 160.0

# Dataset facts (PhysioNet EEG Motor Movement/Imagery Dataset v1.0.0). Runs 4, 8 and 12
# are the "imagine opening and closing left or right fist" task: T1 = left fist cue,
# T2 = right fist cue, T0 = rest.
DATASET = "PhysioNet EEG Motor Movement/Imagery v1.0.0"
DATASET_DOI = "10.13026/C28G6P"
LICENSE = "ODC-BY 1.0"
SUBJECT = "S001"
RUNS = ("S001R04", "S001R08", "S001R12")
EXPECTED_SHA256 = {
    "S001R04.edf": "3d161f88e1c00632585287d2ce584c2bc0f08862438eb255ea8723e00fac693d",
    "S001R08.edf": "358fb5189220725141968ae285fbe9e3f36210b834ffba71d940af308e3aca68",
    "S001R12.edf": "2b281c9b687b4c4176e83251d74743721f2d6ebd76656a972a3b9c44d9d88cd5",
}
LABELS = {"T1": "cue_left_fist", "T2": "cue_right_fist", "T0": "rest"}
WARNING = "Public dataset, not recorded on OpenBCI Cyton+Daisy; one subject, ~22 trials per class"
ATTRIBUTION = [
    {
        "text": "Schalk, G., McFarland, D.J., Hinterberger, T., Birbaumer, N., Wolpaw, J.R. (2009). "
                "EEG Motor Movement/Imagery Dataset (version 1.0.0). PhysioNet. "
                "https://doi.org/10.13026/C28G6P",
        "doi": "10.13026/C28G6P",
    },
    {
        "text": "Schalk, G., McFarland, D.J., Hinterberger, T., Birbaumer, N., Wolpaw, J.R. (2004). "
                "BCI2000: A General-Purpose Brain-Computer Interface (BCI) System. "
                "IEEE Transactions on Biomedical Engineering 51(6):1034-1043.",
        "doi": "10.1109/TBME.2004.827072",
    },
    {
        "text": "Goldberger, A.L., Amaral, L.A.N., Glass, L., Hausdorff, J.M., Ivanov, P.C., Mark, R.G., "
                "Mietus, J.E., Moody, G.B., Peng, C.-K., Stanley, H.E. (2000). PhysioBank, PhysioToolkit, "
                "and PhysioNet: Components of a New Research Resource for Complex Physiologic Signals. "
                "Circulation 101(23):e215-e220.",
        "doi": "10.1161/01.CIR.101.23.e215",
    },
]

# 16 sensorimotor channels, in this order. Row i of every chunk is channel i.
EXAMPLE_CHANNELS = ["FC3", "FC1", "FC2", "FC4", "C5", "C3", "C1", "Cz", "C2", "C4", "C6",
                    "CP3", "CP1", "CPz", "CP2", "CP4"]
TINY_CHANNELS = ["FC3", "FC4", "C3", "C1", "Cz", "C2", "C4", "CPz"]

# Fixed so repeated conversions are byte-identical; not a real wall-clock stamp.
CONVERTED_AT = "2026-10-20T00:00:00.000Z"
NAMESPACE = uuid.UUID("7c1d4b2e-3f6a-4a2b-9c8d-5e1f0a2b3c4d")

CHUNK_SAMPLES = 160           # ~1 s per chunk at 160 Hz


@dataclass(frozen=True)
class Preset:
    name: str
    channels: list[str]
    max_seconds: float | None   # crop each run to its first N seconds (tiny fixture only)


PRESETS = {
    "example": Preset("S001 motor imagery (PhysioNet EEGMMIDB)", EXAMPLE_CHANNELS, None),
    # Three runs are the minimum the pipeline splits (one holdout run, two training runs
    # for two grouped folds); ~42 s keeps five cues per run, both classes in each.
    "tiny": Preset("tiny (EEGMMIDB S001, 8 ch, first 42 s of each run)", TINY_CHANNELS, 42.0),
}


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_edf_physical_dimensions(path: Path) -> list[str]:
    """The physical dimension of every signal, straight from the EDF header (8 ASCII
    bytes per signal after the labels and transducer fields). Read, never assumed."""
    with path.open("rb") as f:
        head = f.read(256)
        nchan = int(head[252:256])
        rest = f.read(256 * nchan)
    off = 16 * nchan + 80 * nchan
    return [rest[off + 8 * i: off + 8 * (i + 1)].decode("ascii").strip() for i in range(nchan)]


def dump_json(path: Path, obj: Any) -> None:
    path.write_text(json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n",
                    encoding="utf-8")


def stamp(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def nanos(seconds: float) -> int:
    return int(round(seconds * 1e9))


# --------------------------------------------------------------------------------------
# One run
# --------------------------------------------------------------------------------------


@dataclass
class Run:
    run_id: str
    file: Path
    data_uv: np.ndarray            # (n_channels, n_samples) float64, microvolts
    start: datetime
    annotations: list[tuple[int, str]]   # (onset sample, description)
    source_names: list[str]        # channel names as the EDF spells them, cropped order


def load_run(raw_dir: Path, run_id: str, channels: list[str], max_seconds: float | None) -> Run:
    import mne  # dev dependency only

    mne.set_log_level("ERROR")
    file = raw_dir / f"{run_id}.edf"
    digest = sha256_file(file)
    if digest != EXPECTED_SHA256[file.name]:
        raise SystemExit(f"{file}: SHA-256 {digest} does not match the expected {EXPECTED_SHA256[file.name]}; refusing to read")

    dims = read_edf_physical_dimensions(file)
    raw = mne.io.read_raw_edf(file, preload=True)
    if raw.info["sfreq"] != SFREQ:
        raise SystemExit(f"{file}: {raw.info['sfreq']} Hz, expected {SFREQ}; not resampling")
    stripped = [name.rstrip(".") for name in raw.ch_names]
    by_upper = {name.upper(): i for i, name in enumerate(stripped)}
    picks = []
    for label in channels:
        if label.upper() not in by_upper:
            raise SystemExit(f"{file}: channel {label} not in {stripped}")
        picks.append(by_upper[label.upper()])
    for i in picks:
        if dims[i] != "uV":
            raise SystemExit(f"{file}: channel {stripped[i]} physical dimension is {dims[i]!r}, expected 'uV'")
    # MNE converts to volts; `units="uV"` scales back. The file stores integers at a
    # physical resolution of (pmax - pmin) / (dmax - dmin) uV, so snap to that grid to
    # undo the two floating-point scalings exactly.
    extras = raw._raw_extras[0]
    resolution = (extras["physical_max"] - extras["physical_min"]) / (extras["digital_max"] - extras["digital_min"])
    data = raw.get_data(picks=picks, units="uV")
    res = np.asarray(resolution)[picks][:, None]
    data = np.round(data / res) * res
    if max_seconds is not None:
        data = data[:, : int(round(max_seconds * SFREQ))]
    n_samples = data.shape[1]
    annotations = []
    for onset, desc in zip(raw.annotations.onset, raw.annotations.description):
        sample = int(round(float(onset) * SFREQ))
        if sample < n_samples:
            annotations.append((sample, str(desc)))
    return Run(run_id, file, np.ascontiguousarray(data, dtype=np.float64), raw.info["meas_date"], annotations,
               [stripped[i] for i in picks])


# --------------------------------------------------------------------------------------
# Writing the project
# --------------------------------------------------------------------------------------


def write_project(raw_dir: Path, out: Path, preset: Preset) -> Path:
    runs = [load_run(raw_dir, r, preset.channels, preset.max_seconds) for r in RUNS]
    if out.exists():
        shutil.rmtree(out)
    recording_id = uuid.uuid5(NAMESPACE, f"eegmmidb/{SUBJECT}/{'+'.join(RUNS)}/{','.join(preset.channels)}/{preset.max_seconds}")
    rec_dir = out / "recordings" / str(recording_id)
    chunk_dir = rec_dir / "chunks"
    chunk_dir.mkdir(parents=True)
    (out / "pipelines").mkdir()
    (out / "results").mkdir()

    chunks: list[dict[str, Any]] = []
    segments: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    chunk_index = 0
    for seg_index, run in enumerate(runs):
        n_samples = run.data_uv.shape[1]
        for first in range(0, n_samples, CHUNK_SAMPLES):
            block = run.data_uv[:, first: first + CHUNK_SAMPLES]
            payload = block.astype("<f8").tobytes(order="C")
            name = f"{chunk_index:06d}.f64"
            (chunk_dir / name).write_bytes(payload)
            chunks.append({
                "index": chunk_index,
                "fileName": f"chunks/{name}",
                "segment": seg_index,
                "firstSampleIndex": first,
                "sampleCount": int(block.shape[1]),
                "rowCount": int(block.shape[0]),
                "sha256": hashlib.sha256(payload).hexdigest(),
                # Imports have no drain clock; the monotonic axis is sample time from the
                # start of the source file (see clockMapping.monotonicEpoch).
                "drainedAtMonotonicNanos": nanos((first + block.shape[1]) / SFREQ),
                "firstBrainflowTimestamp": None,
                "lastBrainflowTimestamp": None,
                "firstPackageNumber": None,
                "lastPackageNumber": None,
            })
            chunk_index += 1
        segments.append({
            "index": seg_index,
            "sessionID": None,
            "runID": run.run_id,
            "startedAtWall": stamp(run.start),
            "startedAtMonotonicNanos": 0,
            "endedAtMonotonicNanos": nanos(n_samples / SFREQ),
            "endReason": "stopped",
            "detectedGaps": [],
        })
        cue_count = 0
        for k, (sample, desc) in enumerate(run.annotations):
            label = LABELS[desc]
            trial_id = None
            if desc in ("T1", "T2"):
                trial_id = f"{run.run_id}-t{cue_count:02d}"
                cue_count += 1
            events.append({
                "eventID": str(uuid.uuid5(NAMESPACE, f"{recording_id}/{run.run_id}/annotation/{k}")),
                "sessionID": None,
                "runID": run.run_id,
                "trialID": trial_id,
                "label": label,
                "origin": "protocol",
                "intendedAtMonotonicNanos": None,
                "presentedAtMonotonicNanos": None,
                "sourceTimeNanos": None,
                "wallTime": stamp(run.start + timedelta(milliseconds=round(sample / SFREQ * 1000))),
                "sampleAssociation": {
                    "recordingID": str(recording_id),
                    "segment": seg_index,
                    "sampleIndex": sample,
                    "method": "edf_annotation_onset",
                },
                "timingUncertaintyNanos": None,
            })

    derivations = [
        f"channels: cropped from 64 to {len(preset.channels)} ({', '.join(preset.channels)}); chunk row i is channel i",
        "channel names: trailing dots stripped and case normalized to the 10-10 convention (Fc3. -> FC3)",
        "units: EDF physical dimension 'uV' read from the header; values stored in uV as float64 "
        "(MNE reads volts; scaled back by 1e6 and snapped to the file's physical resolution)",
        "sample rate: 160 Hz as recorded; not resampled",
        "events: EDF+ annotations T1 -> cue_left_fist, T2 -> cue_right_fist, T0 -> rest, associated by onset sample",
    ]
    if preset.max_seconds is not None:
        derivations.append(f"duration: each run cropped to its first {preset.max_seconds:g} s (test fixture only)")

    manifest = {
        "formatVersion": FORMAT_VERSION,
        "recordingID": str(recording_id),
        # The dataset does not document which runs were one sitting (every EDF carries the
        # same placeholder start date), so no session is claimed: nil -> unknown-session.
        "sessionID": None,
        "runID": "+".join(RUNS),
        "createdAt": CONVERTED_AT,
        "source": {
            "kind": "public_dataset",
            "boardID": None,
            "boardName": "BCI2000 / g.tec (per Schalk 2004)",
            "dataPath": None,
            "brainflowVersion": "n/a",
            "appVersion": CONVERTER_VERSION,
            "dataset": DATASET,
            "doi": DATASET_DOI,
            "license": LICENSE,
            "subject": SUBJECT,
            "runs": list(RUNS),
            "warning": WARNING,
            "attribution": ATTRIBUTION,
            "derivations": derivations,
            "sourceFiles": [{"name": r.file.name, "sha256": EXPECTED_SHA256[r.file.name]} for r in runs],
        },
        "channels": [
            {"id": f"ch{i:02d}", "label": label, "kind": "eeg", "unit": "uV", "sourceRow": i}
            for i, label in enumerate(preset.channels)
        ],
        "reference": "per dataset documentation",
        "montage": f"international 10-10 (BCI2000 64-ch subset), cropped to {len(preset.channels)}",
        "timing": {
            "nominalSampleRateHz": SFREQ,
            "timestampClock": "host_wall",
            "timestampGeneratedBy": "none",
            "sequenceCounterRow": None,
            "sequenceStep": 1,
            "notes": "EDF import: no per-sample timestamps or sequence counters exist; sample time is index / 160 Hz "
                     "from the start of each run's file. Gaps cannot be detected from stored data.",
        },
        "clockMapping": {
            "monotonicEpoch": "synthetic: nanoseconds of sample time since the first sample of the source file",
            "anchorMonotonicNanos": 0,
            "anchorWall": stamp(runs[0].start),
        },
        "boardConfiguration": {"requested": {}, "readback": {}},
        "chunks": chunks,
        "segments": segments,
    }
    dump_json(rec_dir / "recording.json", manifest)
    with (rec_dir / "events.jsonl").open("w", encoding="utf-8") as f:
        for e in events:
            f.write(json.dumps(e, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n")
    dump_json(out / "project.json", {"formatVersion": FORMAT_VERSION, "name": preset.name, "created": CONVERTED_AT})
    (out / "README.md").write_text(readme(preset), encoding="utf-8")
    return out


def readme(preset: Preset) -> str:
    cites = "\n".join(f"- {c['text']} doi:{c['doi']}" for c in ATTRIBUTION)
    return f"""# {preset.name}

**{WARNING}.**

This project was converted from the PhysioNet EEG Motor Movement/Imagery Dataset
(v1.0.0, doi:{DATASET_DOI}), subject {SUBJECT}, runs {', '.join(RUNS)} ("imagine opening and
closing left or right fist"). Channels: {', '.join(preset.channels)} at 160 Hz, microvolts.
Every conversion step is listed in `recording.json` under `source.derivations`.

## License

The dataset is distributed under the Open Data Commons Attribution License v1.0
(ODC-BY 1.0, <https://opendatacommons.org/licenses/by/1-0/>). You are free to share,
create works from and adapt the data provided you attribute it as requested by the
licensor. This converted copy carries the same license.

## Attribution

{cites}

Converted by `worker/tools/convert_eegmmidb.py` ({CONVERTER_VERSION}).
"""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--raw-dir", type=Path, required=True, help="directory with S001R04/08/12.edf")
    ap.add_argument("--out", type=Path, required=True, help="output .bciproj directory (replaced)")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="example")
    args = ap.parse_args(argv)
    out = write_project(args.raw_dir, args.out, PRESETS[args.preset])
    total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"wrote {out} ({total / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
