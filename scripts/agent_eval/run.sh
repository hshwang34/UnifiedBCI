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
# Brief 009: crash reports newer than this marker are copied into the report.
RUN_START="$OUT/.run-start"; touch "$RUN_START"
WORK="$(mktemp -d /tmp/bci-eval-XXXXXX)"
export BCI_CONTROL_DIR="$WORK/control" BCI_APP_PATH="$APP" BCI_NO_LAUNCH=1
APP_PID=""
start_app() { # (re)launches the Debug app and waits for its control socket
  "$APP/Contents/MacOS/BCIWorkspace" -BCIAgentControlEnabled YES >>"$OUT/app.log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 80); do
    [[ -S "$BCI_CONTROL_DIR/control.sock" ]] && "$BCI" app status >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "the app never opened its control socket" >&2; exit 1
}
app_alive() { kill -0 "$APP_PID" 2>/dev/null; }
trap 'kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true' EXIT
start_app

MCP="$WORK/mcp.json"
jq -n --arg bci "$BCI" --arg dir "$BCI_CONTROL_DIR" --arg app "$APP" \
  '{mcpServers: {bci: {command: $bci, args: ["mcp"], env: {BCI_CONTROL_DIR: $dir, BCI_APP_PATH: $app, BCI_NO_LAUNCH: "1"}}}}' >"$MCP"

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
  app_alive || { echo "   the app was not running; relaunching"; start_app; }
  for s in $(jq -r '.setup[]' "$f"); do
    case "$s" in
      import_example) "$BCI" project import-example --path "$project" >/dev/null || echo "   setup $s failed" ;;
      connect_synthetic) "$BCI" acquisition connect --project "$project" --source synthetic --map undeclared >/dev/null || echo "   setup $s failed" ;;
      *) echo "unknown setup step $s" >&2; exit 1 ;;
    esac
  done
  prompt="$(jq -r .prompt "$f" | sed "s|{project}|$project|g")"
  args=(-p "$prompt" --mcp-config "$MCP" --strict-mcp-config --setting-sources project
        --allowedTools "mcp__bci" --disallowedTools "Bash Edit Write NotebookEdit WebFetch WebSearch Task Agent"
        --output-format stream-json --verbose)
  [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
  (cd "$WORK" && claude "${args[@]}" >"$OUT/$id.jsonl" 2>"$OUT/$id.stderr") || echo "   claude exited non-zero (graded anyway)"
  crashed=false; app_alive || crashed=true
  python3 "$HERE/grade.py" "$f" "$OUT/$id.jsonl" "$project" "$crashed" >"$OUT/$id.grade.json"
  if [[ $crashed == true ]]; then echo "   THE APP CRASHED during this scenario (see ~/Library/Logs/DiagnosticReports)"; start_app; fi
  # Brief 009: what the app was doing (after a crash, the relaunched app summarises the report).
  "$BCI" app diagnostics >"$OUT/$id.diagnostics.json" 2>/dev/null || true
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
# Brief 009: any BCI Workspace crash reports written during this run.
CRASHES=()
while IFS= read -r f; do CRASHES+=("$f"); done < <(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'BCIWorkspace*.ips' -newer "$RUN_START" 2>/dev/null | sort)
{
  printf '\n## Crash reports\n\n'
  if [[ ${#CRASHES[@]} -eq 0 ]]; then
    printf 'None.\n'
  else
    mkdir -p "$OUT/crashes"
    for f in "${CRASHES[@]}"; do cp "$f" "$OUT/crashes/" && printf -- '- `crashes/%s`\n' "$(basename "$f")"; done
  fi
  printf '\nEach scenario'"'"'s app diagnostics: `<id>.diagnostics.json`.\n'
} >>"$SUMMARY"
echo "$PASSED of $TOTAL scenarios passed. Report: $SUMMARY"
