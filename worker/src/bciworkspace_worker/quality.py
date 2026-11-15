"""Signal-quality checks and spectra for one recording segment (brief 002).

Pure functions over a segment's (n_channels, n_samples) array. The rule constants and
their wording come from the brief's "Rules (v1 constants)" table; `rules()` is the one
source the app shows, so the text and the thresholds cannot drift apart.

The checks describe the recording; none of them says a signal is neural. Nothing here
changes or excludes data (decision #24). Every number that leaves this module is finite
or `None` (the protocol refuses NaN); a check that can't be computed says why.
"""

from __future__ import annotations

from typing import Any, Sequence

import numpy as np
from scipy.signal import find_peaks, welch

from . import pipeline

# --- v1 constants (brief 002, decision #23: fixed, shown on screen) --------------------

WINDOW_S = 1.0                    # non-overlapping windows for flatline / deflections
FLAT_STD_UV = 0.5                 # flatline: window SD below this
PINNED_RUN_SAMPLES = 5            # pinned: this many equal samples at the segment max/min
DEFLECTION_PTP_UV = 200.0         # large deflections: window peak-to-peak above this
DEFLECTION_FRACTION = 0.10        # ... in more than this fraction of windows
MAINS_HZ = (50.0, 60.0)
MAINS_LINE_HALF_HZ = 1.0          # line band: f ± 1 Hz
MAINS_FLANK_HZ = (2.0, 4.0)       # flanks: f ± (2-4) Hz
MAINS_DB = 10.0
OUTLIER_VAR_HIGH = 5.0
OUTLIER_VAR_LOW = 0.2
HF_BAND_HZ = (20.0, 45.0)
HF_NYQUIST_MARGIN_HZ = 2.0        # HF band capped at Nyquist - 2 Hz
HF_RATIO = 3.0
MIN_OUTLIER_CHANNELS = 3          # cross-channel medians need at least this many EEG channels

PSD_WINDOW_S = 2.0                # Welch: 2 s Hann, 50 % overlap
PSD_MIN_HZ = 1.0
PSD_MAX_BINS = 256

EEG_KIND = "eeg"
MICROVOLT_UNITS = frozenset({"uv", "µv", "μv", "microvolt", "microvolts"})

_RULES = (
    ("flatline", "Flatline",
     "window standard deviation < 0.5 µV", "≥ 1 window"),
    ("pinned", "Pinned at a limit",
     "≥ 5 consecutive samples equal to the channel's segment maximum or minimum", "any run"),
    ("large_deflection", "Large deflections",
     "window peak-to-peak > 200 µV", "> 10 % of windows"),
    ("mains_line", "Mains line (50 / 60 Hz)",
     "PSD power in line ± 1 Hz vs mean of the flanking bands line ± (2–4) Hz", "> 10 dB"),
    ("outlier_amplitude", "Outlier amplitude",
     "channel variance vs median across EEG channels in the segment", "> 5× or < 0.2×"),
    ("outlier_high_frequency", "Outlier high-frequency power",
     "channel 20–45 Hz band power (capped at Nyquist − 2 Hz) vs median across EEG channels", "> 3×"),
)


def rules() -> list[dict[str, str]]:
    """The six checks as the app shows them: id, title, rule text, flag condition."""
    return [{"id": i, "title": t, "rule": r, "flag_when": f} for i, t, r, f in _RULES]


# --- helpers ----------------------------------------------------------------------------


def _num(x: Any) -> float | None:
    x = float(x)
    return x if np.isfinite(x) else None


def _db(power: np.ndarray) -> list[float | None]:
    with np.errstate(divide="ignore", invalid="ignore"):
        return [_num(v) for v in 10.0 * np.log10(power)]


def _result(rule: str, flagged: bool, measured: dict[str, Any]) -> dict[str, Any]:
    return {"rule": rule, "flagged": bool(flagged), "assessable": True, "measured": measured, "reason": None}


def _not_assessable(rule: str, reason: str) -> dict[str, Any]:
    return {"rule": rule, "flagged": False, "assessable": False, "measured": None, "reason": reason}


