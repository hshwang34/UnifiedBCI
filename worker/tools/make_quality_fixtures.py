"""Dev-time generator for the Swift side's `inspect_recording` and `signal_window`
fixtures (brief 002).

Writes JSON files under `Tests/Fixtures/`, each exactly what the method returns as
`result`:

- `inspect_recording_tiny.json` — the real handler on `Tests/Fixtures/tiny.bciproj`.
- `inspect_recording_faults.json` — the same response shape built from
  `quality.inspect_segment` on synthetic segments with one injected fault per channel,
  plus the cases the tiny fixture never reaches: a non-µV unit, a non-EEG kind, a channel
  with non-finite samples, and rates where a mains line (125 Hz), both (100 Hz) or the
  band-pass (50 Hz) do not fit, and an undeclared unit.
- `signal_window_tiny.json` — `signal_window` on the tiny fixture's first segment, its
  first 10 s (inside the band-pass warm-up), 100 points.
- `signal_window_low_rate.json` — `signal_window.window` at 50 Hz, where the band-pass does
  not fit, with a channel whose samples are non-finite for 2 s.

Both are deterministic; `tests/test_quality.py` regenerates them and compares.

Usage (from `worker/`): uv run python tools/make_quality_fixtures.py
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np

from bciworkspace_worker import main as worker_main
from bciworkspace_worker import quality, signal_window
from bciworkspace_worker.protocol import Request

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "Tests" / "Fixtures"
TINY_RECORDING = "3e2e07c7-ba7a-5111-9cee-57a4e2990416"


class _Ctx:
    def emit(self, *_: Any) -> None: ...
    def check_cancelled(self) -> None: ...


def tiny() -> dict[str, Any]:
    req = Request(id="1", method="inspect_recording",
                  params={"project_dir": str(FIXTURES / "tiny.bciproj"), "recording_id": TINY_RECORDING})
    return worker_main.handle_inspect_recording(req, _Ctx())


def _segment(index: int, sfreq: float, data: np.ndarray, channels: list[tuple[str, str, str]]) -> dict[str, Any]:
    kinds, units = [c[1] for c in channels], [c[2] for c in channels]
    per = quality.inspect_segment(data, sfreq, kinds, units)
    return {"index": index, "run_id": f"R{index + 1:02d}", "sfreq": sfreq, "duration_s": data.shape[1] / sfreq,
            "channels": [{"id": f"ch{i:02d}", "label": c[0], "kind": c[1], "unit": c[2], **per[i]}
                         for i, c in enumerate(channels)]}


def faults() -> dict[str, Any]:
    rng = np.random.default_rng(7)
    sfreq, seconds = 250.0, 60.0
    n = int(sfreq * seconds)
    t = np.arange(n) / sfreq
    channels = [("C3", "eeg", "uV"), ("C4", "eeg", "uV"), ("Cz", "eeg", "uV"), ("FLAT", "eeg", "uV"),
                ("PIN", "eeg", "uV"), ("MAINS", "eeg", "uV"), ("BIG", "eeg", "uV"), ("HF", "eeg", "uV"),
                ("ACC", "accel", "g"), ("EMG", "emg", "uV"), ("MV", "eeg", "mV"), ("NAN", "eeg", "uV")]
    data = 10.0 * rng.standard_normal((len(channels), n))
    data[3, 1000:3000] = 0.0                                  # 8 s flat
    data[4, 5000:5020] = data[4].max() + 5.0                  # 20 samples at the segment maximum
    data[5] += 20.0 * np.sin(2 * np.pi * 60.0 * t)            # 60 Hz line
    data[6] += 40.0 * np.sin(2 * np.pi * 0.2 * t)             # slow drift: variance, not 1 s peak-to-peak
    data[7] += 15.0 * np.sin(2 * np.pi * 35.0 * t)            # 20-45 Hz power
    data[8] = 0.01 * rng.standard_normal(n)
    data[10] = 0.01 * rng.standard_normal(n)
    data[11, 100] = np.nan
    eeg4 = [("C3", "eeg", "uV"), ("C4", "eeg", "uV"), ("Cz", "eeg", "uV"), ("CPz", "eeg", "uV")]
    seg125 = 10.0 * rng.standard_normal((4, int(125.0 * 30)))
    seg100 = 10.0 * rng.standard_normal((4, int(100.0 * 30)))
    seg50 = 10.0 * rng.standard_normal((4, int(50.0 * 30)))     # band-pass does not fit below Nyquist
    low = [("C3", "eeg", ""), ("C4", "eeg", "uV"), ("Cz", "eeg", "uV"), ("CPz", "eeg", "uV")]
    return {"rules": quality.rules(),
            "segments": [_segment(0, sfreq, data, channels), _segment(1, 125.0, seg125, eeg4),
                         _segment(2, 100.0, seg100, eeg4), _segment(3, 50.0, seg50, low)]}


def window_tiny() -> dict[str, Any]:
    req = Request(id="1", method="signal_window",
                  params={"project_dir": str(FIXTURES / "tiny.bciproj"), "recording_id": TINY_RECORDING,
                          "segment": 0, "start_s": 0.0, "duration_s": 10.0, "max_points": 100})
    return worker_main.handle_signal_window(req, _Ctx())


def window_low_rate() -> dict[str, Any]:
    rng = np.random.default_rng(3)
    data = 10.0 * rng.standard_normal((2, 50 * 20))
    data[1, 300:400] = np.nan                          # 2 s missing: four null points
    out = signal_window.window(data, 50.0, 5.0, 10.0, "both", 20)
    out["channels"] = [{"id": f"ch{i:02d}", "label": label, "kind": "eeg", "unit": "uV", **c}
                       for i, (label, c) in enumerate(zip(("C3", "NAN"), out["channels"]))]
    return {"recording_id": "00000000-0000-0000-0000-000000000050", "segment": 0, "run_id": "R01", **out}


BUILDERS = (("inspect_recording_tiny.json", tiny), ("inspect_recording_faults.json", faults),
            ("signal_window_tiny.json", window_tiny), ("signal_window_low_rate.json", window_low_rate))


def dumps(result: dict[str, Any]) -> str:
    return json.dumps(result, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main() -> None:
    for name, build in BUILDERS:
        (FIXTURES / name).write_text(dumps(build()), encoding="utf-8")


if __name__ == "__main__":
    main()
