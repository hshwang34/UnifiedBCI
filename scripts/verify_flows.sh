#!/usr/bin/env bash
# Brief 009: drives every major flow of a Debug build through its own launch arguments
# (App/LaunchArguments.swift). For each flow it checks four things:
#   - the app exits on its own (no hang)
#   - it doesn't crash (no new crash report)
#   - its event log has no errors
#   - the expected snapshots exist
# Snapshots go to build/verify/<stamp>/<flow>/ for review. No hardware (decision #26).
#   scripts/verify_flows.sh [flow-name …]       (default: all flows)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/BCIWorkspace.app/Contents/MacOS/BCIWorkspace"
[[ -x "$APP" ]] || { echo "build the Debug app first" >&2; exit 2; }
if pgrep -x BCIWorkspace >/dev/null; then echo "quit BCI Workspace first" >&2; exit 2; fi
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/build/verify/$STAMP"
WORK="$(mktemp -d /tmp/bci-verify-XXXXXX)"
mkdir -p "$OUT"
LOGDIR="$HOME/Library/Logs/BCIWorkspace"
PASS=0; FAIL=0; SUMMARY="$OUT/summary.md"
printf '# Flow verification %s\n\n| Flow | Result | Time (s) | Snapshots | Notes |\n|---|---|---|---|---|\n' "$STAMP" >"$SUMMARY"

# name | timeout s | expected snapshot prefixes (space-separated) | launch arguments
FLOWS=(
  "evaluate|240|recordings result reproduction pipelines protocols|-BCIExploreExampleAt {w}/eval.bciproj -BCIAutoEvaluate 2 -BCIWindowSize 1280x800"
  "freeze-replay|300|freeze-sheet pipelines-models replay-parity|-BCIExploreExampleAt {w}/freeze.bciproj -BCIAutoEvaluate 1 -BCIFreezeAndReplay YES"
  "protocol-editor|180|protocol-editor protocols-v2|-BCIExploreExampleAt {w}/proto.bciproj -BCIProtocolEditor YES"
  "quality|240|quality quality-trace|-BCIExploreExampleAt {w}/quality.bciproj -BCIRecordingTab quality -BCIQualityTrace YES"
  "live-demo|240|live-preview live-recording live-stopped live-recorded|-BCIExploreExampleAt {w}/live.bciproj -BCIConnectSource demo -BCILiveRecordSeconds 6"
  "live-synthetic|240|live-preview live-recording live-recorded|-BCIExploreExampleAt {w}/syn.bciproj -BCIConnectSource synthetic -BCILiveRecordSeconds 6"
  "protocol-run|420|run-start-sheet run-instructions run-cue run-summary run-evaluated|-BCIExploreExampleAt {w}/run.bciproj -BCIConnectSource synthetic -BCIStartRun 2"
  "live-test|600|live-setup live-instructions live-feedback live-run-done live-card|-BCIExploreExampleAt {w}/livetest.bciproj -BCIConnectSource synthetic -BCILiveTest 2"
  "guide|75|guide guide-showme|-BCIExploreExampleAt {w}/guide.bciproj -BCIGuideGoal train -BCIGuideShowMe YES"
  "guide-picker|120|guide-picker|-BCIExploreExampleAt {w}/picker.bciproj -BCIGuidePicker YES"
  "intro|120|intro-0-light intro-4-dark montage-top-light|-BCIOffscreenSnapshotDir {s}"
  "agent-card|60|welcome|-BCIShowAgentCard YES"
  "failing-worker|180|banner|-BCIExploreExampleAt {w}/fail.bciproj -BCIAutoEvaluate 1 -BCIFailingWorker YES"
)

for row in "${FLOWS[@]}"; do
  IFS='|' read -r name limit expect args <<<"$row"
  if [[ $# -gt 0 ]]; then keep=0; for a in "$@"; do [[ "$name" == "$a" ]] && keep=1; done; [[ $keep == 1 ]] || continue; fi
  snaps="$OUT/$name"; mkdir -p "$snaps"
  args="${args//\{w\}/$WORK/$name}"; args="${args//\{s\}/$snaps}"; mkdir -p "$WORK/$name"
  before="$(ls "$LOGDIR"/*.jsonl 2>/dev/null | wc -l)"
  crash_mark="$WORK/$name.mark"; touch "$crash_mark"
  start=$(date +%s)
  # shellcheck disable=SC2086
  "$APP" $args ${EXTRA_ARGS:-} -BCISnapshotDir "$snaps" -BCIQuitWhenDone YES >"$snaps/app.log" 2>&1 &
  pid=$!
  hung=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) - start > limit )); then hung=1; break; fi
    sleep 1
  done
  secs=$(( $(date +%s) - start ))
  notes=()
  if [[ $hung == 1 ]]; then
    sample "$pid" 2 -file "$snaps/hang-sample.txt" >/dev/null 2>&1 || true
    xcrun swift-inspect dump-concurrency "$pid" >"$snaps/hang-tasks.txt" 2>/dev/null || true
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
    notes+=("HUNG after ${limit}s (sample + task dump saved)")
  else
    wait "$pid"; code=$?
    [[ $code == 0 ]] || notes+=("exit code $code")
  fi
  crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'BCIWorkspace*.ips' -newer "$crash_mark" 2>/dev/null)"
  if [[ -n "$crashes" ]]; then mkdir -p "$snaps/crashes"; cp $crashes "$snaps/crashes/"; notes+=("CRASHED"); fi
  log="$(ls -t "$LOGDIR"/*.jsonl 2>/dev/null | head -1)"
  [[ -n "$log" ]] && cp "$log" "$snaps/events.jsonl"
  errs=0; [[ -n "$log" ]] && errs=$(grep -c '"level":"\(error\|fault\)"' "$log" || true)
  [[ $errs -gt 0 ]] && notes+=("$errs error events")
  missing=()
  for p in $expect; do ls "$snaps"/"$p"*.png >/dev/null 2>&1 || missing+=("$p"); done
  [[ ${#missing[@]} -gt 0 ]] && notes+=("missing snapshots: ${missing[*]}")
  count=$(ls "$snaps"/*.png 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${#notes[@]} -eq 0 || ( ${#notes[@]} -eq 1 && "${notes[0]}" == *"error events"* && $name == failing-worker ) ]]; then
    result=PASS; PASS=$((PASS + 1))
  else
    result=FAIL; FAIL=$((FAIL + 1))
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$name" "$result" "$secs" "$count" "${notes[*]:-}" >>"$SUMMARY"
  echo "$result $name (${secs}s, $count snapshots) ${notes[*]:-}"
done
printf '\n%s passed, %s failed.\n' "$PASS" "$FAIL" >>"$SUMMARY"
echo "$PASS passed, $FAIL failed. Report: $SUMMARY"
[[ $FAIL == 0 ]]
