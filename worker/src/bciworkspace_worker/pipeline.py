"""Reference two-class motor-imagery recipe: causal band-pass -> CSP -> shrinkage LDA,
plus a deliberately simpler log-variance baseline.

Evaluation rules follow the PRD (section 6): every fitted step lives inside the
sklearn Pipeline so it is re-fit per fold; splits are grouped by run so overlapping
windows from one trial never straddle train/test; a seeded holdout is frozen before
any model sees it; uncertainty is reported per trial, never per window.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any

import numpy as np
from mne.decoding import CSP
from scipy.signal import butter, sosfilt
from scipy.stats import beta
from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
from sklearn.metrics import balanced_accuracy_score, confusion_matrix
from sklearn.model_selection import GroupShuffleSplit, StratifiedGroupKFold
from sklearn.pipeline import Pipeline


class CausalBandpass(BaseEstimator, TransformerMixin):
    """Zero-state IIR band-pass applied forward-only, per trial.

    The same coefficients and direction are used online, so offline features match
    the streaming path. Filter state is reset at each trial start; that mirrors the
    online behavior after a discontinuity and is part of the declared contract.
    """

    def __init__(self, sfreq: float, low: float = 8.0, high: float = 30.0, order: int = 4):
        self.sfreq = sfreq
        self.low = low
        self.high = high
        self.order = order

    def fit(self, X, y=None):
        self.sos_ = butter(self.order, [self.low, self.high], btype="band", fs=self.sfreq, output="sos")
        return self

    def transform(self, X):
        return sosfilt(self.sos_, X, axis=-1)


class LogVariance(BaseEstimator, TransformerMixin):
    """Per-channel log-variance features: the baseline a CSP pipeline must beat."""

    def fit(self, X, y=None):
        return self

    def transform(self, X):
        return np.log(np.var(X, axis=-1) + 1e-12)


def reference_pipeline(sfreq: float, n_components: int = 4) -> Pipeline:
    return Pipeline(
        [
            ("bandpass", CausalBandpass(sfreq=sfreq)),
            ("csp", CSP(n_components=n_components, reg="ledoit_wolf", log=True, norm_trace=False)),
            ("lda", LinearDiscriminantAnalysis(solver="lsqr", shrinkage="auto")),
        ]
    )


def baseline_pipeline(sfreq: float) -> Pipeline:
    return Pipeline(
        [
            ("bandpass", CausalBandpass(sfreq=sfreq)),
            ("logvar", LogVariance()),
            ("lda", LinearDiscriminantAnalysis(solver="lsqr", shrinkage="auto")),
        ]
    )


def make_synthetic_mi(
    n_runs: int = 4,
    trials_per_run: int = 20,
    n_channels: int = 16,
    sfreq: float = 125.0,
    trial_seconds: float = 3.0,
    effect: float = 0.6,
    seed: int = 0,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Synthetic two-class data with lateralized mu-band desynchronization.

    This exists to exercise the pipeline and protocol end to end. It is NOT evidence
    about real motor imagery; results on it say nothing about a participant.
    """
    rng = np.random.default_rng(seed)
    n_samples = int(trial_seconds * sfreq)
    t = np.arange(n_samples) / sfreq
    n_trials = n_runs * trials_per_run
    X = np.empty((n_trials, n_channels, n_samples))
    y = np.empty(n_trials, dtype=int)
    groups = np.repeat(np.arange(n_runs), trials_per_run)
    left = np.arange(0, n_channels // 2)
    right = np.arange(n_channels // 2, n_channels)
    for i in range(n_trials):
        label = rng.integers(0, 2)
        y[i] = label
        noise = rng.standard_normal((n_channels, n_samples))
        noise = np.cumsum(noise, axis=-1) * 0.05 + rng.standard_normal((n_channels, n_samples))
        mu = np.sin(2 * np.pi * 10.0 * t + rng.uniform(0, 2 * np.pi, (n_channels, 1)))
        gain = np.ones((n_channels, 1))
        # Class 0 suppresses mu over "right" channels, class 1 over "left" channels.
        gain[right if label == 0 else left] = 1.0 - effect
        X[i] = noise + gain * mu
    return X, y, groups


@dataclass
class ClassifierReport:
    balanced_accuracy: float
    accuracy: float
    confusion_matrix: list[list[int]]
    n_test_trials: int
    accuracy_ci95: list[float]

    @staticmethod
    def from_predictions(y_true: np.ndarray, y_pred: np.ndarray) -> "ClassifierReport":
        n = int(len(y_true))
        correct = int((y_true == y_pred).sum())
        # Clopper-Pearson interval over held-out trials (the independent unit).
        lo = 0.0 if correct == 0 else float(beta.ppf(0.025, correct, n - correct + 1))
        hi = 1.0 if correct == n else float(beta.ppf(0.975, correct + 1, n - correct))
        return ClassifierReport(
            balanced_accuracy=float(balanced_accuracy_score(y_true, y_pred)),
            accuracy=correct / n,
            confusion_matrix=confusion_matrix(y_true, y_pred, labels=[0, 1]).tolist(),
            n_test_trials=n,
            accuracy_ci95=[lo, hi],
        )


def fit_evaluate(
    X: np.ndarray,
    y: np.ndarray,
    groups: np.ndarray,
    sfreq: float,
    seed: int = 0,
    n_components: int = 4,
    holdout_fraction: float = 0.25,
    progress=None,
) -> dict[str, Any]:
    """Freeze a grouped holdout, cross-validate on the remainder, then fit once and
    score the holdout. Returns a JSON-serializable evaluation record."""
    splitter = GroupShuffleSplit(n_splits=1, test_size=holdout_fraction, random_state=seed)
    train_idx, hold_idx = next(splitter.split(X, y, groups))
    Xtr, ytr, gtr = X[train_idx], y[train_idx], groups[train_idx]
    Xho, yho = X[hold_idx], y[hold_idx]

    n_train_groups = len(np.unique(gtr))
    n_folds = min(5, n_train_groups)
    if n_folds < 2:
        raise ValueError("need at least 2 training runs for grouped cross-validation")
    cv = StratifiedGroupKFold(n_splits=n_folds, shuffle=True, random_state=seed)

    models = {
        "reference_csp_rlda": reference_pipeline(sfreq, n_components),
        "baseline_logvar_rlda": baseline_pipeline(sfreq),
    }
    results: dict[str, Any] = {}
    for step, (name, model) in enumerate(models.items()):
        fold_scores = []
        for k, (a, b) in enumerate(cv.split(Xtr, ytr, gtr)):
            model.fit(Xtr[a], ytr[a])
            fold_scores.append(float(balanced_accuracy_score(ytr[b], model.predict(Xtr[b]))))
            if progress:
                progress({"model": name, "fold": k + 1, "of": n_folds, "step": step + 1, "steps": len(models)})
        model.fit(Xtr, ytr)
        holdout = ClassifierReport.from_predictions(yho, model.predict(Xho))
        results[name] = {
            "cv_balanced_accuracy_per_fold": fold_scores,
            "cv_balanced_accuracy_mean": float(np.mean(fold_scores)),
            "holdout": asdict(holdout),
        }

    return {
        "split_policy": {
            "unit": "trial",
            "grouping": "run",
            "holdout": "GroupShuffleSplit by run, frozen before fitting",
            "holdout_fraction": holdout_fraction,
            "cv": f"StratifiedGroupKFold(n_splits={n_folds}) on training runs",
            "evidence": "same-session",
            "seed": seed,
        },
        "class_counts": {
            "train": np.bincount(ytr, minlength=2).tolist(),
            "holdout": np.bincount(yho, minlength=2).tolist(),
        },
        "exclusions": [],
        "models": results,
        "config": {
            "sfreq": sfreq,
            "bandpass_hz": [8.0, 30.0],
            "bandpass_order": 4,
            "bandpass_direction": "causal",
            "csp_components": n_components,
            "csp_regularization": "ledoit_wolf",
            "lda_shrinkage": "auto",
        },
    }
