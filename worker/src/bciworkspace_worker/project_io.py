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
every channel row (and the marker row, when there is one) inside every chunk, a positive
sample rate, well-formed detected gaps. Chunk paths are built from
the index and must resolve to a regular file inside `chunks/`; the size is checked
against `stat` before a byte is read.
"""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
import stat
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .pipeline import ModelError, Segment, validate_model_arrays


class IntegrityError(Exception):
    """A chunk's bytes do not match the manifest, or the manifest is inconsistent."""


class ProjectError(Exception):
    """The project or recording is missing, unreadable, or not the format we speak."""


FORMAT_VERSION = 1
# Gap evidence that means the samples around it are not one clean, evenly spaced sequence
# (docs/data-contracts.md). `duplicate_counter` is included: on a step-1 board BrainFlow stores a
# repeated packet as received (brief 004), so the window holds one sample twice and every later
# sample sits one period late. Nothing was lost, but the window is not what the online path would
# see on clean data, so it is excluded like a loss. receipt_interval and clock_anomaly are
# provenance only; disconnect / process_terminated sit at a segment's end, past every window.
DATA_GAP_EVIDENCE = frozenset({"sequence_skip", "stale_half", "duplicate_counter", "invalid_counter", "overflow_suspected"})
# The protocol's event for an aborted trial (brief 005); its trialID names the trial.
ABORT_LABEL = "trial_abort"


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
        gaps = seg.get("detectedGaps", [])
        if not isinstance(gaps, list) or not all(isinstance(g, dict) and isinstance(g.get("evidence"), str) for g in gaps):
            raise IntegrityError(f"recording.json: segment {seg['index']} detectedGaps is not a list of gaps")
        for g in gaps:
            if _int(g.get("afterSampleIndex"), f"segment {seg['index']} gap afterSampleIndex") < -1:
                raise IntegrityError(f"recording.json: segment {seg['index']} has a gap before sample -1")
    marker_row = m["timing"].get("markerRow") if isinstance(m["timing"], dict) else None
    if marker_row is not None:
        source_rows_and_marker = [*source_rows, _int(marker_row, "timing.markerRow")]
    else:
        source_rows_and_marker = source_rows
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
        for row in source_rows_and_marker:
            if not 0 <= row < rows:
                raise IntegrityError(f"channel or marker reads row {row}, but chunk {index} has {rows} rows")


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


def load_segments(rec: Recording, labels: dict[str, int] | None, only: int | None = None,
                  notes: dict[str, Any] | None = None) -> list[Segment]:
    """Assemble one `Segment` per stream segment from its chunks, with the events
    whose label is in `labels` (label -> class index); `labels=None` loads samples only
    and never reads `events.jsonl` (signal inspection needs no events). `only` loads just
    the segment with that index (an empty list when there is none). Chunks must tile
    each segment contiguously from sample 0; anything else is an integrity error."""
    manifest = rec.manifest
    rows = [int(c["sourceRow"]) for c in manifest["channels"]]
    events_by_segment, aborted = ({}, frozenset()) if labels is None else _events_by_segment(rec, labels, notes)
    out: list[Segment] = []
    for seg in sorted(manifest["segments"], key=lambda s: int(s["index"])):
        index = int(seg["index"])
        if only is not None and index != only:
            continue
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
        gaps = tuple((int(g["afterSampleIndex"]), str(g["evidence"])) for g in seg.get("detectedGaps", [])
                     if g["evidence"] in DATA_GAP_EVIDENCE)
        out.append(Segment(data=data, sfreq=rec.sfreq, events=events_by_segment.get(index, []),
                           run_id=str(seg["runID"]), session_id=seg.get("sessionID"), gaps=gaps, aborted_trials=aborted,
                           segment_index=index))
    return out


