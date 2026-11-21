"""Brief 005 PR 2: protocol recordings through `fit_evaluate_project`, and proof that
recordings made before brief 005 evaluate byte-for-byte as they did.

A protocol recording is written here by hand in the on-disk format (docs/data-contracts.md):
four runs, one of them split across two segments by a reconnect, cue labels from the default
protocol, one `trial_abort` event and one `sequence_skip` gap inside a trial window.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path

import numpy as np

from bciworkspace_worker import pipeline, project_io
from test_project import EXAMPLE, TINY, expect_integrity, hostile_copy, params, run_in_process, run_in_subprocess

SFREQ = 125.0
LABELS = {"left": "cue_left_hand", "right": "cue_right_hand"}

# SHA-256 of the `evaluation` bytes for recordings that predate brief 005, computed with the
# worker at origin/main 30377f0 (before this change). Stored results link to reruns by byte
# identity (`reproductionOf`), so a change here would turn every rerun into `divergedFrom`.
BEFORE_005 = {
    ("tiny", 0): "60ce632215556b0777e353aadeb06a83be3ee9d48ec6445b1d53220b51a2ed9d",
    ("tiny", 3): "c5d4cff339f16f5d2d8c5cbc10d986a3f45dcd9ccd5a496b07f7d96a5fe9edea",
    ("example", 0): "dc7596748834308e631e4874ab1209af5f2f0f121e4e9976507b93db2f0e1d75",
}


def test_recordings_from_before_brief_005_evaluate_byte_for_byte_as_before():
    for (name, seed), digest in BEFORE_005.items():
        raw, _ = run_in_subprocess(params(TINY if name == "tiny" else EXAMPLE, seed=seed))
        assert hashlib.sha256(raw).hexdigest() == digest, (name, seed)


def write_protocol_project(tmp_path: Path) -> tuple[Path, str, dict]:
    """A `.bciproj` holding one protocol recording; returns (project, recording id, facts)."""
    runs = pipeline.make_synthetic_runs(n_runs=4, trials_per_run=10, n_channels=8, sfreq=SFREQ, seed=5)
    rid = str(uuid.UUID(int=5)).upper()
    project = tmp_path / "proto.bciproj"
    rec_dir = project / "recordings" / rid
    (rec_dir / "chunks").mkdir(parents=True)
    (project / "project.json").write_text(json.dumps({"formatVersion": 1, "name": "proto", "created": "2026-11-20T00:00:00.000Z"}))
    marker_row = 8                                    # chunk rows: 8 channels, then the marker row
    # Run 1 is cut by a reconnect between its 5th and 6th trial: two segments, one run.
    cut = runs[1].events[5][0] - int(0.5 * SFREQ)
    pieces = [(runs[0], 0, None), (runs[1], 0, cut), (runs[1], cut, None), (runs[2], 0, None), (runs[3], 0, None)]
    chunks, segments, events = [], [], []
    for index, (run, lo, hi) in enumerate(pieces):
        data = run.data[:, lo:hi]
        block = np.vstack([data, np.zeros((1, data.shape[1]))])
        raw = block.astype("<f8").tobytes()
        name = project_io.chunk_file_name(index)
        (rec_dir / name).write_bytes(raw)
        chunks.append({"index": index, "fileName": name, "segment": index, "firstSampleIndex": 0, "sampleCount": data.shape[1],
                       "rowCount": block.shape[0], "sha256": hashlib.sha256(raw).hexdigest()})
        segments.append({"index": index, "runID": run.run_id, "sessionID": "S1", "detectedGaps": []})
        for sample, label, trial in run.events:
            if lo <= sample < (hi if hi is not None else data.shape[1] + lo):
                events.append({"eventID": str(uuid.uuid4()), "runID": run.run_id, "trialID": f"{run.run_id}-{trial}",
                               "label": LABELS["left"] if label == 0 else LABELS["right"], "origin": "protocol",
                               "sampleAssociation": {"recordingID": rid, "segment": index, "sampleIndex": int(sample - lo),
                                                     "method": "brainflow_marker"}})
    aborted = f"run02-{runs[2].events[3][2]}"
    events.append({"eventID": str(uuid.uuid4()), "runID": "run02", "trialID": aborted, "label": "trial_abort", "origin": "operator"})
    gap_trial = runs[3].events[6]
    segments[4]["detectedGaps"] = [{"afterSampleIndex": gap_trial[0] + int(1.0 * SFREQ), "evidence": "sequence_skip",
                                    "estimatedMissingSamples": 2, "ambiguous": True},
                                   {"afterSampleIndex": 3, "evidence": "receipt_interval", "estimatedMissingSamples": None, "ambiguous": False}]
    manifest = {"formatVersion": 1, "recordingID": rid, "sessionID": "S1", "runID": "run00",
                "source": {"kind": "synthetic"}, "timing": {"nominalSampleRateHz": SFREQ, "markerRow": marker_row},
                "channels": [{"id": f"ch{c:02d}", "sourceRow": c} for c in range(8)], "chunks": chunks, "segments": segments}
    (rec_dir / "recording.json").write_text(json.dumps(manifest))
    (rec_dir / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    return project, rid, {"aborted": aborted, "gap": f"run03-{gap_trial[2]}", "n_cues": sum(1 for e in events if e["origin"] == "protocol")}


def test_protocol_recording_evaluates_with_its_labels_runs_and_exclusions(tmp_path):
    project, rid, facts = write_protocol_project(tmp_path)
    out, _ = run_in_process({"project_dir": str(project), "recording_id": rid, "seed": 0, "labels": LABELS})
    ev = out["evaluation"]
    reasons = {e["trial_id"]: e["reason"] for e in ev["exclusions"]}
    assert reasons[facts["aborted"]] == "trial_aborted"
    assert reasons[facts["gap"]] == "window_spans_detected_gap"
    assert set(reasons.values()) <= {"trial_aborted", "window_spans_detected_gap", "window_exceeds_segment"}, reasons
    assert ev["data_source"]["n_runs"] == 4, "two segments of one run are one run"
    assert ev["data_source"]["n_trials"] == facts["n_cues"]
    m = ev["split_manifest"]
    assert sorted(m["holdout_runs"] + m["training_runs"]) == ["run00", "run01", "run02", "run03"]
    assert ev["split_policy"]["evidence"] == "same-session"
    assert (out["pipeline"]["configuration"]["label_left"], out["pipeline"]["configuration"]["label_right"]) == ("cue_left_hand", "cue_right_hand")
    used = len(m["holdout_trials"]) + sum(ev["class_counts"]["train"])
    assert used + len(ev["exclusions"]) == facts["n_cues"]


def test_marker_row_outside_a_chunk_is_an_integrity_error(tmp_path):
    def edit(m, rec_dir):
        m["timing"]["markerRow"] = m["chunks"][0]["rowCount"]
    assert "marker" in expect_integrity(hostile_copy(tmp_path, edit))


def test_malformed_detected_gaps_are_an_integrity_error(tmp_path):
    def edit(m, rec_dir):
        m["segments"][0]["detectedGaps"] = [{"afterSampleIndex": "3", "evidence": "sequence_skip"}]
    assert "afterSampleIndex" in expect_integrity(hostile_copy(tmp_path / "a", edit))

    def edit2(m, rec_dir):
        m["segments"][0]["detectedGaps"] = {"evidence": "sequence_skip"}
    assert "detectedGaps" in expect_integrity(hostile_copy(tmp_path / "b", edit2))


def test_a_pre_005_single_segment_recording_with_gaps_now_excludes_the_trials_it_touches(tmp_path):
    """Behaviour change (brief 005): an ordinary one-segment recording made before this brief,
    with counter gaps in its manifest, used to keep every trial. Now each trial whose window or
    filter warm-up holds a data-gap sample is excluded and listed; provenance-only evidence
    (receipt_interval, clock_anomaly) still excludes nothing."""
    run = pipeline.make_synthetic_runs(n_runs=1, trials_per_run=12, n_channels=8, sfreq=SFREQ, seed=8)[0]
    rid = str(uuid.UUID(int=8)).upper()
    project = tmp_path / "gaps.bciproj"
    rec_dir = project / "recordings" / rid
    (rec_dir / "chunks").mkdir(parents=True)
    (project / "project.json").write_text(json.dumps({"formatVersion": 1, "name": "g", "created": "2026-11-01T00:00:00.000Z"}))
    raw = run.data.astype("<f8").tobytes()
    (rec_dir / "chunks" / "000000.f64").write_bytes(raw)
    ev = run.events
    off, length = int(0.5 * SFREQ), int(2.0 * SFREQ)       # the default window below
    gaps = [(ev[2][0] + off + 50, "sequence_skip"), (ev[4][0] + off + 1, "stale_half"),
            (ev[6][0] + off + length - 2, "duplicate_counter"), (ev[8][0] + off - 30, "overflow_suspected"),
            (ev[9][0] + off + 40, "receipt_interval"), (ev[10][0] + off + 40, "clock_anomaly")]
    manifest = {"formatVersion": 1, "recordingID": rid, "sessionID": None, "runID": run.run_id, "source": {"kind": "brainflow"},
                "timing": {"nominalSampleRateHz": SFREQ}, "channels": [{"id": f"ch{c:02d}", "sourceRow": c} for c in range(8)],
                "chunks": [{"index": 0, "fileName": "chunks/000000.f64", "segment": 0, "firstSampleIndex": 0, "sampleCount": run.data.shape[1],
                            "rowCount": 8, "sha256": hashlib.sha256(raw).hexdigest()}],
                "segments": [{"index": 0, "runID": run.run_id, "sessionID": None,
                              "detectedGaps": [{"afterSampleIndex": a, "evidence": e, "estimatedMissingSamples": None, "ambiguous": False} for a, e in gaps]}]}
    (rec_dir / "recording.json").write_text(json.dumps(manifest))
    (rec_dir / "events.jsonl").write_text("".join(json.dumps({
        "eventID": str(uuid.uuid4()), "trialID": t, "label": LABELS["left"] if lab == 0 else LABELS["right"],
        "sampleAssociation": {"recordingID": rid, "segment": 0, "sampleIndex": int(smp)}}) + "\n" for smp, lab, t in ev))
    rec = project_io.open_recording(project, rid)
    (seg,) = project_io.load_segments(rec, {LABELS["left"]: 0, LABELS["right"]: 1})
    sos = pipeline.BandpassSpec().design(SFREQ)
    epochs = pipeline.epoch_segments([seg], sos, (0.5, 2.0), pipeline.settling_samples(sos))
    pinned = {(e["trial_id"], e["gap_evidence"]) for e in epochs.exclusions if e["reason"] == "window_spans_detected_gap"}
    assert pinned == {(ev[2][2], "sequence_skip"), (ev[4][2], "stale_half"), (ev[6][2], "duplicate_counter"), (ev[8][2], "overflow_suspected")}
    kept = set(epochs.trial_ids.tolist())
    assert {ev[9][2], ev[10][2]} <= kept, "provenance-only evidence excludes nothing"
    assert len(kept) + len(epochs.exclusions) == len(ev)