def _rate(sfreq: float) -> str:
    return f"{sfreq:g}"


def bandpass_unavailable(spec: pipeline.BandpassSpec, sfreq: float) -> str | None:
    """Why the reference band-pass can't run at this rate, else None."""
    if spec.high_hz < sfreq / 2.0:
        return None
    return f"band-pass {spec.low_hz:g}–{spec.high_hz:g} Hz does not fit below Nyquist at {_rate(sfreq)} Hz"


def is_microvolt(unit: str) -> bool:
    return unit.strip().lower() in MICROVOLT_UNITS


def _windows(x: np.ndarray, sfreq: float) -> np.ndarray:
    """(n_windows, n) consecutive non-overlapping 1 s windows; a partial tail is dropped."""
    n = int(round(WINDOW_S * sfreq))
    k = x.shape[-1] // n
    return x[: k * n].reshape(k, n)


# --- spectra ------------------------------------------------------------------------------


def welch_psd(data: np.ndarray, sfreq: float, nperseg: int) -> tuple[np.ndarray, np.ndarray]:
    """Welch PSD per row: Hann, 50 % overlap, no further detrending (callers remove the
    mean). Returns (freqs, power) on native bins."""
    return welch(data, fs=sfreq, window="hann", nperseg=nperseg, noverlap=nperseg // 2,
                 detrend=False, scaling="density", axis=-1)


