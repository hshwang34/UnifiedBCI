"""Dev-time generator for BrainFlow playback-file fixtures (brief 004, PR 1).

Writes `Tests/Fixtures/playback_cyton_daisy_faults.csv`: 200 received samples in BrainFlow's
own file layout for Cyton+Daisy (board 2) — one line per sample, 32 tab-separated values,
`%.6f`, exactly what `DataFilter.write_file` produces and what the playback-file board (-3)
reads back. Row 0 is the package counter (even values, step 2, mod 256), rows 1–16 EEG in
µV, row 30 the wall-clock timestamp, row 31 the marker (0). Everything else is 0.

Injected transport faults, by received-sample index (the Swift bridge test asserts each
one comes out of `SequenceAccounting` with the right evidence):

- counters start at 200, so they wrap 254 -> 0 cleanly at sample 28 (not a gap);
- 60: two samples lost (counter +6, timestamp +3 periods);
- 100: stale half — counter repeats, Daisy rows 9–16 repeat the previous sample;
- 140: invalid counter (7.5) — the sample arrives, its counter byte does not parse;
- the second wrap is a skip: 252 -> 2, two samples (254 and 0) lost across the wrap.

Timestamps advance by 1/125 s per received sample plus the lost samples' time, from a
fixed base, so the file is byte-deterministic. Values are exact decimals (no libm).

Usage (from `worker/`): uv run python tools/make_playback_fixture.py
"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FAULTS_CSV = REPO / "Tests" / "Fixtures" / "playback_cyton_daisy_faults.csv"

ROWS = 32  # BoardShim.get_num_rows(CYTON_DAISY_BOARD)
COUNTER_ROW, TIMESTAMP_ROW = 0, 30
EEG_ROWS = range(1, 17)
DAISY_ROWS = range(9, 17)
RATE = 125
BASE_TIMESTAMP = 1_763_600_000.0
RECEIVED = 200


def fault_samples() -> list[list[float]]:
    samples: list[list[float]] = []
    counter, period = 200, 0  # counter of the next sample; its time in sample periods
    wraps = 0
    for i in range(RECEIVED):
        if i == 60:
            counter, period = (counter + 4) % 256, period + 2
        if counter == 254 and samples and wraps == 1:  # second wrap: lose 254 and 0
            counter, period = 2, period + 2
        row = [0.0] * ROWS
        for r in EEG_ROWS:
            row[r] = ((period * 7 + r * 13) % 200 - 100) * 0.5
        if i == 100:
            counter = int(samples[-1][COUNTER_ROW])  # stale half: no new counter
            for r in DAISY_ROWS:
                row[r] = samples[-1][r]
        row[COUNTER_ROW] = 7.5 if i == 140 else float(counter)
        row[TIMESTAMP_ROW] = BASE_TIMESTAMP + period / RATE
        samples.append(row)
        if counter == 254:
            wraps += 1
        counter, period = (counter + 2) % 256, period + 1
    return samples


def render(samples: list[list[float]]) -> str:
    return "".join("\t".join(f"{v:.6f}" for v in s) + "\n" for s in samples)


def main() -> None:
    FAULTS_CSV.write_text(render(fault_samples()), encoding="ascii")
    print(f"wrote {FAULTS_CSV.relative_to(REPO)}")


if __name__ == "__main__":
    main()
