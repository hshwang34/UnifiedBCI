#!/usr/bin/env bash
# Assemble the Python worker for embedding in the app bundle (arm64 only, decision #5).
#
# Output: build/worker-dist/
#   python/   standalone CPython (python-build-standalone via uv); the interpreter is
#             statically linked, so libpython*.dylib is deleted along with Tcl/Tk, IDLE,
#             ensurepip and pip
#   site/     pinned runtime dependencies + bciworkspace_worker, installed with --target;
#             MNE and everything it drags in never enter (dev dependency group only),
#             BrainFlow keeps only its darwin libraries, tests/.pyi/datasets are dropped
#
# The Xcode "Copy bundled worker if built" phase rsyncs this into
# BCIWorkspace.app/Contents/Resources/worker/, and WorkerLaunch.locate() prefers it over
# the development venv. Bytecode is not precompiled: the app launches the interpreter
# with -B / PYTHONDONTWRITEBYTECODE so nothing is ever written inside the bundle.
#
# Usage: scripts/bundle_worker.sh [--sign "<Developer ID identity>"]
#   --sign  signs every Mach-O (interpreter, .so, .dylib) with --force --options runtime
#           --timestamp, one file at a time (no --deep). Off by default; signing the
#           whole app is the fast-lane track's job and reruns this with an identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/worker-dist"
PYVER="3.12"
SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN_IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: the bundled worker is built for arm64 only (decision #5); run on Apple Silicon" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> standalone CPython $PYVER"
# uv places the interpreter under $OUT/python/cpython-<ver>-macos-aarch64-none/; flatten it.
uv python install "$PYVER" --install-dir "$OUT/python-tmp" --no-bin --no-registry >/dev/null
# uv also leaves a versionless symlink beside the real directory; take the directory.
mv "$(find "$OUT/python-tmp" -maxdepth 1 -type d -name 'cpython-*')" "$OUT/python"
rm -rf "$OUT/python-tmp"

echo "==> verify the interpreter does not need libpython"
if otool -L "$OUT/python/bin/python3" | grep -q libpython; then
  echo "error: python3 links libpython dynamically; do not delete it" >&2
  exit 1
fi

echo "==> pinned runtime dependencies from worker/uv.lock (no dev group: no MNE)"
(cd "$ROOT/worker" && uv export --no-dev --no-emit-project --frozen -o "$OUT/requirements.txt" >/dev/null)
uv pip install --python "$OUT/python/bin/python3" --target "$OUT/site" --no-cache \
  --requirement "$OUT/requirements.txt" "$ROOT/worker" >/dev/null
if [[ -d "$OUT/site/mne" ]]; then
  echo "error: mne landed in the runtime set; it must stay in the dev dependency group" >&2
  exit 1
fi

echo "==> trim interpreter"
PYLIB="$OUT/python/lib/python$PYVER"
rm -f "$OUT/python/lib/libpython$PYVER.dylib"
rm -rf "$OUT/python/lib"/tcl* "$OUT/python/lib"/tk* "$OUT/python/lib"/itcl* "$OUT/python/lib"/thread* \
       "$OUT/python/lib"/libtcl* "$OUT/python/lib"/libtk* "$OUT/python/lib/pkgconfig" \
       "$PYLIB/idlelib" "$PYLIB/ensurepip" "$PYLIB/tkinter" "$PYLIB/turtledemo" "$PYLIB/test" \
       "$PYLIB/site-packages/pip" "$PYLIB/site-packages"/pip-*.dist-info \
       "$OUT/python/share" "$OUT/python/include" "$OUT/python/bin/idle3"* "$OUT/python/bin/pip"* "$OUT/python/bin/2to3"* \
       "$OUT/python/bin/python3"*-config
rm -f "$PYLIB/lib-dynload/_tkinter"*.so

echo "==> trim BrainFlow to darwin libraries (the worker never opens a board)"
find "$OUT/site/brainflow/lib" -type f \( -name '*.dll' -o -name '*.so' \) -delete
find "$OUT/site/brainflow/lib" -type f -name 'libonnxruntime*' ! -name '*arm64*' -delete

echo "==> trim site-packages"
find "$OUT" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$OUT/site" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true  # not "testing": numpy.testing is imported at runtime
find "$OUT/site" -type f -name '*.pyi' -delete
rm -rf "$OUT/site/scipy/datasets" "$OUT/site/sklearn/datasets" "$OUT/site/bin"
find "$OUT/site" -maxdepth 1 -type d -name '*.dist-info' -exec sh -c 'rm -f "$1"/RECORD "$1"/*.pth 2>/dev/null; true' _ {} \;

echo "==> verify every Mach-O is darwin/arm64 only"
BAD_ARCH=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  if ! lipo -archs "$f" 2>/dev/null | grep -qw arm64; then
    echo "   not arm64: ${f#$OUT/}" >&2; BAD_ARCH=1
  fi
done < <(find "$OUT" -type f \( -name '*.so' -o -name '*.dylib' -o -path '*/bin/*' \) -print0)
[[ $BAD_ARCH -eq 0 ]] || { echo "error: foreign-architecture binaries remain" >&2; exit 1; }

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> sign every Mach-O with '$SIGN_IDENTITY' (hardened runtime, timestamp, no --deep)"
  COUNT=0
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
      COUNT=$((COUNT + 1))
    fi
  done < <(find "$OUT" -type f -print0)
  echo "   signed $COUNT Mach-O files"
fi

echo "==> smoke test (isolated interpreter, scrubbed environment, same flags as the app)"
env -i HOME="$HOME" PATH=/usr/bin:/bin PYTHONPATH="$OUT/site" \
  "$OUT/python/bin/python3" -s -P -u -B -X utf8 -c "
import json
import bciworkspace_worker.main as m
from bciworkspace_worker import pipeline
segs = pipeline.make_synthetic_runs(n_runs=4, trials_per_run=6, n_channels=4)
rec = pipeline.fit_evaluate(segs, seed=0, n_components=2)
assert rec['models']['reference_csp_rlda']['holdout']['n_test_trials'] > 0
print(json.dumps(m._versions()))
"
du -sh "$OUT" "$OUT/python" "$OUT/site" "$OUT/site/brainflow" | sed 's#'"$ROOT"'/##'
echo "bundled worker ready at $OUT (rebuild the app to embed it)"
