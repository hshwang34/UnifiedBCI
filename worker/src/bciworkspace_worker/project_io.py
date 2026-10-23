"""Read-only access to a `.bciproj` recording for the worker.

Mirrors docs/data-contracts.md: `recording.json` lists immutable chunk files with a
SHA-256 each; `events.jsonl` holds one event per line. Binary samples are read from
those files directly (never sent over the protocol pipe), and every chunk is verified
against its listed hash before a single sample is used. A mismatch is an
`IntegrityError`, which the server reports under the error code `integrity`; the
worker never repairs or skips a bad chunk.

A `.bciproj` may come from anyone, so `recording.json` is hostile input. `validate`
applies the same rules as Swift's `RecordingHandle.validate` before anything is read:
canonical chunk names (`chunks/NNNNNN.f64` for the entry's index), positive dimensions,
every channel row inside every chunk, a positive sample rate. Chunk paths are built from
the index and must resolve to a regular file inside `chunks/`; the size is checked
against `stat` before a byte is read.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import stat
import uuid
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
        # UUIDs compare case-insensitively: Swift writes them upper-case, the converter lower.
        return str(self.manifest["recordingID"]).lower()

    @property
    def sfreq(self) -> float:
        return float(self.manifest["timing"]["nominalSampleRateHz"])

    @property
    def channel_ids(self) -> list[str]:
        return [str(c["id"]) for c in self.manifest["channels"]]


def _read_regular_text(path: Path) -> str:
    """UTF-8 text of `path`, refusing anything but a regular file: a FIFO planted in
    place of a manifest would otherwise block the worker forever."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError(f"{path.name} is not a regular file")
        return f.read().decode("utf-8")


def chunk_file_name(index: int) -> str:
    """The canonical chunk name for an index; the only form a manifest may list."""
    return f"chunks/{index:06d}.f64"


def open_recording(project_dir: str | Path, recording_id: str) -> Recording:
    project_dir = Path(project_dir)
    try:
        uuid.UUID(recording_id)
    except ValueError as exc:
        raise ProjectError(f"recording id {recording_id!r} is not a UUID") from exc
    try:
        project = json.loads(_read_regular_text(project_dir / "project.json"))
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read project.json in {project_dir}: {exc}") from exc
    version = project.get("formatVersion") if isinstance(project, dict) else None
    if version != FORMAT_VERSION:
        raise ProjectError(f"project format version {version!r} is not {FORMAT_VERSION}")
    rec_dir = project_dir / "recordings" / recording_id
    try:
        manifest = json.loads(_read_regular_text(rec_dir / "recording.json"))
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read recording {recording_id}: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ProjectError(f"recording.json in {rec_dir} is not a JSON object")
    if manifest.get("formatVersion") != FORMAT_VERSION:
        raise ProjectError(f"recording format version {manifest.get('formatVersion')!r} is not {FORMAT_VERSION}")
    if str(manifest.get("recordingID")).lower() != recording_id.lower():
        raise ProjectError(f"recording.json in {rec_dir} names {manifest.get('recordingID')!r}, not {recording_id!r}")
    rec = Recording(rec_dir, manifest)
    validate(rec)
    return rec


def _int(value: Any, what: str) -> int:
    # bool is an int subclass in Python; JSON `true` is not a row number.
    if isinstance(value, bool) or not isinstance(value, int):
        raise IntegrityError(f"recording.json: {what} is {value!r}, not an integer")
    return value


