#!/usr/bin/env bash
# One Debug BCI Workspace at a time (brief 009). Two running copies break each other's
# snapshots and project opens, so every script or agent that launches the app wraps the run:
#   scripts/app_lock.sh <command …>      waits (up to 30 min) for the lock, runs, releases
# The lock is a directory in /tmp shared by every worktree; a lock whose owner is gone is taken over.
set -uo pipefail
LOCK="/tmp/bci-workspace-app.lock"
deadline=$(( $(date +%s) + 1800 ))
while ! mkdir "$LOCK" 2>/dev/null; do
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  (( $(date +%s) > deadline )) && { echo "app_lock: gave up waiting for $LOCK (owner $owner)" >&2; exit 75; }
  sleep 3
done
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
while pgrep -x BCIWorkspace >/dev/null; do sleep 2; done   # an unlocked run still finishing
"$@"
