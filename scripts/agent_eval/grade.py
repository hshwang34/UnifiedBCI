#!/usr/bin/env python3
"""Grades one agent-eval run (brief 008): the Claude Code transcript plus the project left
on disk, against a scenario's checks. Stdlib only. Prints one JSON object.

    grade.py <scenario.json> <transcript.jsonl> <project.bciproj>
"""
import json
import re
import sys
from pathlib import Path

PREFIX = "mcp__bci__"


def load_transcript(path: Path):
    tools, final, meta = [], "", {}
    for line in path.read_text(errors="replace").splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("type") == "assistant":
            for block in msg.get("message", {}).get("content", []) or []:
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    tools.append({"name": name[len(PREFIX):] if name.startswith(PREFIX) else name, "input": block.get("input") or {}})
        elif msg.get("type") == "result":
            final = msg.get("result") or ""
            meta = {k: msg.get(k) for k in ("num_turns", "total_cost_usd", "duration_ms", "is_error", "subtype")}
    return tools, final, meta


def count(project: Path, child: str, manifest: str) -> int:
    d = project / child
    return sum(1 for p in d.iterdir() if (p / manifest).is_file()) if d.is_dir() else 0


def check(c, tools, final, project):
    t = c["type"]
    if t == "tool_called":
        ok = any(x["name"] == c["tool"] for x in tools)
        return ok, f"{c['tool']} {'called' if ok else 'never called'}"
    if t == "tool_not_called":
        ok = not any(x["name"] == c["tool"] for x in tools)
        return ok, f"{c['tool']} {'not called' if ok else 'called'}"
    if t in ("tool_arg", "tool_not_arg"):
        calls = [x for x in tools if x["name"] == c["tool"]]
        if not calls:
            return False, f"{c['tool']} never called"
        values = [json.dumps(x["input"].get(c["key"])) if not isinstance(x["input"].get(c["key"]), str) else x["input"].get(c["key"]) for x in calls]
        hit = any(v is not None and re.search(c["pattern"], v) for v in values)
        ok = hit if t == "tool_arg" else not hit
        return ok, f"{c['key']} = {values}"
    if t == "results_at_least":
        n = count(project, "results", "result.meta.json")
        return n >= c["n"], f"{n} results"
    if t == "recordings_exactly":
        n = count(project, "recordings", "recording.json")
        return n == c["n"], f"{n} recordings"
    if t == "final_matches":
        m = re.search(c["pattern"], final)
        return bool(m), f"matched {m.group(0)!r}" if m else "no match in the final answer"
    if t == "final_not_matches":
        m = re.search(c["pattern"], final)
        return not m, f"found {m.group(0)!r}" if m else "absent"
    return False, f"unknown check type {t}"


def main():
    scenario = json.loads(Path(sys.argv[1]).read_text())
    tools, final, meta = load_transcript(Path(sys.argv[2]))
    project = Path(sys.argv[3])
    rows = []
    for c in scenario["checks"]:
        ok, detail = check(c, tools, final, project)
        rows.append({"check": c["type"] + (f" {c.get('tool', '')}" if "tool" in c else ""), "pattern": c.get("pattern"),
                     "why": c.get("why", ""), "ok": ok, "detail": detail})
    out = {
        "scenario": scenario["id"], "passed": all(r["ok"] for r in rows) and bool(final),
        "checks": rows, "toolCalls": [x["name"] for x in tools], "final": final, **meta,
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
