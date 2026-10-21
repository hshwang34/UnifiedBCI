"""Reference two-class motor-imagery recipe: causal band-pass -> CSP -> shrinkage LDA,
plus a deliberately simpler log-variance baseline.

Evaluation rules follow the PRD (section 6):

- The band-pass has no fitted parameters, so it is applied once to each continuous
  stream segment with zero initial state at segment start — exactly what the online
  path does (`reset_on_segment_start`). Epochs are cut from the filtered segment, so
  a trial never sees a start transient the live system would not see. Trials whose
  window begins inside the filter's warm-up are excluded and listed.
- Every fitted step (CSP, LDA) lives inside the sklearn Pipeline and is re-fit per
  fold. Splits are grouped by run, a seeded holdout is frozen before any model sees
  it, and the chosen split is written to the record (`split_manifest`) so the same
  split can be re-scored without redrawing it.
- Uncertainty: a trial-level Clopper-Pearson interval on accuracy (one window per
  trial, so trials are the independent unit), per-run holdout scores, a run-level
  bootstrap interval on balanced accuracy, and a paired reference-vs-baseline
  comparison over runs.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Sequence

import numpy as np
from scipy.linalg import eigh
from scipy.signal import butter, sosfilt
from scipy.stats import beta
from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.covariance import ledoit_wolf
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
from sklearn.metrics import confusion_matrix
from sklearn.model_selection import GroupShuffleSplit, StratifiedGroupKFold
from sklearn.pipeline import Pipeline

Progress = Callable[[dict[str, Any]], None]
Check = Callable[[], None]


# --------------------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------------------


@dataclass
class Segment:
    """One contiguous stream segment: `data` is (n_channels, n_samples) float64 at
    `sfreq`; `events` are `(sample_index, label, trial_id)` cue onsets inside it.
    `run_id` is the grouping unit for splits; `session_id` decides the evidence label."""

    data: np.ndarray
    sfreq: float
    events: list[tuple[int, int, str]]
    run_id: str
    session_id: str | None = None

    def __post_init__(self) -> None:
        self.data = np.asarray(self.data, dtype=np.float64)
        if self.data.ndim != 2:
            raise ValueError(f"segment {self.run_id!r}: data must be (n_channels, n_samples)")


@dataclass(frozen=True)
class BandpassSpec:
    low_hz: float = 8.0
    high_hz: float = 30.0
    order: int = 4

    def design(self, sfreq: float) -> np.ndarray:
        return butter(self.order, [self.low_hz, self.high_hz], btype="band", fs=sfreq, output="sos")


def settling_samples(sos: np.ndarray, tolerance: float = 1e-3) -> int:
    """Samples until the slowest pole's start transient has decayed to `tolerance`.
    Derived from the coefficients, so the warm-up follows the filter, not a literal."""
    poles = np.concatenate([np.roots(section[3:]) for section in sos])
    radius = float(np.max(np.abs(poles)))
    if radius >= 1.0:
        raise ValueError("filter is not stable")
    return int(np.ceil(np.log(tolerance) / np.log(radius)))


class CausalFilterState:
    """Streaming form of the band-pass: carries filter state across chunks and resets
    at segment start. `filter_segment` is the offline form; both must agree."""

    def __init__(self, sos: np.ndarray, n_channels: int):
        self.sos = sos
        self.n_channels = n_channels
        self.reset()

    def reset(self) -> None:
        self._zi = np.zeros((self.sos.shape[0], self.n_channels, 2))

    def process(self, chunk: np.ndarray) -> np.ndarray:
        out, self._zi = sosfilt(self.sos, chunk, axis=-1, zi=self._zi)
        return out


def filter_segment(sos: np.ndarray, data: np.ndarray) -> np.ndarray:
    """Offline form: one causal pass over the whole segment, zero state at its start."""
    return sosfilt(sos, data, axis=-1)


@dataclass
class Epochs:
    X: np.ndarray                 # (n_trials, n_channels, n_window)
    y: np.ndarray                 # (n_trials,) int labels
    groups: np.ndarray            # (n_trials,) run ids
    trial_ids: np.ndarray         # (n_trials,) str
    exclusions: list[dict[str, Any]] = field(default_factory=list)


def epoch_segments(
    segments: Sequence[Segment],
    sos: np.ndarray,
    window: tuple[float, float],
    warmup_samples: int,
) -> Epochs:
    """Filter each segment continuously, then cut one window per event.

    `window` is `(offset_s, length_s)` relative to the cue sample. A trial is excluded
    (and listed with a reason) when its window starts before `warmup_samples` into the
    segment, before the segment itself, or runs past its end. Nothing is padded."""
    sfreq = segments[0].sfreq
    offset_s, length_s = window
    offset = int(round(offset_s * sfreq))
    length = int(round(length_s * sfreq))
    if length <= 0:
        raise ValueError("window length must be positive")

    X: list[np.ndarray] = []
    y: list[int] = []
    groups: list[str] = []
    trial_ids: list[str] = []
    exclusions: list[dict[str, Any]] = []
    for seg in segments:
        if seg.sfreq != sfreq:
            raise ValueError(f"segment {seg.run_id!r} is at {seg.sfreq} Hz, expected {sfreq} Hz; not resampling")
        if seg.data.shape[0] != segments[0].data.shape[0]:
            raise ValueError(f"segment {seg.run_id!r} has {seg.data.shape[0]} channels, expected {segments[0].data.shape[0]}")
        filtered = filter_segment(sos, seg.data)
        n_samples = filtered.shape[1]
        for sample_index, label, trial_id in seg.events:
            start = int(sample_index) + offset
            stop = start + length
            reason = None
            if start < 0:
                reason = "window_starts_before_segment"
            elif start < warmup_samples:
                reason = "window_starts_before_filter_warmup"
            elif stop > n_samples:
                reason = "window_exceeds_segment"
            if reason is not None:
                exclusions.append({
                    "trial_id": str(trial_id), "run_id": seg.run_id, "label": int(label),
                    "reason": reason, "window_start_sample": start, "window_stop_sample": stop,
                })
                continue
            X.append(filtered[:, start:stop])
            y.append(int(label))
            groups.append(seg.run_id)
            trial_ids.append(str(trial_id))
    if not X:
        raise ValueError("no trials survived epoching")
    return Epochs(np.stack(X), np.asarray(y), np.asarray(groups, dtype=object), np.asarray(trial_ids, dtype=object), exclusions)


# --------------------------------------------------------------------------------------
# Estimators
# --------------------------------------------------------------------------------------


def _class_covariance(x_class: np.ndarray) -> tuple[np.ndarray, float]:
    """Ledoit-Wolf shrinkage covariance of one class, trials concatenated along time,
    assumed centered (band-passed data has no DC). Matches MNE's `cov_est='concat'`."""
    n_channels = x_class.shape[1]
    flat = x_class.transpose(1, 0, 2).reshape(n_channels, -1)
    cov, shrinkage = ledoit_wolf(flat.T, assume_centered=True)
    return cov, float(shrinkage)