def _events_by_segment(rec: Recording, labels: dict[str, int],
                       notes: dict[str, Any] | None = None) -> tuple[dict[int, list[tuple[int, int, str]]], frozenset[str]]:
    """Cue events by segment, and the trial ids of `trial_abort` events (brief 005).

    Nothing a protocol recording can hold makes it unevaluable on its own. When `notes` is
    given it is filled with what the evaluation must still report:
    - `unplaced`: exclusions for trials with no sample to cut at: a cue without a sample
      association (`no_sample_for_cue`, or `trial_aborted` when its trial was aborted), and
      an aborted trial whose cue never appeared (its `trial_abort` names the planned class
      in `plannedLabel`), listed `trial_aborted` so unequal class counts stay visible.
    - `fallback`: trial ids of cues placed by `nearest_receipt_timestamp`, not a marker.
    - `truncated_line`: the number of a last line cut off mid-write (no newline, not JSON),
      which is ignored; any other malformed line is still an error.
    Without `notes` (recordings that predate brief 005 never need them) a cue without an
    association is still an error, as before."""
    path = rec.directory / "events.jsonl"
    try:
        text = _read_regular_text(path)
    except (OSError, ValueError) as exc:
        raise ProjectError(f"cannot read {path}: {exc}") from exc
    lines = text.splitlines()
    parsed: list[tuple[int, dict[str, Any]]] = []
    aborted: dict[str, dict[str, Any]] = {}
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError as exc:
            if notes is not None and n == len(lines) and not text.endswith("\n"):
                notes["truncated_line"] = n
                continue
            raise ProjectError(f"{path}:{n}: not JSON: {exc}") from exc
        if not isinstance(ev, dict):
            raise ProjectError(f"{path}:{n}: not an event object")
        if ev.get("label") == ABORT_LABEL and isinstance(ev.get("trialID"), str):
            aborted.setdefault(ev["trialID"], ev)
        else:
            parsed.append((n, ev))
    out: dict[int, list[tuple[int, int, str]]] = {}
    unplaced: dict[str, dict[str, Any]] = {}
    seen: set[str] = set()
    fallback: list[str] = []
    for n, ev in parsed:
        label = ev.get("label")
        if not isinstance(label, str) or label not in labels:
            continue
        assoc = ev.get("sampleAssociation")
        trial_id = str(ev.get("trialID") or ev.get("eventID"))
        seen.add(trial_id)
        if assoc is None and notes is not None:
            reason = "trial_aborted" if trial_id in aborted else "no_sample_for_cue"
            unplaced.setdefault(trial_id, _unplaced(trial_id, ev.get("runID"), labels[label], reason))
            continue
        if assoc is None and trial_id in aborted:
            continue
        if not isinstance(assoc, dict) or str(assoc.get("recordingID")).lower() != rec.recording_id:
            raise ProjectError(f"{path}:{n}: cue event {ev.get('eventID')} has no sample association for this recording")
        segment, sample = assoc.get("segment"), assoc.get("sampleIndex")
        if any(isinstance(v, bool) or not isinstance(v, int) for v in (segment, sample)):
            raise ProjectError(f"{path}:{n}: cue event {ev.get('eventID')} has a non-integer segment/sampleIndex")
        if assoc.get("method") == "nearest_receipt_timestamp":
            fallback.append(trial_id)
        out.setdefault(segment, []).append((sample, labels[label], trial_id))
    if notes is not None:
        for trial_id, ev in aborted.items():
            planned = ev.get("plannedLabel")
            if trial_id not in seen and isinstance(planned, str) and planned in labels:
                unplaced[trial_id] = _unplaced(trial_id, ev.get("runID"), labels[planned], "trial_aborted")
        notes["unplaced"] = sorted(unplaced.values(), key=lambda e: e["trial_id"])
        notes["fallback"] = sorted(fallback)
    for events in out.values():
        events.sort(key=lambda e: e[0])
    return out, frozenset(aborted)


def _unplaced(trial_id: str, run_id: Any, label: int, reason: str) -> dict[str, Any]:
    """An exclusion for a trial with no sample: no window to name."""
    return {"trial_id": trial_id, "run_id": str(run_id), "label": label, "reason": reason,
            "window_start_sample": None, "window_stop_sample": None}


def evaluation_notes(record: dict[str, Any], notes: dict[str, Any]) -> None:
    """Adds `_events_by_segment`'s notes to an evaluation record. Keys appear only when
    there is something to say, so records of earlier recordings keep their bytes."""
    unplaced = notes.get("unplaced") or []
    if unplaced:
        record["exclusions"] = record["exclusions"] + unplaced
        listed = {e["trial_id"] for e in unplaced}
        kept = [w for w in record.get("warnings", []) if not (w.get("kind") == "abort_names_unknown_trial" and w.get("trial_id") in listed)]
        if kept:
            record["warnings"] = kept
        else:
            record.pop("warnings", None)
    warnings = list(record.get("warnings", []))
    if notes.get("fallback"):
        warnings.append({"kind": "cue_by_nearest_timestamp", "count": len(notes["fallback"]), "trial_ids": notes["fallback"]})
    if notes.get("truncated_line"):
        warnings.append({"kind": "events_last_line_truncated", "line": notes["truncated_line"]})
    if warnings:
        record["warnings"] = warnings


