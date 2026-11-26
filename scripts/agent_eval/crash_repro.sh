#!/usr/bin/env bash
# Brief 009: reproduces the 2026-11-26 click crash. It drives eval scenario 03's flow
# (synthetic connect → record → disconnect) through bci while the Debug app hit-tests its
# windows many times a second (-BCIHitTestStress), the path a mouse-down takes. Exits 0 if
# the app survives every round, 1 if it crashed (the crash report is copied next to the log).
#   scripts/agent_eval/crash_repro.sh [rounds=5] [record-seconds=8]     (STRESS=0: without the hit-test stress)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/BCIWorkspace.app"
BCI="$APP/Contents/Helpers/bci"
ROUNDS="${1:-5}"; SECONDS_PER="${2:-8}"
if pgrep -x BCIWorkspace >/dev/null; then echo "quit BCI Workspace first" >&2; exit 2; fi
WORK="$(mktemp -d /tmp/bci-crash-XXXXXX)"
export BCI_CONTROL_DIR="$WORK/control" BCI_APP_PATH="$APP" BCI_NO_LAUNCH=1
START="$(date +%s)"
STRESS_ARGS=(-BCIHitTestStress YES); [[ "${STRESS:-1}" == 0 ]] && STRESS_ARGS=(-BCIHitTestStress NO)
"$APP/Contents/MacOS/BCIWorkspace" -BCIAgentControlEnabled YES "${STRESS_ARGS[@]}" >"$WORK/app.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 80); do "$BCI" app status >/dev/null 2>&1 && break; sleep 0.25; done
PROJ="$WORK/repro.bciproj"
"$BCI" project import-example --path "$PROJ" >/dev/null
sleep "${DELAY:-0}"      # DELAY=8: let the analysis worker finish starting before connecting
crashed() {
  echo "CRASHED in round $1 ($2)"
  mkdir -p "$WORK/crashes"
  find ~/Library/Logs/DiagnosticReports -name 'BCIWorkspace*.ips' -newermt "@$START" -exec cp {} "$WORK/crashes/" \; 2>/dev/null || true
  ls "$WORK/crashes" 2>/dev/null
  exit 1
}
for r in $(seq 1 "$ROUNDS"); do
  "$BCI" acquisition connect --project "$PROJ" --source synthetic --map undeclared >/dev/null || { kill -0 "$PID" 2>/dev/null || crashed "$r" connect; }
  "$BCI" acquisition record --project "$PROJ" --seconds "$SECONDS_PER" >/dev/null || { kill -0 "$PID" 2>/dev/null || crashed "$r" record; }
  "$BCI" acquisition disconnect --project "$PROJ" >/dev/null || { kill -0 "$PID" 2>/dev/null || crashed "$r" disconnect; }
  kill -0 "$PID" 2>/dev/null || crashed "$r" "between steps"
  echo "round $r ok"
done
echo "survived $ROUNDS rounds ($WORK)"
