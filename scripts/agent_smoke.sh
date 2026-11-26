#!/usr/bin/env bash
# Brief 008 smoke run: drives a Debug build end to end through `bci`. It imports the
# example, inspects, evaluates, freezes and replays, then on the synthetic board connects,
# records, and runs an unattended protocol run. Each step's exit code and JSON is checked.
# No hardware (decision #26). Control is turned on by a Debug launch argument and an
# isolated control directory, so the app's saved settings are never touched.
#   scripts/agent_smoke.sh [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Debug/BCIWorkspace.app"
BCI="$APP/Contents/Helpers/bci"
command -v jq >/dev/null || { echo "needs jq: brew install jq" >&2; exit 1; }
if pgrep -x BCIWorkspace >/dev/null; then echo "quit BCI Workspace first (a project is never opened twice)" >&2; exit 1; fi

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> Debug build"
  xcodebuild -project "$ROOT/BCIWorkspace.xcodeproj" -scheme BCIWorkspace -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build >"$ROOT/build/agent-smoke-build.log" 2>&1 \
    || { tail -30 "$ROOT/build/agent-smoke-build.log" >&2; exit 1; }
fi

WORK="$(mktemp -d /tmp/bci-smoke-XXXXXX)"
export BCI_CONTROL_DIR="$WORK/control" BCI_APP_PATH="$APP"
export BCI_PROJECT="$WORK/agent-smoke.bciproj"
"$APP/Contents/MacOS/BCIWorkspace" -BCIAgentControlEnabled YES >"$WORK/app.log" 2>&1 &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 80); do [[ -S "$BCI_CONTROL_DIR/control.sock" ]] && break; sleep 0.25; done
[[ -S "$BCI_CONTROL_DIR/control.sock" ]] || { echo "the app never opened its control socket" >&2; cat "$WORK/app.log" >&2; exit 1; }

step() { # <name> <jq check> -- bci args…
  local name="$1" check="$2"; shift 3
  local out
  if ! out="$("$BCI" "$@" 2>"$WORK/stderr.log")"; then
    echo "FAIL $name (exit $?): $out" >&2; tail -5 "$WORK/stderr.log" >&2; exit 1
  fi
  jq -e "$check" >/dev/null <<<"$out" || { echo "FAIL $name: check $check on $out" >&2; exit 1; }
  echo "ok   $name"
  LAST="$out"
}
expect_exit() { # <name> <code> -- bci args…
  local name="$1" want="$2"; shift 3
  set +e; "$BCI" "$@" >/dev/null 2>&1; local got=$?; set -e
  [[ $got == "$want" ]] || { echo "FAIL $name: exit $got, wanted $want" >&2; exit 1; }
  echo "ok   $name (exit $want)"
}

step "app status"        '.controlEnabled == true'                 -- app status
expect_exit "usage error" 2                                        -- evaluate run --bogus 1
step "import example"    '.recordings | length == 1'               -- project import-example --path "$BCI_PROJECT"
REC="$(jq -r '.recordings[0].recordingID' <<<"$LAST")"
step "verify"            '.ok == true'                             -- recordings verify --recording "$REC"
step "inspect"           '.segments | length > 0'                  -- recordings inspect --recording "$REC"
step "evaluate"          '.accounting.evaluationsOnRecording == 1' -- evaluate run --recording "$REC"
RES="$(jq -r .resultID <<<"$LAST")"
step "reproduce"         '.reproductionOf != null'                 -- evaluate run --recording "$REC"
step "freeze"            '.modelID != null'                        -- models freeze --result "$RES"
MODEL="$(jq -r .modelID <<<"$LAST")"
step "replay"            '.liveRunID != null'                      -- replay run --model "$MODEL" --recording "$REC"
step "export"            '.path != null'                           -- export result --result "$RES" --destination "$WORK/export"
expect_exit "record without a stream" 5                            -- acquisition record --seconds 1
step "connect synthetic" '.state == "streaming"'                   -- acquisition connect --source synthetic --map undeclared
step "record 3 s"        '.recordingID != null'                    -- acquisition record --seconds 3
step "protocols"         '.protocols | length > 0'                 -- protocols list
DRAFT='{"name":"Smoke","classes":[{"label":"cue_left_hand","displayName":"Left hand","cue":"left_arrow"},{"label":"cue_right_hand","displayName":"Right hand","cue":"right_arrow"}],"timing":{"fixationMs":500,"cueMs":2000,"restMinMs":500,"restMaxMs":800},"trialsPerClass":2,"runsPerSession":1,"instructions":"Smoke run."}'
step "new protocol"      '.protocolID != null'                     -- protocols create-version --draft "$DRAFT"
PROTO="$(jq -r .protocolID <<<"$LAST")"
step "unattended run"    '.runs[0].state == "completed"'           -- protocol run --protocol "$PROTO" --seed 1 --operator agent
step "disconnect"        '.state == "disconnected"'                -- acquisition disconnect
[[ -s "$BCI_PROJECT/logs/agent-actions.jsonl" ]] || { echo "FAIL action log missing" >&2; exit 1; }
echo "ok   action log ($(wc -l <"$BCI_PROJECT/logs/agent-actions.jsonl" | tr -d ' ') lines)"
echo "Agent smoke run passed ($WORK)"