class CSP(BaseEstimator, TransformerMixin):
    """Two-class common spatial patterns with Ledoit-Wolf shrinkage and log-power
    features. Generalized eigendecomposition of (C_a, C_a + C_b); eigenvalues lie in
    (0, 1) and give the share of class-a variance each component carries.
    `n_components` are taken from the two ends of the spectrum (ceil(n/2) from the top,
    floor(n/2) from the bottom). Rows of `filters_` are spatial filters; rows of
    `patterns_` the matching forward-model patterns."""

    def __init__(self, n_components: int = 4, shrinkage: str = "ledoit_wolf", log: bool = True):
        self.n_components = n_components
        self.shrinkage = shrinkage
        self.log = log

    def fit(self, X: np.ndarray, y: np.ndarray) -> "CSP":
        X = np.asarray(X, dtype=np.float64)
        y = np.asarray(y)
        if X.ndim != 3:
            raise ValueError("X must be (n_trials, n_channels, n_samples)")
        classes = np.unique(y)
        if len(classes) != 2:
            raise ValueError(f"CSP needs exactly two classes, got {classes.tolist()}")
        n_channels = X.shape[1]
        if not 1 <= self.n_components <= n_channels:
            raise ValueError(f"n_components must be in [1, {n_channels}]")
        if self.shrinkage != "ledoit_wolf":
            raise ValueError("only 'ledoit_wolf' shrinkage is implemented")

        (cov_a, alpha_a), (cov_b, alpha_b) = (_class_covariance(X[y == c]) for c in classes)
        evals, evecs = eigh(cov_a, cov_a + cov_b)      # ascending; columns are filters
        top = int(np.ceil(self.n_components / 2))
        bottom = self.n_components - top
        order = np.concatenate([np.arange(n_channels - 1, n_channels - 1 - top, -1), np.arange(bottom)])

        self.classes_ = classes
        self.eigenvalues_ = evals
        self.all_filters_ = evecs.T
        self.component_indices_ = order
        self.filters_ = evecs[:, order].T
        self.patterns_ = np.linalg.pinv(evecs)[order]
        self.shrinkage_per_class_ = [alpha_a, alpha_b]
        return self

    def transform(self, X: np.ndarray) -> np.ndarray:
        sources = np.einsum("kc,nct->nkt", self.filters_, np.asarray(X, dtype=np.float64))
        power = np.mean(sources ** 2, axis=-1)
        return np.log(power) if self.log else power


