#!/usr/bin/env bash
# Assemble a relocatable Python worker for embedding in the app bundle.
#
# Output: build/worker-dist/
#   python/   standalone CPython (python-build-standalone via uv), relocatable
#   site/     pinned dependencies + bciworkspace_worker, installed with --target
#
# The Xcode "Copy bundled worker if built" phase rsyncs this into
# BCIWorkspace.app/Contents/Resources/worker/, and WorkerLaunch.locate() prefers it over
# the development venv. Signing/notarizing the hundreds of .so files inside site/ is a
# separate, unproven gate — see docs/adr/0001-native-app-with-bundled-worker.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/worker-dist"
PYVER="3.12"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> standalone CPython $PYVER"
# uv places the interpreter under $OUT/python/cpython-<ver>-macos-aarch64-none/; flatten it.
uv python install "$PYVER" --install-dir "$OUT/python-tmp" --no-bin --no-registry >/dev/null
# uv also leaves a versionless symlink beside the real directory; take the directory.
mv "$(find "$OUT/python-tmp" -maxdepth 1 -type d -name 'cpython-*')" "$OUT/python"
rm -rf "$OUT/python-tmp"

echo "==> pinned dependencies from worker/uv.lock"
(cd "$ROOT/worker" && uv export --no-dev --no-emit-project --frozen -o "$OUT/requirements.txt" >/dev/null)
uv pip install --python "$OUT/python/bin/python3" --target "$OUT/site" --no-cache \
  --requirement "$OUT/requirements.txt" "$ROOT/worker" >/dev/null

echo "==> trim"
find "$OUT" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$OUT/site" -path "*/tests/*" -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$OUT/python/lib/python$PYVER/test" "$OUT/python/share"

echo "==> smoke test"
PYTHONPATH="$OUT/site" "$OUT/python/bin/python3" -c "
import bciworkspace_worker.main as m, json
print(json.dumps(m._versions()))
"
du -sh "$OUT"
echo "bundled worker ready at $OUT (rebuild the app to embed it)"