def data_source(rec: Recording, segments: list[Segment]) -> dict[str, Any]:
    """What the evaluation record says about where its samples came from. Passes the
    recording's own warning through so the UI can show it beside every number."""
    src = rec.manifest.get("source", {})
    out: dict[str, Any] = {
        "kind": str(src.get("kind", "unknown")),
        "recording_id": rec.recording_id,
        "n_runs": len({s.run_id for s in segments}),   # a run may span segments
        "n_trials": sum(len(s.events) for s in segments),
        "n_channels": len(rec.channel_ids),
        "sfreq": rec.sfreq,
    }
    for key in ("dataset", "doi", "license", "subject", "runs", "warning"):
        if src.get(key) is not None:
            out[key] = src[key]
    return out


# A fitted-arrays file is a few KB to a few hundred KB (256 channels at most); anything far
# larger is not one, and is refused before it is read.
MAX_MODEL_FILE_BYTES = 4 * 1024 * 1024
MAX_MODEL_MEMBERS = 32


def load_model_arrays(path: str | Path, sha256: str | None = None, which: str = "reference",
                      n_channels: int | None = None) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
    """The validated arrays of one model in a fitted-arrays `.npz` (`validate_model_arrays`)
    and its summary, plus the file's SHA-256 in the summary. The file is hostile input: it
    must be a regular file of bounded size, a zip of `<key>.npy` members whose declared
    sizes stay bounded, loaded with `allow_pickle=False`. When `sha256` is given the bytes
    must match it, or the model is refused as changed since it was frozen."""
    path = Path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as exc:
        raise ModelError(f"cannot open model file {path.name}: {exc.strerror or exc}") from exc
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise ModelError(f"model file {path.name} is not a regular file")
        if st.st_size > MAX_MODEL_FILE_BYTES:
            raise ModelError(f"model file {path.name} is {st.st_size} bytes; at most {MAX_MODEL_FILE_BYTES} are allowed")
        raw = f.read(MAX_MODEL_FILE_BYTES + 1)
    digest = hashlib.sha256(raw).hexdigest()
    if sha256 is not None and digest != str(sha256).lower():
        raise ModelError("model file changed since it was frozen (SHA-256 does not match)")
    if not raw.startswith(b"PK\x03\x04"):
        raise ModelError(f"model file {path.name} is not an .npz archive")
    arrays: dict[str, np.ndarray] = {}
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as zf:
            infos = zf.infolist()
            if len(infos) > MAX_MODEL_MEMBERS or sum(i.file_size for i in infos) > MAX_MODEL_FILE_BYTES:
                raise ModelError(f"model file {path.name} unpacks to more than {MAX_MODEL_FILE_BYTES} bytes")
            if not all(i.filename.endswith(".npy") and "/" not in i.filename for i in infos):
                raise ModelError(f"model file {path.name} holds members that are not arrays")
        with np.load(io.BytesIO(raw), allow_pickle=False) as npz:
            for key in npz.files:
                arrays[key] = npz[key]
    except ModelError:
        raise
    except (ValueError, OSError, EOFError, zipfile.BadZipFile, KeyError) as exc:
        # allow_pickle=False turns an object array into a ValueError here: pickles never load.
        raise ModelError(f"model file {path.name} cannot be read as plain arrays: {exc}") from exc
    clean, summary = validate_model_arrays(arrays, which, n_channels)
    summary["sha256"] = digest
    return clean, summary


def cue_end_samples(rec: Recording) -> dict[str, tuple[int, int]]:
    """`cue_end` events (brief 005) by trial id, as (segment, sample index). A cue end
    without a usable sample association is left out: its trial then has no imagery span."""
    out: dict[str, tuple[int, int]] = {}
    try:
        text = _read_regular_text(rec.directory / "events.jsonl")
    except (OSError, ValueError):
        return out
    for line in text.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("label") != "cue_end" or not isinstance(ev.get("trialID"), str):
            continue
        assoc = ev.get("sampleAssociation")
        if not isinstance(assoc, dict) or str(assoc.get("recordingID")).lower() != rec.recording_id:
            continue
        segment, sample = assoc.get("segment"), assoc.get("sampleIndex")
        if all(isinstance(v, int) and not isinstance(v, bool) for v in (segment, sample)):
            out.setdefault(ev["trialID"], (segment, sample))
    return out
