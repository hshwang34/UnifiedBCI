"""Seeded trial order for the cued protocol (brief 005), mirrored from Swift.

`Sources/Protocol/ProtocolSchedule.swift` is the implementation the app runs; this module
reproduces it exactly so exports can be checked and the golden vectors in
`Tests/Fixtures/protocol_schedule_golden.json` are tested from both sides. It is not on the
evaluation path.

Algorithm `seeded_shuffle_v1` (every step is integer arithmetic, so no platform float or
RNG behaviour can differ):

1. PRNG: SplitMix64 (Steele, Lea, Flood 2014). `state += 0x9E3779B97F4A7C15`, then
   `z = state; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) *
   0x94D049BB133111EB; out = z ^ (z >> 31)`, all mod 2**64. The state starts at the run seed.
2. `below(n)`: an unbiased integer in [0, n) by rejection. `t = (2**64 - n) % n`; draw `x`
   until `x >= t`; return `x % n`. Always draws at least once; n == 0 means 2**64.
3. Order: the class-balanced list (class 0 repeated N times, then class 1 N times), shuffled
   by Fisher-Yates from the end: for i = len-1 down to 1, j = below(i + 1), swap i and j.
4. Rest: after the shuffle, one draw per trial in trial order,
   `rest_ms = rest_min_ms + below(rest_max_ms - rest_min_ms + 1)` (a 1 ms grid).
5. Offsets (ms from the first fixation onset): fixation, cue = fixation + fixation_ms,
   cue_end = cue + cue_ms, end = cue_end + rest_ms; the next trial's fixation is this end.
6. Trial ids are `<runID>-t<nn>`, numbered from 1, at least two digits.

Run seed = session seed + run index (0-based).
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

ORDER = "seeded_shuffle_v1"
MASK = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed: int) -> None:
        if not 0 <= seed <= MASK:
            raise ValueError("seed must be an unsigned 64-bit integer")
        self.state = seed

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, n: int) -> int:
        """Unbiased integer in [0, n); n == 0 stands for 2**64 (one raw draw), as in Swift."""
        if not 0 <= n <= MASK:
            raise ValueError("n must be an unsigned 64-bit integer")
        if n == 0:
            return self.next()
        threshold = ((1 << 64) - n) % n
        while True:
            x = self.next()
            if x >= threshold:
                return x % n


def schedule(labels: list[str], trials_per_class: int, fixation_ms: int, cue_ms: int,
             rest_min_ms: int, rest_max_ms: int, seed: int, run_id: str) -> list[dict[str, Any]]:
    rng = SplitMix64(seed)
    order = [label for label in labels for _ in range(trials_per_class)]
    for i in range(len(order) - 1, 0, -1):
        j = rng.below(i + 1)
        order[i], order[j] = order[j], order[i]
    rests = [rest_min_ms + rng.below(rest_max_ms - rest_min_ms + 1) for _ in order]
    trials, t = [], 0
    for k, (label, rest) in enumerate(zip(order, rests)):
        cue = t + fixation_ms
        cue_end = cue + cue_ms
        end = cue_end + rest
        trials.append({"trialID": f"{run_id}-t{k + 1:02d}", "label": label, "restMs": rest,
                       "fixationOffsetMs": t, "cueOffsetMs": cue, "cueEndOffsetMs": cue_end, "endOffsetMs": end})
        t = end
    return trials


def canonical_content(classes: list[dict[str, str]], timing: dict[str, int], trials_per_class: int,
                      order: str = ORDER) -> str:
    """The bytes `contentHash` covers: what the participant sees and when."""
    content = {"classes": [{"cue": c["cue"], "label": c["label"]} for c in classes],
               "order": order, "timing": timing, "trialsPerClass": trials_per_class}
    return json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def content_hash(classes: list[dict[str, str]], timing: dict[str, int], trials_per_class: int,
                 order: str = ORDER) -> str:
    return hashlib.sha256(canonical_content(classes, timing, trials_per_class, order).encode()).hexdigest()


DEFAULT_CLASSES = [{"label": "cue_left_hand", "cue": "left_arrow"}, {"label": "cue_right_hand", "cue": "right_arrow"}]
DEFAULT_TIMING = {"fixationMs": 2000, "cueMs": 4000, "restMinMs": 1500, "restMaxMs": 2500}

CASES = [
    ("default, seed 0", DEFAULT_CLASSES, 20, DEFAULT_TIMING, 0, "RUN-A"),
    ("default, seed 1", DEFAULT_CLASSES, 20, DEFAULT_TIMING, 1, "RUN-A"),
    ("default, session seed 42 run 3", DEFAULT_CLASSES, 20, DEFAULT_TIMING, 45, "RUN-B"),
    ("default, largest seed", DEFAULT_CLASSES, 20, DEFAULT_TIMING, MASK, "RUN-C"),
    ("one trial per class, fixed rest", DEFAULT_CLASSES, 1,
     {"fixationMs": 500, "cueMs": 1000, "restMinMs": 700, "restMaxMs": 700}, 7, "R1"),
    ("two per class, short phases", [{"label": "a", "cue": "up_arrow"}, {"label": "b", "cue": "down_arrow"}], 2,
     {"fixationMs": 100, "cueMs": 250, "restMinMs": 1, "restMaxMs": 30000}, 0x0123456789ABCDEF, "short"),
    ("100 per class", DEFAULT_CLASSES, 100, DEFAULT_TIMING, 2**52 - 1, "BIG"),
]


def golden_vectors() -> dict[str, Any]:
    raw = []
    for seed in (0, 1, 0x0123456789ABCDEF, MASK):
        rng = SplitMix64(seed)
        raw.append({"seed": f"0x{seed:016x}", "outputs": [f"0x{rng.next():016x}" for _ in range(5)]})
    below = []
    for seed, n in ((0, 1), (0, 2), (0, 3), (5, 1001), (MASK, 7), (9, 2**63 + 1)):
        rng = SplitMix64(seed)
        below.append({"seed": f"0x{seed:016x}", "n": f"0x{n:016x}", "outputs": [f"0x{rng.below(n):016x}" for _ in range(8)]})
    cases = []
    for name, classes, n, timing, seed, run_id in CASES:
        cases.append({"name": name, "classes": classes, "trialsPerClass": n, "timing": timing,
                      "seed": f"0x{seed:016x}", "runID": run_id,
                      "contentCanonical": canonical_content(classes, timing, n),
                      "contentHash": content_hash(classes, timing, n),
                      "trials": schedule([c["label"] for c in classes], n, timing["fixationMs"], timing["cueMs"],
                                         timing["restMinMs"], timing["restMaxMs"], seed, run_id)})
    return {"about": "Golden vectors for seeded_shuffle_v1 (brief 005). Generated by "
                     "worker/src/bciworkspace_worker/protocol_schedule.py; Sources/Protocol/ProtocolSchedule.swift "
                     "must reproduce every value. Seeds and raw PRNG outputs are hex strings (64-bit).",
            "order": ORDER, "splitmix64": raw, "below": below, "schedules": cases}


def golden_bytes() -> bytes:
    """The fixture file's exact bytes (`worker/tools/make_protocol_golden.py` writes them)."""
    return (json.dumps(golden_vectors(), indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode()

