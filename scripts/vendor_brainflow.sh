#!/usr/bin/env bash
# Copies the BrainFlow native libraries out of the pinned worker environment so the
# Swift bridge links against exactly the same BrainFlow build the Python worker uses.
# Re-run after `uv sync` bumps brainflow in worker/uv.lock.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/worker/.venv/lib/python3.12/site-packages/brainflow/lib"
DST="$ROOT/native/brainflow/lib"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC not found; run 'uv sync' inside worker/ first" >&2
  exit 1
fi

mkdir -p "$DST"
# Only the board controller is needed for acquisition. DataHandler/MLModule stay in Python.
cp -f "$SRC/libBoardController.dylib" "$DST/"
# Ad-hoc signature from the wheel is fine for local builds; Xcode re-signs on embed.
lipo -info "$DST/libBoardController.dylib"
VERSION="$(cd "$ROOT/worker" && uv pip list 2>/dev/null | awk '$1=="brainflow"{print $2}')"
echo "$VERSION" > "$DST/VERSION"
echo "vendored BrainFlow $VERSION -> $DST"
