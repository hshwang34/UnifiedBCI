"""Causal streaming inference over a fitted model's explicit arrays (brief 006), and the
offline reference it must match.

`StreamingPredictor` is what a live session runs: samples arrive in chunks of any size,
the band-pass carries its state across chunks (`CausalFilterState`, zero state at each
segment start, `reset_on_segment_start`), and a prediction is due every `hop` samples from
segment start, for the window of the model's length ending there. `reference_segment` is
the offline form: one `filter_segment` pass over the whole segment, the same windows cut
afterwards. Both apply one validity rule (`pipeline.window_exclusion`, the rule offline
epoching uses), so a window is `insufficient_window` until it is full and starts at or after
the filter warm-up, and while a detected gap lies inside it or inside the warm-up before it.

Besides the hop grid, each registered cue gets one cue-locked window at the model's
training offset (decision #41: the live per-trial outcome). A hop window is
`feedback_eligible` only when it lies wholly inside the imagery period, from
cue + offset to the cue's end (decision #40). Eligibility is timing only; whether the bar
shows (validity, abstention, staleness) is decided in Swift.

The worker computes scores and confidences; abstention is a policy (`decide`), applied by
the app with the threshold stored per live run. Tolerances live in `TOLERANCES` and are
echoed into every parity report.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from itertools import cycle
from typing import Any, Callable, Iterable, Sequence

import numpy as np

from . import pipeline
from .project_io import DATA_GAP_EVIDENCE

# Declared parity tolerances (brief 006), absolute, float64, both paths in the worker.
TOLERANCES: dict[str, float] = {
    "bandpassed_uv": 1e-8,
    "features": 1e-9,
    "score": 1e-8,
    # A decision may differ only where the offline value sits this close to a boundary.
    "boundary_score": 1e-6,
    "boundary_confidence": 1e-9,
}
DEFAULT_HOP_SAMPLES = 16                    # 128 ms at 125 Hz
DEFAULT_ABSTAIN_THRESHOLD = 0.6             # decision #39
CHECK_EVERY = 256                           # replay checks for cancellation every this many pushes / windows

VALID = "valid"
INSUFFICIENT = "insufficient_window"
INVALID_INPUT = "invalid_input"


@dataclass(frozen=True)
class Cue:
    sample: int                             # cue onset, segment-relative sample index
    trial_id: str
    end_sample: int | None = None           # end of the imagery period; None: cue-locked window only


@dataclass
class Prediction:
    segment: int | None
    kind: str                               # "hop" | "cue_locked"
    window_start: int                       # segment-relative, half-open [start, stop)
    window_stop: int
    validity: str
    detail: str | None = None
    score: float | None = None
    confidence: float | None = None
    predicted_class: int | None = None
    features: np.ndarray | None = field(default=None, repr=False)
    trial_id: str | None = None
    feedback_eligible: bool = False
    gap: tuple[int, str] | None = None

    @property
    def key(self) -> tuple[Any, ...]:
        return (self.segment, self.kind, self.window_stop, self.trial_id)

    def to_json(self) -> dict[str, Any]:
        out = {k: getattr(self, k) for k in ("segment", "kind", "window_start", "window_stop", "validity", "detail",
                                              "score", "confidence", "predicted_class", "trial_id", "feedback_eligible")}
        out["gap"] = None if self.gap is None else {"after_sample": self.gap[0], "evidence": self.gap[1]}
        return out


@dataclass(frozen=True)
class WindowSpec:
    offset: int                             # samples from cue to the training window's start
    length: int
    hop: int
    warmup: int

    @staticmethod
    def make(sfreq: float, window: tuple[float, float], hop: int = DEFAULT_HOP_SAMPLES,
             warmup: int | None = None, sos: np.ndarray | None = None) -> "WindowSpec":
        """Seconds to samples exactly as `pipeline.epoch_segments` rounds them."""
        offset, length = int(round(window[0] * sfreq)), int(round(window[1] * sfreq))
        if length <= 0 or hop <= 0:
            raise ValueError("window length and hop must be positive")
        if warmup is None:
            if sos is None:
                raise ValueError("need the band-pass or an explicit warm-up")
            warmup = pipeline.settling_samples(sos)
        if warmup < 0:
            raise ValueError("warm-up must not be negative")
        return WindowSpec(offset, length, int(hop), int(warmup))


def decide(score: float | None, confidence: float | None, predicted_class: int | None,
           threshold: float = DEFAULT_ABSTAIN_THRESHOLD) -> int | str | None:
    """The action a policy would take: the class, `"abstain"` below the threshold, or None
    for a window without a valid score."""
    if score is None or confidence is None:
        return None
    return "abstain" if confidence < threshold else predicted_class


def _score_window(arrays: dict[str, np.ndarray], window: np.ndarray, pred: Prediction) -> None:
    with np.errstate(divide="ignore", invalid="ignore"):         # a flat window is reported, not warned
        features = pipeline.features_from_arrays(arrays, window[None])
    if not np.all(np.isfinite(features)):
        pred.validity, pred.detail = INVALID_INPUT, "non_finite_features"
        return
    score = pipeline.score_from_features(arrays, features)
    pred.features = features[0]
    pred.score = float(score[0])
    pred.confidence = float(pipeline.confidence_from_score(score[0]))
    pred.predicted_class = int(pipeline.class_from_score(arrays, score)[0])


def _judge(arrays: dict[str, np.ndarray], spec: WindowSpec, segment: int | None, kind: str, stop: int,
           n_samples: int, gaps: Sequence[tuple[int, str]], window: np.ndarray | None,
           trial_id: str | None, eligible: bool) -> Prediction:
    start = stop - spec.length
    reason, gap = pipeline.window_exclusion(start, stop, n_samples, spec.warmup, gaps)
    pred = Prediction(segment, kind, start, stop, VALID if reason is None else INSUFFICIENT, reason,
                      trial_id=trial_id, feedback_eligible=eligible, gap=gap)
    if reason is None and window is not None:
        _score_window(arrays, window, pred)
    return pred


def _eligible_trial(cues: Iterable[Cue], spec: WindowSpec, start: int, stop: int) -> str | None:
    """The trial whose imagery period holds `[start, stop)` wholly (decision #40). A window
    reaching back before the cue holds fixation data, so it never counts, whatever the offset."""
    for cue in cues:
        if cue.end_sample is not None and start >= cue.sample + max(spec.offset, 0) and stop <= cue.end_sample:
            return cue.trial_id
    return None


def _data_gaps(gaps: Iterable[tuple[int, str]]) -> list[tuple[int, str]]:
    return [(int(a), str(e)) for a, e in gaps if e in DATA_GAP_EVIDENCE]


class StreamingPredictor:
    """Chunk-by-chunk predictions for one stream at a time. Call `start_segment` at every
    segment start (it resets the filter state, the window buffer, the sample count, the
    gaps and the cues), `add_cue` as soon as a cue's sample is known, `push` per drained
    chunk, and `end_segment` when the segment ends (unfinished cue-locked windows are then
    reported as `window_exceeds_segment`, as offline)."""

    def __init__(self, arrays: dict[str, np.ndarray], n_channels: int, spec: WindowSpec):
        self.arrays = arrays
        self.n_channels = int(n_channels)
        self.spec = spec
        self._filter = pipeline.CausalFilterState(np.asarray(arrays["bandpass_sos"], dtype=np.float64), self.n_channels)
        self.segment: int | None = None
        self.start_segment(None)

    @property
    def n_samples(self) -> int:
        """Samples pushed since the segment started."""
        return self._n

    def start_segment(self, segment: int | None) -> None:
        self.segment = segment
        self._filter.reset()
        self._n = 0
        # The last `length` band-passed samples, sample i at column i % length: no copy per push.
        self._ring = np.zeros((self.n_channels, self.spec.length))
        self._gaps: list[tuple[int, str]] = []
        self._cues: list[Cue] = []
        self._pending: dict[int, list[str]] = {}       # cue-locked stop -> trial ids
        self.last_filtered = np.empty((self.n_channels, 0))

    def add_cue(self, cue: Cue) -> list[Prediction]:
        """Registers a cue of the current segment. Its cue-locked window is emitted when
        its last sample arrives; if that sample has already been pushed the window can't
        be cut any more and is returned at once as `cue_registered_late`."""
        self._cues.append(cue)
        stop = cue.sample + self.spec.offset + self.spec.length
        if stop <= self._n:
            # A window the offline reference also excludes keeps the reference's reason.
            reason, gap = pipeline.window_exclusion(stop - self.spec.length, stop, stop, self.spec.warmup, self._gaps)
            return [Prediction(self.segment, "cue_locked", stop - self.spec.length, stop, INSUFFICIENT,
                               reason or "cue_registered_late", trial_id=cue.trial_id, gap=gap)]
        self._pending.setdefault(stop, []).append(cue.trial_id)
        return []

    def push(self, chunk: np.ndarray, gaps: Iterable[tuple[int, str]] = ()) -> list[Prediction]:
        """Filters one chunk (n_channels, n) and returns every window that became due in it.
        `gaps` are this chunk's detected gaps as `(after_sample_index, evidence)`, with the
        affected sample `after + 1` inside the chunk or just after it."""
        chunk = np.asarray(chunk, dtype=np.float64)
        if chunk.ndim != 2 or chunk.shape[0] != self.n_channels:
            raise ValueError(f"chunk must be ({self.n_channels}, n), got {chunk.shape}")
        n0, n1 = self._n, self._n + chunk.shape[1]
        for after, evidence in _data_gaps(gaps):
            if not n0 - 1 <= after < n1:
                raise ValueError(f"gap after sample {after} is not in this chunk ({n0}..{n1 - 1})")
            self._gaps.append((after, evidence))
        filtered = self._filter.process(chunk)
        self.last_filtered = filtered
        first_hop = (n0 // self.spec.hop + 1) * self.spec.hop
        stops = sorted({*range(first_hop, n1 + 1, self.spec.hop), *(s for s in self._pending if n0 < s <= n1)})
        out: list[Prediction] = []
        for stop in stops:
            start = stop - self.spec.length
            window = self._window(filtered, n0, start, stop) if start >= 0 else None
            if stop % self.spec.hop == 0:
                trial = _eligible_trial(self._cues, self.spec, start, stop)
                out.append(_judge(self.arrays, self.spec, self.segment, "hop", stop, n1, self._gaps, window,
                                  trial, trial is not None))
            for trial_id in self._pending.pop(stop, []):
                out.append(_judge(self.arrays, self.spec, self.segment, "cue_locked", stop, n1, self._gaps, window,
                                  trial_id, False))
        keep = min(filtered.shape[1], self.spec.length)
        self._ring[:, np.arange(n1 - keep, n1) % self.spec.length] = filtered[:, filtered.shape[1] - keep:]
        self._n = n1
        # A cue past its imagery end can't make a later window eligible; its cue-locked window,
        # if still due, is in `_pending`. So only open cues are kept.
        self._cues = [c for c in self._cues if c.end_sample is not None and c.end_sample > n1]
        return out

    @property
    def open_cues(self) -> int:
        """Cues still able to affect a window: eligibility spans not yet over plus pending
        cue-locked windows. The live session bounds this."""
        return len({c.trial_id for c in self._cues} | {t for v in self._pending.values() for t in v})

    def _window(self, filtered: np.ndarray, n0: int, start: int, stop: int) -> np.ndarray:
        """Samples [start, stop): those before `n0` from the ring, the rest from this chunk.
        Joined only for a due window (every hop), never per push."""
        if start >= n0:
            return filtered[:, start - n0: stop - n0]
        return np.concatenate([self._ring[:, np.arange(start, n0) % self.spec.length], filtered[:, :stop - n0]], axis=1)

    def end_segment(self) -> list[Prediction]:
        out = [Prediction(self.segment, "cue_locked", stop - self.spec.length, stop, INSUFFICIENT,
                          "window_exceeds_segment", trial_id=t)
               for stop in sorted(self._pending) for t in self._pending[stop]]
        self._pending.clear()
        return out


def reference_segment(arrays: dict[str, np.ndarray], spec: WindowSpec, data: np.ndarray,
                      gaps: Iterable[tuple[int, str]] = (), cues: Sequence[Cue] = (),
                      segment: int | None = None, check: Callable[[], None] | None = None) -> tuple[list[Prediction], np.ndarray]:
    """Offline reference: `filter_segment` once over the whole segment, then the same
    windows the streaming path emits (hop grid and cue-locked), in the same order.
    Returns the predictions and the band-passed segment. `check` (cancellation) is called
    every `CHECK_EVERY` windows."""
    data = np.asarray(data, dtype=np.float64)
    filtered = pipeline.filter_segment(np.asarray(arrays["bandpass_sos"], dtype=np.float64), data)
    n = filtered.shape[1]
    gaps = _data_gaps(gaps)
    cue_stops: dict[int, list[str]] = {}
    for cue in cues:
        cue_stops.setdefault(cue.sample + spec.offset + spec.length, []).append(cue.trial_id)
    out: list[Prediction] = []
    for k, stop in enumerate(sorted({*range(spec.hop, n + 1, spec.hop), *(s for s in cue_stops if s <= n)})):
        if check and k % CHECK_EVERY == 0:
            check()
        start = stop - spec.length
        window = filtered[:, start:stop] if start >= 0 else None
        if stop % spec.hop == 0:
            trial = _eligible_trial(cues, spec, start, stop)
            out.append(_judge(arrays, spec, segment, "hop", stop, n, gaps, window, trial, trial is not None))
        for trial_id in cue_stops.get(stop, []):
            out.append(_judge(arrays, spec, segment, "cue_locked", stop, n, gaps, window, trial_id, False))
    for stop in sorted(s for s in cue_stops if s > n):
        out += [Prediction(segment, "cue_locked", stop - spec.length, stop, INSUFFICIENT, "window_exceeds_segment",
                           trial_id=t) for t in cue_stops[stop]]
    return out, filtered


def chunk_sizes(sizes: int | Sequence[int]) -> Iterable[int]:
    """An endless chunk-size sequence: one fixed size, or a list cycled."""
    if isinstance(sizes, int):
        sizes = [sizes]
    if not sizes or any(int(s) <= 0 for s in sizes):
        raise ValueError("chunk sizes must be positive")
    return cycle(int(s) for s in sizes)


def stream_segment(predictor: StreamingPredictor, data: np.ndarray, sizes: int | Sequence[int],
                   gaps: Iterable[tuple[int, str]] = (), cues: Sequence[Cue] = (),
                   segment: int | None = None, check: Callable[[], None] | None = None) -> tuple[list[Prediction], np.ndarray]:
    """Replays one recorded segment through `predictor` in chunks of `sizes`, registering
    each cue with the chunk that holds its sample (as the live path learns of it), and
    handing each gap to the chunk holding its affected sample. Returns the predictions and
    the concatenated band-passed output. `check` (cancellation) is called every
    `CHECK_EVERY` pushes."""
    data = np.asarray(data, dtype=np.float64)
    gaps = sorted(_data_gaps(gaps))
    pending_cues = sorted(cues, key=lambda c: c.sample)
    predictor.start_segment(segment)
    out: list[Prediction] = []
    filtered: list[np.ndarray] = []
    n, pos, gi, ci = data.shape[1], 0, 0, 0
    for k, size in enumerate(chunk_sizes(sizes)):
        if pos >= n:
            break
        if check and k % CHECK_EVERY == 0:
            check()
        stop = min(n, pos + size)
        while ci < len(pending_cues) and pending_cues[ci].sample < stop:
            out += predictor.add_cue(pending_cues[ci])
            ci += 1
        chunk_gaps = []
        while gi < len(gaps) and gaps[gi][0] < stop:
            chunk_gaps.append(gaps[gi])
            gi += 1
        out += predictor.push(data[:, pos:stop], chunk_gaps)
        filtered.append(predictor.last_filtered)
        pos = stop
    for cue in pending_cues[ci:]:                     # cues at or past the segment's end
        out += predictor.add_cue(cue)
    out += predictor.end_segment()
    return out, np.concatenate(filtered, axis=1) if filtered else np.empty((data.shape[0], 0))


def parity_report(streamed: Sequence[Prediction], reference: Sequence[Prediction],
                  bandpassed_deviation: float, threshold: float = DEFAULT_ABSTAIN_THRESHOLD) -> dict[str, Any]:
    """Compares streamed predictions with the offline reference window by window. Passes
    when the same windows were emitted, every validity matches, every deviation is within
    `TOLERANCES`, and decisions agree everywhere except windows on the boundary, which are
    counted and listed rather than hidden."""
    ref_by_key = {p.key: p for p in reference}
    str_by_key = {p.key: p for p in streamed}
    missing = sorted(set(ref_by_key) - set(str_by_key), key=repr)
    extra = sorted(set(str_by_key) - set(ref_by_key), key=repr)
    dev = {"features": 0.0, "score": 0.0}
    validity_mismatch, decision_mismatch, boundary = [], [], []
    first_valid: dict[str, int | None] = {}
    for key, ref in ref_by_key.items():
        seg = str(ref.segment)
        first_valid.setdefault(seg, None)
        if ref.kind == "hop" and ref.validity == VALID and (first_valid[seg] is None or ref.window_stop < first_valid[seg]):
            first_valid[seg] = ref.window_stop
        got = str_by_key.get(key)
        if got is None:
            continue
        where = {"segment": ref.segment, "kind": ref.kind, "window_stop": ref.window_stop, "trial_id": ref.trial_id}
        if (got.validity, got.detail) != (ref.validity, ref.detail):
            validity_mismatch.append({**where, "offline": [ref.validity, ref.detail], "streaming": [got.validity, got.detail]})
            continue
        if ref.score is None:
            continue
        dev["features"] = max(dev["features"], float(np.max(np.abs(got.features - ref.features))))
        dev["score"] = max(dev["score"], abs(got.score - ref.score))
        on_boundary = (abs(ref.score) <= TOLERANCES["boundary_score"]
                       or abs(ref.confidence - threshold) <= TOLERANCES["boundary_confidence"])
        if on_boundary:
            boundary.append({**where, "offline_score": ref.score, "offline_confidence": ref.confidence})
        elif decide(got.score, got.confidence, got.predicted_class, threshold) != decide(
                ref.score, ref.confidence, ref.predicted_class, threshold):
            decision_mismatch.append({**where, "offline_score": ref.score, "streaming_score": got.score})
    observed = {"bandpassed_uv": float(bandpassed_deviation), **dev}
    deviations = {q: {"tolerance": TOLERANCES[q], "observed_max": observed[q], "within": observed[q] <= TOLERANCES[q]}
                  for q in ("bandpassed_uv", "features", "score")}
    passed = (not missing and not extra and not validity_mismatch and not decision_mismatch
              and all(d["within"] for d in deviations.values()))
    return {
        "passed": passed,
        "windows_compared": len(set(ref_by_key) & set(str_by_key)),
        "tolerances": dict(TOLERANCES),
        "abstain_threshold": threshold,
        "max_deviation": deviations,
        "validity_mismatches": validity_mismatch,
        "decision_mismatches": decision_mismatch,
        "boundary_windows": boundary,
        "first_valid_window_stop": first_valid,
        "missing_windows": [list(k) for k in missing],
        "extra_windows": [list(k) for k in extra],
    }


DEFAULT_CHUNKINGS: tuple[int | str, ...] = (1, 7, 13, 125, "random")


def resolve_chunking(chunking: int | str, seed: int) -> list[int]:
    """Chunk sizes for one replay pass; "random" is a seeded mix of 1..64 samples."""
    if chunking == "random":
        return np.random.default_rng(seed).integers(1, 65, size=257).tolist()
    if isinstance(chunking, bool) or not isinstance(chunking, int) or chunking <= 0:
        raise ValueError(f"chunking {chunking!r} is not a positive sample count or 'random'")
    return [chunking]


def replay(arrays: dict[str, np.ndarray], spec: WindowSpec, segments: Sequence[tuple[int | None, np.ndarray,
           Sequence[tuple[int, str]], Sequence[Cue]]], chunkings: Sequence[int | str] = DEFAULT_CHUNKINGS,
           seed: int = 0, threshold: float = DEFAULT_ABSTAIN_THRESHOLD,
           check: Any = None) -> tuple[dict[str, Any], list[Prediction], list[Prediction]]:
    """Runs recorded segments `(index, data, gaps, cues)` through the offline reference once
    and the streaming path once per chunking. Returns the combined report (one parity report
    per chunking, `passed` only if all pass), the first chunking's streamed predictions and
    the reference predictions. `check` (cancellation) is called every `CHECK_EVERY` pushes
    or windows, in the reference pass as in every streaming pass."""
    if not chunkings:
        raise ValueError("need at least one chunking")
    reference: list[Prediction] = []
    ref_filtered: list[np.ndarray] = []
    for index, data, gaps, cues in segments:
        preds, filtered = reference_segment(arrays, spec, data, gaps, cues, index, check)
        reference += preds
        ref_filtered.append(filtered)
    passes = []
    first: list[Prediction] = []
    for chunking in chunkings:
        sizes = resolve_chunking(chunking, seed)
        predictor = StreamingPredictor(arrays, segments[0][1].shape[0], spec)
        streamed: list[Prediction] = []
        dev = 0.0
        for (index, data, gaps, cues), want in zip(segments, ref_filtered):
            preds, filtered = stream_segment(predictor, data, sizes, gaps, cues, index, check)
            streamed += preds
            dev = max(dev, float(np.max(np.abs(filtered - want))) if want.size else 0.0)
        passes.append({"chunking": chunking, "report": parity_report(streamed, reference, dev, threshold)})
        if not first:
            first = streamed
    reports = [p["report"] for p in passes]
    summary = {
        "passed": all(r["passed"] for r in reports),
        "windows_compared": reports[0]["windows_compared"],
        "tolerances": dict(TOLERANCES),
        "abstain_threshold": threshold,
        "max_deviation": {q: {"observed_max": max(r["max_deviation"][q]["observed_max"] for r in reports), "tolerance": TOLERANCES[q],
                              "within": all(r["max_deviation"][q]["within"] for r in reports)}
                          for q in ("bandpassed_uv", "features", "score")},
        "boundary_windows": reports[0]["boundary_windows"],
        "first_valid_window_stop": reports[0]["first_valid_window_stop"],
        "chunkings": passes,
    }
    return summary, first, reference