def validate(rec: Recording) -> None:
    """Structural checks on a decoded manifest (Swift: `RecordingHandle.validate`).
    Every failure is an `IntegrityError`; nothing is repaired or clamped."""
    m = rec.manifest
    chunks, channels, segments = m.get("chunks"), m.get("channels"), m.get("segments")
    for name, value in (("chunks", chunks), ("channels", channels), ("segments", segments)):
        if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
            raise IntegrityError(f"recording.json: {name} is not a list of objects")
    try:
        sfreq = float(m["timing"]["nominalSampleRateHz"])
    except (KeyError, TypeError, ValueError) as exc:
        raise IntegrityError(f"recording.json: sample rate (timing.nominalSampleRateHz) is not a number: {exc}") from exc
    if not (math.isfinite(sfreq) and sfreq > 0):
        raise IntegrityError(f"recording.json: sample rate {sfreq!r} is not positive")
    if not isinstance(m.get("source", {}), dict):
        raise IntegrityError("recording.json: source is not an object")
    if not all(isinstance(c.get("id"), str) for c in channels):
        raise IntegrityError("recording.json: a channel has no string id")
    source_rows = [_int(c.get("sourceRow"), f"channel {c.get('id')!r} sourceRow") for c in channels]
    for seg in segments:
        if _int(seg.get("index"), "segment index") < 0:
            raise IntegrityError(f"recording.json: segment index {seg['index']} is negative")
        if not isinstance(seg.get("runID"), str) or not isinstance(seg.get("sessionID"), (str, type(None))):
            raise IntegrityError(f"recording.json: segment {seg['index']} has no string runID")
    seen: set[int] = set()
    for entry in chunks:
        index = _int(entry.get("index"), "chunk index")
        if index < 0 or index in seen:
            raise IntegrityError(f"chunk index {index} is negative or duplicated")
        seen.add(index)
        if entry.get("fileName") != chunk_file_name(index):
            raise IntegrityError(f"chunk {index} names {entry.get('fileName')!r}, not {chunk_file_name(index)!r}")
        rows = _int(entry.get("rowCount"), f"chunk {index} rowCount")
        count = _int(entry.get("sampleCount"), f"chunk {index} sampleCount")
        first = _int(entry.get("firstSampleIndex"), f"chunk {index} firstSampleIndex")
        segment = _int(entry.get("segment"), f"chunk {index} segment")
        if rows <= 0 or count <= 0 or first < 0 or segment < 0:
            raise IntegrityError(f"chunk {index} has non-positive dimensions")
        if rows * count * 8 > 2**63 - 1:
            raise IntegrityError(f"chunk {index}: {rows}x{count} float64 overflows")
        if not isinstance(entry.get("sha256"), str):
            raise IntegrityError(f"chunk {index} has no SHA-256")
        for row in source_rows:
            if not 0 <= row < rows:
                raise IntegrityError(f"channel reads row {row}, but chunk {index} has {rows} rows")


def _chunk_path(rec: Recording, index: int) -> Path:
    """The chunk's path built from its index, confirmed to be a regular file (not a
    symlink, FIFO or device) whose resolved location is inside this recording's `chunks/`."""
    name = chunk_file_name(index)
    path = rec.directory / name
    try:
        st = os.lstat(path)
    except OSError as exc:
        raise IntegrityError(f"chunk {name} is missing: {exc}") from exc
    if not stat.S_ISREG(st.st_mode):
        raise IntegrityError(f"chunk {name} is not a regular file")
    # `chunks` itself is not resolved, so a `chunks` symlink pointing elsewhere fails too.
    chunk_dir = rec.directory.resolve() / "chunks"
    if path.resolve().parent != chunk_dir:
        raise IntegrityError(f"chunk {name} resolves outside the recording directory")
    return path


def read_chunk(rec: Recording, entry: dict[str, Any]) -> np.ndarray:
    """One chunk as (rowCount, sampleCount) float64, verified against its size (before
    reading) and SHA-256. `entry` must have passed `validate`."""
    name = chunk_file_name(entry["index"])
    rows, count = entry["rowCount"], entry["sampleCount"]
    expected = rows * count * 8
    path = _chunk_path(rec, entry["index"])
    # O_NOFOLLOW closes the window between the lstat above and the open.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        raise IntegrityError(f"chunk {name} cannot be opened: {exc}") from exc
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise IntegrityError(f"chunk {name} is not a regular file")
        if st.st_size != expected:
            raise IntegrityError(f"chunk {name}: {st.st_size} bytes is not {rows} x {count} float64")
        raw = f.read(expected + 1)
    if len(raw) != expected:
        raise IntegrityError(f"chunk {name}: read {len(raw)} bytes, expected {expected}")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != entry["sha256"]:
        raise IntegrityError(f"chunk {name}: SHA-256 {digest} does not match the manifest's {entry['sha256']}")
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
        lines = _read_regular_text(path).splitlines()
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read {path}: {exc}") from exc
    out: dict[int, list[tuple[int, int, str]]] = {}
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError as exc:
            raise ProjectError(f"{path}:{n}: not JSON: {exc}") from exc
        if not isinstance(ev, dict):
            raise ProjectError(f"{path}:{n}: not an event object")
        label = ev.get("label")
        if not isinstance(label, str) or label not in labels:
            continue
        assoc = ev.get("sampleAssociation")
        if not isinstance(assoc, dict) or str(assoc.get("recordingID")).lower() != rec.recording_id:
            raise ProjectError(f"{path}:{n}: cue event {ev.get('eventID')} has no sample association for this recording")
        trial_id = ev.get("trialID") or str(ev.get("eventID"))
        segment, sample = assoc.get("segment"), assoc.get("sampleIndex")
        if any(isinstance(v, bool) or not isinstance(v, int) for v in (segment, sample)):
            raise ProjectError(f"{path}:{n}: cue event {ev.get('eventID')} has a non-integer segment/sampleIndex")
        out.setdefault(segment, []).append((sample, labels[label], str(trial_id)))
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
