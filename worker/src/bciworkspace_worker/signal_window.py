"""A bounded view of one segment's samples for the Quality tab's trace view (brief 002).

`window` cuts at most `MAX_WINDOW_S` seconds out of a segment and reduces every channel to
at most `MAX_POINTS` points, each the min and max of its run of samples (an envelope), so
a peak survives decimation and no raw data crosses the pipe in bulk.

The band-passed trace is the evaluation's processed signal: the unmodified samples, one
causal pass of the reference `BandpassSpec` over the whole segment from zero state
(`pipeline.filter_segment`, as `quality.inspect_segment` does for the spectrum), cut to the
window afterwards. Samples inside the filter warm-up (`settling_samples`) are returned,
not dropped; `warmup_end_s` says where the warm-up ends so the view can mark it.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from . import pipeline, quality

MAX_WINDOW_S = 30.0
MAX_POINTS = 2000
TRACES = ("raw", "bandpassed")
WHICH = {"raw": ("raw",), "bandpassed": ("bandpassed",), "both": TRACES}

NON_FINITE = "channel contains non-finite samples"


def _num(x: float) -> float | None:
    return float(x) if np.isfinite(x) else None


def envelope(x: np.ndarray, starts: np.ndarray) -> dict[str, Any]:
    """Per bucket (from each start to the next), the min and max of the finite samples;
    null for a bucket with none. `lo`/`hi` are the window's extremes."""
    with np.errstate(invalid="ignore"):
        lo = np.fmin.reduceat(x, starts, axis=-1)
        hi = np.fmax.reduceat(x, starts, axis=-1)
    finite = x[np.isfinite(x)]
    return {"min": [_num(v) for v in lo], "max": [_num(v) for v in hi],
            "lo": _num(finite.min()) if finite.size else None,
            "hi": _num(finite.max()) if finite.size else None}


def clamp(n_samples: int, sfreq: float, start_s: float, duration_s: float) -> tuple[int, int]:
    """(first sample, sample count) of the window kept inside the segment: a window that
    runs past either end slides back in, and one longer than the segment is the segment."""
    count = max(1, min(int(round(duration_s * sfreq)), n_samples))
    first = min(max(int(round(start_s * sfreq)), 0), n_samples - count)
    return first, count


def window(data: np.ndarray, sfreq: float, start_s: float, duration_s: float,
           which: str = "both", max_points: int = MAX_POINTS) -> dict[str, Any]:
    """The window as the protocol returns it, minus the recording metadata. `data` is the
    whole segment, (n_channels, n_samples), as recorded."""
    if not (np.isfinite(duration_s) and 0.0 < duration_s <= MAX_WINDOW_S):
        raise ValueError(f"duration_s must be more than 0 and at most {MAX_WINDOW_S:g} s, got {duration_s!r}")
    if not np.isfinite(start_s):
        raise ValueError(f"start_s must be a finite number, got {start_s!r}")
    if which not in WHICH:
        raise ValueError(f"which must be one of {sorted(WHICH)}, got {which!r}")
    if not 2 <= max_points <= MAX_POINTS:
        raise ValueError(f"max_points must be between 2 and {MAX_POINTS}, got {max_points!r}")
    data = np.asarray(data, dtype=np.float64)
    n_ch, n = data.shape
    first, count = clamp(n, sfreq, start_s, duration_s)
    k = min(max_points, count)
    starts = (np.arange(k) * count) // k
    finite = np.all(np.isfinite(data), axis=1)

    spec = pipeline.BandpassSpec()
    reason = quality.bandpass_unavailable(spec, sfreq) if "bandpassed" in WHICH[which] else None
    bandpass: dict[str, Any] | None = None
    filtered = None
    if "bandpassed" in WHICH[which] and reason is None:
        sos = spec.design(sfreq)
        settle = pipeline.settling_samples(sos)
        samples = np.where(finite[:, None], data, 0.0)
        filtered = pipeline.filter_segment(sos, samples)[:, first:first + count]
        bandpass = {"low_hz": spec.low_hz, "high_hz": spec.high_hz, "order": spec.order,
                    "warmup_samples": settle, "warmup_end_s": settle / sfreq}

    raw = data[:, first:first + count]
    channels = []
    for i in range(n_ch):
        ch: dict[str, Any] = {"raw": None, "bandpassed": None, "bandpassed_reason": None}
        if "raw" in WHICH[which]:
            ch["raw"] = envelope(raw[i], starts)
        if "bandpassed" in WHICH[which]:
            if reason is not None:
                ch["bandpassed_reason"] = reason
            elif not finite[i]:
                ch["bandpassed_reason"] = NON_FINITE
            else:
                ch["bandpassed"] = envelope(filtered[i], starts)
        channels.append(ch)
    return {
        "sfreq": sfreq, "segment_duration_s": n / sfreq,
        "start_s": first / sfreq, "duration_s": count / sfreq,
        "samples": count, "points": k, "t_s": [(first + int(s)) / sfreq for s in starts],
        "bandpass": bandpass, "bandpassed_reason": reason, "channels": channels,
    }
