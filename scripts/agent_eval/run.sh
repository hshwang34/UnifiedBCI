#!/usr/bin/env bash
# Agent evaluation (brief 008): runs Claude Code headless against BCI Workspace through
# `bci mcp`, one scenario at a time, then grades the transcript and the project it left.
#
#   scripts/agent_eval/run.sh [--no-build] [--model <model>] [scenario-id-prefix …]
#   scripts/agent_eval/run.sh 01                # one scenario
#   scripts/agent_eval/run.sh                   # all of them
#
# Each scenario uses real Claude usage on the signed-in account. The agent gets only the bci
# MCP tools (no shell, no file edits), the Debug app runs with an isolated control folder,
# and nothing touches hardware (decision #26). Reports go to build/agent-eval/<stamp>/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/agent_eval"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Debug/BCIWorkspace.app"
BCI="$APP/Contents/Helpers/bci"
BUILD=1; MODEL=""; PICK=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --model) MODEL="$2"; shift ;;
    *) PICK+=("$1") ;;
  esac
  shift
done
command -v claude >/dev/null || { echo "needs Claude Code (claude) on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "needs jq: brew install jq" >&2; exit 1; }
if pgrep -x BCIWorkspace >/dev/null; then echo "quit BCI Workspace first (a project is never opened twice)" >&2; exit 1; fi
if [[ $BUILD == 1 ]]; then
  echo "==> Debug build"
  xcodebuild -project "$ROOT/BCIWorkspace.xcodeproj" -scheme BCIWorkspace -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build >"$ROOT/build/agent-eval-build.log" 2>&1 \
    || { tail -30 "$ROOT/build/agent-eval-build.log" >&2; exit 1; }
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/build/agent-eval/$STAMP"
mkdir -p "$OUT"
WORK="$(mktemp -d /tmp/bci-eval-XXXXXX)"
export BCI_CONTROL_DIR="$WORK/control" BCI_APP_PATH="$APP"
"$APP/Contents/MacOS/BCIWorkspace" -BCIAgentControlEnabled YES >"$OUT/app.log" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 80); do [[ -S "$BCI_CONTROL_DIR/control.sock" ]] && break; sleep 0.25; done
[[ -S "$BCI_CONTROL_DIR/control.sock" ]] || { echo "the app never opened its control socket" >&2; exit 1; }

MCP="$WORK/mcp.json"
jq -n --arg bci "$BCI" --arg dir "$BCI_CONTROL_DIR" --arg app "$APP" \
  '{mcpServers: {bci: {command: $bci, args: ["mcp"], env: {BCI_CONTROL_DIR: $dir, BCI_APP_PATH: $app}}}}' >"$MCP"

SUMMARY="$OUT/summary.md"
printf '# Agent eval %s\n\n| Scenario | Result | Checks | Turns | Cost (USD) | Time (s) |\n|---|---|---|---|---|---|\n' "$STAMP" >"$SUMMARY"
PASSED=0; TOTAL=0
for f in "$HERE"/scenarios/*.json; do
  id="$(jq -r .id "$f")"
  if [[ ${#PICK[@]} -gt 0 ]]; then
    match=0; for p in "${PICK[@]}"; do [[ "$id" == "$p"* ]] && match=1; done
    [[ $match == 1 ]] || continue
  fi
  TOTAL=$((TOTAL + 1))
  echo "==> $id"
  project="$WORK/$id.bciproj"
  for s in $(jq -r '.setup[]' "$f"); do
    case "$s" in
      import_example) "$BCI" project import-example --path "$project" >/dev/null ;;
      connect_synthetic) "$BCI" acquisition connect --project "$project" --source synthetic --map undeclared >/dev/null ;;
      *) echo "unknown setup step $s" >&2; exit 1 ;;
    esac
  done
  prompt="$(jq -r .prompt "$f" | sed "s|{project}|$project|g")"
  args=(-p "$prompt" --mcp-config "$MCP" --strict-mcp-config --setting-sources project
        --allowedTools "mcp__bci" --disallowedTools "Bash Edit Write NotebookEdit WebFetch WebSearch Task Agent"
        --output-format stream-json --verbose)
  [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
  (cd "$WORK" && claude "${args[@]}" >"$OUT/$id.jsonl" 2>"$OUT/$id.stderr") || echo "   claude exited non-zero (graded anyway)"
  python3 "$HERE/grade.py" "$f" "$OUT/$id.jsonl" "$project" >"$OUT/$id.grade.json"
  # Leave the app clean for the next scenario: stop jobs, release the board, close the project.
  for j in $("$BCI" jobs list | jq -r '.jobs[] | select(.state == "running" or .state == "awaiting_operator") | .job'); do
    "$BCI" jobs cancel --job "$j" >/dev/null 2>&1 || true
  done
  sleep 1
  "$BCI" acquisition disconnect --project "$project" >/dev/null 2>&1 || true
  "$BCI" project close --project "$project" >/dev/null 2>&1 || true
  g="$OUT/$id.grade.json"
  ok="$(jq -r 'if .passed then "PASS" else "FAIL" end' "$g")"
  [[ "$ok" == PASS ]] && PASSED=$((PASSED + 1))
  printf '| %s | %s | %s | %s | %s | %s |\n' "$id" "$ok" \
    "$(jq -r '[.checks[] | select(.ok)] | length' "$g")/$(jq -r '.checks | length' "$g")" \
    "$(jq -r '.num_turns // "?"' "$g")" "$(jq -r '.total_cost_usd // "?"' "$g")" \
    "$(jq -r 'if .duration_ms then (.duration_ms / 1000 | floor) else "?" end' "$g")" >>"$SUMMARY"
  jq -r '.checks[] | "   \(if .ok then "ok  " else "FAIL" end) \(.check) — \(.detail)"' "$g"
done
{
  printf '\n%s of %s scenarios passed.\n\n## Failed checks\n\n' "$PASSED" "$TOTAL"
  for g in "$OUT"/*.grade.json; do
    jq -r '.scenario as $s | .checks[] | select(.ok | not) | "- **\($s)**: \(.check) — \(.detail)\(if .why != "" then " (\(.why))" else "" end)"' "$g"
  done
  printf '\n## Final answers\n\n'
  for g in "$OUT"/*.grade.json; do jq -r '"### \(.scenario)\n\n\(.final)\n"' "$g"; done
} >>"$SUMMARY"
echo "$PASSED of $TOTAL scenarios passed. Report: $SUMMARY"