class LogVariance(BaseEstimator, TransformerMixin):
    """Per-channel log-variance features: the baseline a CSP pipeline must beat."""

    def fit(self, X, y=None):
        return self

    def transform(self, X):
        return np.log(np.var(X, axis=-1) + 1e-12)


def reference_pipeline(n_components: int = 4) -> Pipeline:
    return Pipeline([
        ("csp", CSP(n_components=n_components)),
        ("lda", LinearDiscriminantAnalysis(solver="lsqr", shrinkage="auto")),
    ])


def baseline_pipeline() -> Pipeline:
    return Pipeline([
        ("logvar", LogVariance()),
        ("lda", LinearDiscriminantAnalysis(solver="lsqr", shrinkage="auto")),
    ])


# --------------------------------------------------------------------------------------
# Fitted parameters as explicit arrays
# --------------------------------------------------------------------------------------


def fitted_arrays(model: Pipeline, sos: np.ndarray) -> dict[str, np.ndarray]:
    """Everything needed to reproduce `model.predict` on filtered epochs, as plain
    arrays for `np.savez`. No pickled estimators ever leave the worker."""
    out: dict[str, np.ndarray] = {"bandpass_sos": np.asarray(sos)}
    steps = model.named_steps
    if "csp" in steps:
        csp: CSP = steps["csp"]
        out["csp_filters"] = csp.filters_
        out["csp_patterns"] = csp.patterns_
        out["csp_component_indices"] = csp.component_indices_
        out["csp_eigenvalues"] = csp.eigenvalues_
        out["feature_kind"] = np.array("csp_log_power")
    else:
        out["feature_kind"] = np.array("log_variance")
    lda: LinearDiscriminantAnalysis = steps["lda"]
    out["lda_coef"] = lda.coef_
    out["lda_intercept"] = lda.intercept_
    out["lda_classes"] = lda.classes_
    return out


def predict_from_arrays(arrays: dict[str, np.ndarray], X_filtered: np.ndarray) -> np.ndarray:
    """Reference re-implementation over the saved arrays; the test suite checks it
    agrees with the sklearn objects it was exported from."""
    kind = str(arrays["feature_kind"])
    if kind == "csp_log_power":
        sources = np.einsum("kc,nct->nkt", arrays["csp_filters"], X_filtered)
        features = np.log(np.mean(sources ** 2, axis=-1))
    elif kind == "log_variance":
        features = np.log(np.var(X_filtered, axis=-1) + 1e-12)
    else:
        raise ValueError(f"unknown feature kind {kind!r}")
    scores = features @ arrays["lda_coef"].T + arrays["lda_intercept"]
    classes = arrays["lda_classes"]
    return classes[(scores[:, 0] > 0).astype(int)]


# --------------------------------------------------------------------------------------
# Synthetic data
# --------------------------------------------------------------------------------------


