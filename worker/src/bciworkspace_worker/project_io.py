"""Read-only access to a `.bciproj` recording for the worker.

Mirrors docs/data-contracts.md: `recording.json` lists immutable chunk files with a
SHA-256 each; `events.jsonl` holds one event per line. Binary samples are read from
those files directly (never sent over the protocol pipe), and every chunk is verified
against its listed hash before a single sample is used. A mismatch is an
`IntegrityError`, which the server reports under the error code `integrity`; the
worker never repairs or skips a bad chunk.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .pipeline import Segment


class IntegrityError(Exception):
    """A chunk's bytes do not match the manifest, or the manifest is inconsistent."""


class ProjectError(Exception):
    """The project or recording is missing, unreadable, or not the format we speak."""


FORMAT_VERSION = 1


@dataclass(frozen=True)
class Recording:
    directory: Path
    manifest: dict[str, Any]

    @property
    def recording_id(self) -> str:
        return str(self.manifest["recordingID"])

    @property
    def sfreq(self) -> float:
        return float(self.manifest["timing"]["nominalSampleRateHz"])

    @property
    def channel_ids(self) -> list[str]:
        return [str(c["id"]) for c in self.manifest["channels"]]


def open_recording(project_dir: str | Path, recording_id: str) -> Recording:
    project_dir = Path(project_dir)
    try:
        project = json.loads((project_dir / "project.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read project.json in {project_dir}: {exc}") from exc
    if project.get("formatVersion") != FORMAT_VERSION:
        raise ProjectError(f"project format version {project.get('formatVersion')!r} is not {FORMAT_VERSION}")
    rec_dir = project_dir / "recordings" / recording_id
    try:
        manifest = json.loads((rec_dir / "recording.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read recording {recording_id}: {exc}") from exc
    if manifest.get("formatVersion") != FORMAT_VERSION:
        raise ProjectError(f"recording format version {manifest.get('formatVersion')!r} is not {FORMAT_VERSION}")
    if str(manifest.get("recordingID")) != recording_id:
        raise ProjectError(f"recording.json in {rec_dir} names {manifest.get('recordingID')!r}, not {recording_id!r}")
    return Recording(rec_dir, manifest)


def read_chunk(rec: Recording, entry: dict[str, Any]) -> np.ndarray:
    """One chunk as (rowCount, sampleCount) float64, verified against its SHA-256."""
    path = rec.directory / entry["fileName"]
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise IntegrityError(f"chunk {entry['fileName']} is missing: {exc}") from exc
    digest = hashlib.sha256(raw).hexdigest()
    if digest != entry["sha256"]:
        raise IntegrityError(f"chunk {entry['fileName']}: SHA-256 {digest} does not match the manifest's {entry['sha256']}")
    rows, count = int(entry["rowCount"]), int(entry["sampleCount"])
    if len(raw) != rows * count * 8:
        raise IntegrityError(f"chunk {entry['fileName']}: {len(raw)} bytes is not {rows} x {count} float64")
    return np.frombuffer(raw, dtype="<f8").reshape(rows, count)


def load_segments(rec: Recording, labels: dict[str, int]) -> list[Segment]:
    """Assemble one `Segment` per stream segment from its chunks, with the events
    whose label is in `labels` (label -> class index). Chunks must tile each segment
    contiguously from sample 0; anything else is an integrity error, not a repair."""
    manifest = rec.manifest
    rows = [int(c["sourceRow"]) for c in manifest["channels"]]
    events_by_segment = _events_by_segment(rec, labels)
    out: list[Segment] = []
    for seg in sorted(manifest["segments"], key=lambda s: int(s["index"])):
        index = int(seg["index"])
        entries = sorted((c for c in manifest["chunks"] if int(c["segment"]) == index), key=lambda c: int(c["firstSampleIndex"]))
        blocks = []
        expected = 0
        for entry in entries:
            if int(entry["firstSampleIndex"]) != expected:
                raise IntegrityError(f"segment {index}: chunk {entry['fileName']} starts at sample {entry['firstSampleIndex']}, expected {expected}")
            block = read_chunk(rec, entry)
            blocks.append(block[rows])
            expected += block.shape[1]
        if not blocks:
            raise IntegrityError(f"segment {index} ({seg['runID']}) has no chunks")
        data = np.concatenate(blocks, axis=1)
        out.append(Segment(data=data, sfreq=rec.sfreq, events=events_by_segment.get(index, []),
                           run_id=str(seg["runID"]), session_id=seg.get("sessionID")))
    return out


def _events_by_segment(rec: Recording, labels: dict[str, int]) -> dict[int, list[tuple[int, int, str]]]:
    path = rec.directory / "events.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProjectError(f"cannot read {path}: {exc}") from exc
    out: dict[int, list[tuple[int, int, str]]] = {}
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError as exc:
            raise ProjectError(f"{path}:{n}: not JSON: {exc}") from exc
        label = ev.get("label")
        if label not in labels:
            continue
        assoc = ev.get("sampleAssociation")
        if not isinstance(assoc, dict) or str(assoc.get("recordingID")) != rec.recording_id:
            raise ProjectError(f"{path}:{n}: cue event {ev.get('eventID')} has no sample association for this recording")
        trial_id = ev.get("trialID") or str(ev.get("eventID"))
        out.setdefault(int(assoc["segment"]), []).append((int(assoc["sampleIndex"]), labels[label], str(trial_id)))
    for events in out.values():
        events.sort(key=lambda e: e[0])
    return out


def data_source(rec: Recording, segments: list[Segment]) -> dict[str, Any]:
    """What the evaluation record says about where its samples came from. Passes the
    recording's own warning through so the UI can show it beside every number."""
    src = rec.manifest.get("source", {})
    out: dict[str, Any] = {
        "kind": str(src.get("kind", "unknown")),
        "recording_id": rec.recording_id,
        "n_runs": len(segments),
        "n_trials": sum(len(s.events) for s in segments),
        "n_channels": len(rec.channel_ids),
        "sfreq": rec.sfreq,
    }
    for key in ("dataset", "doi", "license", "subject", "runs", "warning"):
        if src.get(key) is not None:
            out[key] = src[key]
    return out
