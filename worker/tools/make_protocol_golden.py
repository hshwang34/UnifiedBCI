"""Writes Tests/Fixtures/protocol_schedule_golden.json from the worker's reference
`protocol_schedule` (brief 005). Run after a deliberate change to `seeded_shuffle_v1` or
its cases; the Swift and Python tests both read the file.

    (cd worker && uv run python tools/make_protocol_golden.py)
"""

from __future__ import annotations

from pathlib import Path

from bciworkspace_worker.protocol_schedule import golden_bytes

OUT = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "protocol_schedule_golden.json"

if __name__ == "__main__":
    OUT.write_bytes(golden_bytes())
    print(f"wrote {OUT}")