def _pink_noise(rng: np.random.Generator, shape: tuple[int, int]) -> np.ndarray:
    """1/f-shaped noise per row, unit variance."""
    white = rng.standard_normal(shape)
    spectrum = np.fft.rfft(white, axis=-1)
    freqs = np.fft.rfftfreq(shape[-1])
    freqs[0] = freqs[1]
    spectrum /= np.sqrt(freqs)
    pink = np.fft.irfft(spectrum, n=shape[-1], axis=-1)
    return pink / pink.std(axis=-1, keepdims=True)


def make_synthetic_runs(
    n_runs: int = 4,
    trials_per_run: int = 20,
    n_channels: int = 16,
    sfreq: float = 125.0,
    effect: float = 0.6,
    seed: int = 0,
    pre_seconds: float = 3.0,
    cue_interval_seconds: float = 4.0,
    modulation_window: tuple[float, float] = (0.25, 3.0),
    n_sources: int = 6,
) -> list[Segment]:
    """Continuous synthetic runs with cue events at known sample indices.

    A few latent sources are mixed through one random full-rank spatial matrix: two
    carry mu-band (10 Hz) rhythm whose power drops by `effect` during a trial of the
    class they belong to, the rest are pink noise. Each run adds per-channel gain and
    slow offset drift plus pink sensor noise. Because the class effect lives in a
    mixed subspace, no single channel's variance is the optimal feature.

    This exists to exercise the pipeline and protocol end to end. It is NOT evidence
    about real motor imagery; results on it say nothing about a participant.
    """
    rng = np.random.default_rng(seed)
    duration_s = pre_seconds + trials_per_run * cue_interval_seconds + 1.0
    n_samples = int(round(duration_s * sfreq))
    t = np.arange(n_samples) / sfreq
    mixing = rng.standard_normal((n_channels, n_sources))
    labels_per_run = np.array([0, 1] * (trials_per_run // 2) + [0] * (trials_per_run % 2))
    mod_start, mod_stop = (int(round(s * sfreq)) for s in modulation_window)

    segments: list[Segment] = []
    for run in range(n_runs):
        run_id = f"run{run:02d}"
        cues = [int(round((pre_seconds + k * cue_interval_seconds) * sfreq)) for k in range(trials_per_run)]
        labels = rng.permutation(labels_per_run)

        sources = _pink_noise(rng, (n_sources, n_samples))
        for src in (0, 1):
            envelope = np.ones(n_samples)
            for cue, label in zip(cues, labels):
                if label == src:
                    envelope[cue + mod_start: cue + mod_stop] = 1.0 - effect
            phase = rng.uniform(0, 2 * np.pi)
            rhythm = np.sin(2 * np.pi * 10.0 * t + phase + 0.3 * np.cumsum(rng.standard_normal(n_samples)) / np.sqrt(sfreq))
            sources[src] = 2.0 * envelope * rhythm + 0.3 * sources[src]

        gain = rng.uniform(0.8, 1.2, (n_channels, 1))
        drift = np.cumsum(rng.standard_normal((n_channels, n_samples)), axis=-1) * (0.5 / np.sqrt(sfreq))
        data = gain * (mixing @ sources) + drift + 0.5 * _pink_noise(rng, (n_channels, n_samples))
        events = [(cue, int(label), f"{run_id}-t{k:03d}") for k, (cue, label) in enumerate(zip(cues, labels))]
        segments.append(Segment(data=data, sfreq=sfreq, events=events, run_id=run_id, session_id="synthetic-session"))
    return segments


# --------------------------------------------------------------------------------------
# Splits
# --------------------------------------------------------------------------------------


def draw_split_manifest(
    y: np.ndarray,
    groups: np.ndarray,
    trial_ids: np.ndarray,
    seed: int,
    holdout_fraction: float = 0.25,
    max_folds: int = 5,
) -> dict[str, Any]:
    """Freeze a grouped holdout and the grouped CV folds on the remaining runs.
    Everything a reader needs to reproduce the split is listed by id."""
    splitter = GroupShuffleSplit(n_splits=1, test_size=holdout_fraction, random_state=seed)
    train_idx, hold_idx = next(splitter.split(y, y, groups))
    holdout_runs = sorted({str(g) for g in groups[hold_idx]})
    training_runs = sorted({str(g) for g in groups[train_idx]})
    n_folds = min(max_folds, len(training_runs))
    if n_folds < 2:
        raise ValueError("need at least 2 training runs for grouped cross-validation")
    cv = StratifiedGroupKFold(n_splits=n_folds, shuffle=True, random_state=seed)
    folds = []
    for k, (_, test) in enumerate(cv.split(y[train_idx], y[train_idx], groups[train_idx])):
        folds.append({"fold": k + 1, "test_runs": sorted({str(g) for g in groups[train_idx][test]})})
    return {
        "seed": seed,
        "holdout_fraction": holdout_fraction,
        "holdout_runs": holdout_runs,
        "holdout_trials": sorted(str(t) for t in trial_ids[hold_idx]),
        "training_runs": training_runs,
        "folds": folds,
    }


def _validate_manifest(manifest: dict[str, Any], groups: np.ndarray, trial_ids: np.ndarray) -> None:
    present = {str(g) for g in groups}
    holdout = set(manifest["holdout_runs"])
    training = set(manifest["training_runs"])
    if holdout & training:
        raise ValueError(f"split manifest leaks runs into both splits: {sorted(holdout & training)}")
    missing = (holdout | training) - present
    if missing:
        raise ValueError(f"split manifest names runs absent from the data: {sorted(missing)}")
    if present - (holdout | training):
        raise ValueError(f"data has runs the split manifest does not place: {sorted(present - (holdout | training))}")
    for fold in manifest["folds"]:
        if not set(fold["test_runs"]) <= training:
            raise ValueError(f"fold {fold['fold']} tests on runs outside the training split")
    expected_trials = sorted(str(t) for t, g in zip(trial_ids, groups) if str(g) in holdout)
    if "holdout_trials" in manifest and list(manifest["holdout_trials"]) != expected_trials:
        raise ValueError("split manifest holdout trials do not match the data; refusing to re-score a different split")


# --------------------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------------------


def balanced_accuracy(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    """Mean per-class recall over the classes present in `y_true`."""
    recalls = [np.mean(y_pred[y_true == c] == c) for c in np.unique(y_true)]
    return float(np.mean(recalls))


def clopper_pearson(correct: int, n: int) -> list[float]:
    lo = 0.0 if correct == 0 else float(beta.ppf(0.025, correct, n - correct + 1))
    hi = 1.0 if correct == n else float(beta.ppf(0.975, correct + 1, n - correct))
    return [lo, hi]


def _per_run_scores(y_true, y_pred, groups) -> list[dict[str, Any]]:
    out = []
    for run in sorted({str(g) for g in groups}):
        m = groups == run
        out.append({
            "run_id": run,
            "n_trials": int(m.sum()),
            "balanced_accuracy": balanced_accuracy(y_true[m], y_pred[m]),
            "accuracy": float(np.mean(y_true[m] == y_pred[m])),
        })
    return out


def _run_bootstrap(
    y_true: np.ndarray,
    predictions: dict[str, np.ndarray],
    groups: np.ndarray,
    seed: int,
    n_boot: int = 2000,
) -> dict[str, Any]:
    """Resample held-out runs with replacement; the same draws score every model so
    differences between models are paired. Returns percentile 95 % intervals, or
    None when fewer than two runs were held out (no run-level resampling possible)."""
    runs = sorted({str(g) for g in groups})
    names = list(predictions)
    if len(runs) < 2:
        return {"n_resamples": 0, "balanced_accuracy_ci95": {n: None for n in names}, "difference_ci95": None}
    rng = np.random.default_rng(seed)
    by_run = [np.flatnonzero(groups == r) for r in runs]
    stats = {n: np.empty(n_boot) for n in names}
    for b in range(n_boot):
        idx = np.concatenate([by_run[p] for p in rng.integers(0, len(runs), len(runs))])
        for n in names:
            stats[n][b] = balanced_accuracy(y_true[idx], predictions[n][idx])
    ci = {n: [float(np.percentile(stats[n], 2.5)), float(np.percentile(stats[n], 97.5))] for n in names}
    diff = stats[names[0]] - stats[names[1]]
    return {
        "n_resamples": n_boot,
        "balanced_accuracy_ci95": ci,
        "difference_ci95": [float(np.percentile(diff, 2.5)), float(np.percentile(diff, 97.5))],
    }


def holdout_report(y_true, y_pred, groups) -> dict[str, Any]:
    n = int(len(y_true))
    correct = int((y_true == y_pred).sum())
    return {
        "balanced_accuracy": balanced_accuracy(y_true, y_pred),
        "accuracy": correct / n,
        "confusion_matrix": confusion_matrix(y_true, y_pred, labels=[0, 1]).tolist(),
        "n_test_trials": n,
        "n_test_runs": len(set(groups.tolist())),
        # Clopper-Pearson over held-out trials: valid because each trial contributes
        # exactly one window. Overlapping windows per trial would break independence.
        "accuracy_ci95": clopper_pearson(correct, n),
        "per_run": _per_run_scores(y_true, y_pred, groups),
    }


# --------------------------------------------------------------------------------------
# Fit + evaluate
# --------------------------------------------------------------------------------------


def _evidence(segments: Sequence[Segment], manifest: dict[str, Any]) -> str:
    session_of = {s.run_id: s.session_id for s in segments}
    holdout_sessions = {session_of[r] for r in manifest["holdout_runs"]}
    training_sessions = {session_of[r] for r in manifest["training_runs"]}
    if holdout_sessions == training_sessions and len(holdout_sessions) == 1:
        return "same-session"
    if not holdout_sessions & training_sessions:
        return "cross-session"
    return "mixed-session"


def fit_evaluate(
    segments: Sequence[Segment],
    window: tuple[float, float] = (0.5, 2.0),
    seed: int = 0,
    n_components: int = 4,
    bandpass: BandpassSpec = BandpassSpec(),
    holdout_fraction: float = 0.25,
    warmup_seconds: float | None = None,
    split_manifest: dict[str, Any] | None = None,
    progress: Progress | None = None,
    check_cancelled: Check | None = None,
    return_fitted: bool = False,
) -> dict[str, Any] | tuple[dict[str, Any], dict[str, dict[str, np.ndarray]]]:
    """Filter each segment continuously, epoch, freeze (or reuse) a grouped split,
    cross-validate on the training runs, fit once, score the holdout. Returns a
    JSON-serializable evaluation record; with `return_fitted` also the per-model
    fitted arrays (`fitted_arrays`) for the caller to write as `.npz`."""
    if not segments:
        raise ValueError("no segments")
    sfreq = segments[0].sfreq
    sos = bandpass.design(sfreq)
    warmup_samples = settling_samples(sos) if warmup_seconds is None else int(round(warmup_seconds * sfreq))
    epochs = epoch_segments(segments, sos, window, warmup_samples)
    X, y, groups, trial_ids = epochs.X, epochs.y, epochs.groups, epochs.trial_ids

    if split_manifest is None:
        manifest = draw_split_manifest(y, groups, trial_ids, seed, holdout_fraction)
    else:
        manifest = {**split_manifest}
        _validate_manifest(manifest, groups, trial_ids)
    assert not set(manifest["holdout_runs"]) & set(manifest["training_runs"])
    hold = np.isin(groups, manifest["holdout_runs"])
    train = np.isin(groups, manifest["training_runs"])
    Xtr, ytr, gtr = X[train], y[train], groups[train]
    Xho, yho, gho = X[hold], y[hold], groups[hold]
    folds = manifest["folds"]

    models = {
        "reference_csp_rlda": reference_pipeline(n_components),
        "baseline_logvar_rlda": baseline_pipeline(),
    }
    results: dict[str, Any] = {}
    predictions: dict[str, np.ndarray] = {}
    fitted: dict[str, dict[str, np.ndarray]] = {}
    for step, (name, model) in enumerate(models.items()):
        fold_scores = []
        for fold in folds:
            if check_cancelled:
                check_cancelled()
            test = np.isin(gtr, fold["test_runs"])
            model.fit(Xtr[~test], ytr[~test])
            fold_scores.append(balanced_accuracy(ytr[test], model.predict(Xtr[test])))
            if progress:
                progress({"model": name, "fold": fold["fold"], "of": len(folds), "step": step + 1, "steps": len(models)})
        if check_cancelled:
            check_cancelled()
        model.fit(Xtr, ytr)
        predictions[name] = model.predict(Xho)
        fitted[name] = fitted_arrays(model, sos)
        results[name] = {
            "cv_balanced_accuracy_per_fold": fold_scores,
            "cv_balanced_accuracy_mean": float(np.mean(fold_scores)),
            "holdout": holdout_report(yho, predictions[name], gho),
        }

    ref_name, base_name = "reference_csp_rlda", "baseline_logvar_rlda"
    boot = _run_bootstrap(yho, {ref_name: predictions[ref_name], base_name: predictions[base_name]}, gho, seed)
    for name in results:
        results[name]["holdout"]["balanced_accuracy_run_bootstrap_ci95"] = boot["balanced_accuracy_ci95"][name]
    ref_runs = {r["run_id"]: r for r in results[ref_name]["holdout"]["per_run"]}
    base_runs = {r["run_id"]: r for r in results[base_name]["holdout"]["per_run"]}
    per_run_diff = [{"run_id": r, "difference": ref_runs[r]["balanced_accuracy"] - base_runs[r]["balanced_accuracy"]} for r in ref_runs]
    ref_right = predictions[ref_name] == yho
    base_right = predictions[base_name] == yho

    csp: CSP = models[ref_name].named_steps["csp"]
    lda: LinearDiscriminantAnalysis = models[ref_name].named_steps["lda"]
    record = {
        "split_policy": {
            "unit": "trial",
            "grouping": "run",
            "holdout": "GroupShuffleSplit by run, frozen before fitting" if split_manifest is None else "re-scored from supplied split manifest",
            "holdout_fraction": manifest.get("holdout_fraction"),
            "cv": f"StratifiedGroupKFold(n_splits={len(folds)}) on training runs",
            "evidence": _evidence(segments, manifest),
            "seed": seed,
        },
        "split_manifest": manifest,
        "class_counts": {
            "train": np.bincount(ytr, minlength=2).tolist(),
            "holdout": np.bincount(yho, minlength=2).tolist(),
        },
        "exclusions": epochs.exclusions,
        "models": results,
        "comparison": {
            "reference": ref_name,
            "baseline": base_name,
            "per_run_difference": per_run_diff,
            "mean_difference": float(np.mean([d["difference"] for d in per_run_diff])),
            "difference_run_bootstrap_ci95": boot["difference_ci95"],
            "n_bootstrap_resamples": boot["n_resamples"],
            "paired_trials": {
                "reference_only_correct": int(np.sum(ref_right & ~base_right)),
                "baseline_only_correct": int(np.sum(~ref_right & base_right)),
                "both_correct": int(np.sum(ref_right & base_right)),
                "neither_correct": int(np.sum(~ref_right & ~base_right)),
            },
        },
        "uncertainty_notes": (
            "accuracy_ci95 is Clopper-Pearson over held-out trials and assumes trials are "
            "independent; that holds because each trial contributes exactly one window. "
            "balanced_accuracy_run_bootstrap_ci95 resamples held-out runs and is null when "
            "fewer than two runs are held out."
        ),
        "config": {
            "sfreq": sfreq,
            "n_channels": int(X.shape[1]),
            "bandpass_hz": [bandpass.low_hz, bandpass.high_hz],
            "bandpass_order": bandpass.order,
            "bandpass_sections": int(sos.shape[0]),
            "bandpass_direction": "causal",
            "filter_state_policy": "reset_on_segment_start",
            "filter_warmup_samples": warmup_samples,
            "filter_warmup_seconds": warmup_samples / sfreq,
            "window_offset_seconds": window[0],
            "window_length_seconds": window[1],
            "window_samples": int(X.shape[2]),
            "csp_components": int(csp.n_components),
            "csp_component_indices": csp.component_indices_.tolist(),
            "csp_regularization": csp.shrinkage,
            "csp_shrinkage_per_class": csp.shrinkage_per_class_,
            "lda_solver": lda.solver,
            "lda_shrinkage": lda.shrinkage,
        },
    }
    return (record, fitted) if return_fitted else record