def _reduce_bins(freqs: np.ndarray, power: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Bins from 1 Hz to Nyquist, averaged in contiguous groups down to ≤ 256 bins
    (native bins kept when there are fewer). Averaging keeps band power; interpolating
    would drop narrow lines."""
    keep = freqs >= PSD_MIN_HZ
    freqs, power = freqs[keep], power[..., keep]
    if freqs.size <= PSD_MAX_BINS:
        return freqs, power
    groups = np.array_split(np.arange(freqs.size), PSD_MAX_BINS)
    return (np.array([freqs[g].mean() for g in groups]),
            np.stack([power[..., g].mean(axis=-1) for g in groups], axis=-1))


def strongest_peak_hz(freqs: np.ndarray, power: np.ndarray) -> float | None:
    """Frequency of the most prominent local maximum of the log spectrum, 1 Hz to
    Nyquist; None when the spectrum has no peak (e.g. a flat channel)."""
    keep = freqs >= PSD_MIN_HZ
    f, p = freqs[keep], power[keep]
    if f.size < 3 or not np.all(p > 0):
        return None
    peaks, props = find_peaks(10.0 * np.log10(p), prominence=0.0)
    if peaks.size == 0:
        return None
    return _num(f[peaks[int(np.argmax(props["prominences"]))]])


# --- checks ---------------------------------------------------------------------------------


def check_flatline(x: np.ndarray, sfreq: float) -> dict[str, Any]:
    w = _windows(x, sfreq)
    if w.shape[0] == 0:
        return _not_assessable("flatline", f"segment shorter than {WINDOW_S:g} s")
    flat = int(np.sum(w.std(axis=1) < FLAT_STD_UV))
    return _result("flatline", flat >= 1, {
        "flat_windows": flat, "windows": int(w.shape[0]),
        "flat_s": flat * w.shape[1] / sfreq, "total_s": x.size / sfreq,
    })


def check_pinned(x: np.ndarray) -> dict[str, Any]:
    longest = runs = 0
    for limit in {float(x.max()), float(x.min())}:
        at = np.concatenate(([0], (x == limit).astype(np.int8), [0]))
        edges = np.flatnonzero(np.diff(at))
        lengths = edges[1::2] - edges[0::2]
        long_runs = lengths[lengths >= PINNED_RUN_SAMPLES]
        runs += int(long_runs.size)
        longest = max(longest, int(lengths.max(initial=0)))
    return _result("pinned", runs > 0, {"runs": runs, "longest_run_samples": longest})


def check_large_deflection(x: np.ndarray, sfreq: float) -> dict[str, Any]:
    w = _windows(x, sfreq)
    if w.shape[0] == 0:
        return _not_assessable("large_deflection", f"segment shorter than {WINDOW_S:g} s")
    over = int(np.sum(np.ptp(w, axis=1) > DEFLECTION_PTP_UV))
    fraction = over / w.shape[0]
    return _result("large_deflection", fraction > DEFLECTION_FRACTION,
                   {"windows_over": over, "windows": int(w.shape[0]), "fraction": fraction})


def _band_mean(freqs: np.ndarray, power: np.ndarray, lo: float, hi: float) -> float | None:
    sel = (freqs >= lo) & (freqs <= hi)
    return float(power[sel].mean()) if sel.any() else None


def check_mains(freqs: np.ndarray, power: np.ndarray, sfreq: float) -> dict[str, Any]:
    """One entry per line frequency. A line whose outer flank passes Nyquist is not
    assessable at this rate; the check is flagged when any assessable line exceeds 10 dB."""
    nyquist = sfreq / 2.0
    lines: list[dict[str, Any]] = []
    for hz in MAINS_HZ:
        entry: dict[str, Any] = {"hz": hz, "db": None, "flagged": False, "assessable": False, "reason": None}
        lines.append(entry)
        if hz + MAINS_FLANK_HZ[1] > nyquist:
            entry["reason"] = f"not assessable at {_rate(sfreq)} Hz"
            continue
        line = _band_mean(freqs, power, hz - MAINS_LINE_HALF_HZ, hz + MAINS_LINE_HALF_HZ)
        lo = _band_mean(freqs, power, hz - MAINS_FLANK_HZ[1], hz - MAINS_FLANK_HZ[0])
        hi = _band_mean(freqs, power, hz + MAINS_FLANK_HZ[0], hz + MAINS_FLANK_HZ[1])
        if line is None or lo is None or hi is None:
            entry["reason"] = "frequency resolution too coarse for the line and flank bands"
            continue
        flank = (lo + hi) / 2.0
        if flank <= 0.0 or line <= 0.0:
            entry["reason"] = "no power in the line or flank bands"
            continue
        db = 10.0 * np.log10(line / flank)
        entry.update(db=_num(db), flagged=bool(db > MAINS_DB), assessable=True)
    if not any(e["assessable"] for e in lines):
        reasons = sorted({e["reason"] for e in lines})
        return _not_assessable("mains_line", "; ".join(reasons))
    return _result("mains_line", any(e["flagged"] for e in lines), {"lines": lines})


def _ratio_check(rule: str, value: float, group_values: list[float], flag) -> dict[str, Any]:
    median = float(np.median(group_values))
    if median <= 0.0:
        return _not_assessable(rule, "median across EEG channels is zero")
    ratio = value / median
    return _result(rule, flag(ratio), {"value": _num(value), "median": _num(median), "ratio": _num(ratio)})


def hf_band(sfreq: float) -> tuple[float, float] | None:
    hi = min(HF_BAND_HZ[1], sfreq / 2.0 - HF_NYQUIST_MARGIN_HZ)
    return (HF_BAND_HZ[0], hi) if hi > HF_BAND_HZ[0] else None


# --- one segment -------------------------------------------------------------------------------


def inspect_segment(data: np.ndarray, sfreq: float, kinds: Sequence[str], units: Sequence[str]) -> list[dict[str, Any]]:
    """Per channel: `checks` (six results, `rules()` order), `psd` {freqs, raw,
    processed (dB re 1 unit²/Hz; null where power is zero), processed_reason}, and
    `peak_hz` (strongest peak of the raw spectrum). `data` is (n_channels, n_samples)."""
    data = np.asarray(data, dtype=np.float64)
    n_ch, n = data.shape
    finite = np.all(np.isfinite(data), axis=1)
    samples = np.where(finite[:, None], data, 0.0)    # non-finite channels: reported, not computed
    raw = samples - samples.mean(axis=1, keepdims=True)

    nperseg = min(int(round(PSD_WINDOW_S * sfreq)), n)
    spec = pipeline.BandpassSpec()
    processed_reason = bandpass_unavailable(spec, sfreq)
    if processed_reason is not None:
        processed = None
    else:
        # Same processed signal as evaluation: the unmodified samples, one causal pass from
        # zero state, warm-up dropped. The mean is removed for the raw spectrum only.
        sos = spec.design(sfreq)
        settle = pipeline.settling_samples(sos)
        processed = pipeline.filter_segment(sos, samples)[:, settle:]
    if processed is not None and processed.shape[1] < nperseg:
        if processed.shape[1] >= int(round(WINDOW_S * sfreq)):
            nperseg = processed.shape[1]   # short segment: both spectra use the shorter window
        else:
            processed_reason = f"segment too short after the band-pass warm-up ({settle} samples)"

    freqs, raw_power = welch_psd(raw, sfreq, nperseg)
    out_freqs, raw_bins = _reduce_bins(freqs, raw_power)
    proc_bins = None
    if processed_reason is None:
        _, proc_power = welch_psd(processed, sfreq, nperseg)
        _, proc_bins = _reduce_bins(freqs, proc_power)

    is_eeg = [k.strip().lower() == EEG_KIND for k in kinds]
    is_uv = [is_microvolt(u) for u in units]
    variance = raw.var(axis=1)
    band = hf_band(sfreq)
    if band is not None:
        sel = (freqs >= band[0]) & (freqs <= band[1])
        df = freqs[1] - freqs[0] if freqs.size > 1 else 0.0
        hf_power = raw_power[:, sel].sum(axis=1) * df
    group = [i for i in range(n_ch) if is_eeg[i] and is_uv[i] and finite[i]]

    channels = []
    for i in range(n_ch):
        x = raw[i]
        if not finite[i]:
            reason = "channel contains non-finite samples"
            checks = [_not_assessable(r[0], reason) for r in _RULES]
            psd = {"freqs": [_num(f) for f in out_freqs], "raw": None, "processed": None, "processed_reason": reason}
            channels.append({"checks": checks, "psd": psd, "peak_hz": None})
            continue
        if is_uv[i]:
            unit_reason = None
        elif not units[i].strip():
            unit_reason = "unit not declared"
        else:
            unit_reason = f"not assessed (unit {units[i]})"
        if unit_reason:
            flat = _not_assessable("flatline", unit_reason)
            defl = _not_assessable("large_deflection", unit_reason)
        else:
            flat, defl = check_flatline(x, sfreq), check_large_deflection(x, sfreq)
        if unit_reason:
            out_amp = _not_assessable("outlier_amplitude", unit_reason)
            out_hf = _not_assessable("outlier_high_frequency", unit_reason)
        elif not is_eeg[i]:
            reason = f"not compared (kind {kinds[i]}; medians are across EEG channels)"
            out_amp = _not_assessable("outlier_amplitude", reason)
            out_hf = _not_assessable("outlier_high_frequency", reason)
        elif len(group) < MIN_OUTLIER_CHANNELS:
            reason = f"fewer than {MIN_OUTLIER_CHANNELS} EEG channels to compare"
            out_amp = _not_assessable("outlier_amplitude", reason)
            out_hf = _not_assessable("outlier_high_frequency", reason)
        else:
            out_amp = _ratio_check("outlier_amplitude", float(variance[i]), [float(variance[j]) for j in group],
                                   lambda r: r > OUTLIER_VAR_HIGH or r < OUTLIER_VAR_LOW)
            if band is None:
                out_hf = _not_assessable("outlier_high_frequency", f"not assessable at {_rate(sfreq)} Hz")
            else:
                out_hf = _ratio_check("outlier_high_frequency", float(hf_power[i]), [float(hf_power[j]) for j in group],
                                      lambda r: r > HF_RATIO)
                if out_hf["measured"] is not None:
                    out_hf["measured"]["band_hz"] = [band[0], band[1]]
        checks = [flat, check_pinned(x), defl, check_mains(freqs, raw_power[i], sfreq), out_amp, out_hf]
        psd = {"freqs": [_num(f) for f in out_freqs], "raw": _db(raw_bins[i]),
               "processed": None if proc_bins is None else _db(proc_bins[i]),
               "processed_reason": processed_reason}
        channels.append({"checks": checks, "psd": psd, "peak_hz": strongest_peak_hz(freqs, raw_power[i])})
    return channels
