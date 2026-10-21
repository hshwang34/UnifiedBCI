#!/usr/bin/env bash
# One-shot developer setup: pinned Python worker env, vendored BrainFlow dylib, Xcode project.
# Requirements: Xcode 26, Homebrew `uv` and `xcodegen`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v uv >/dev/null || { echo "install uv: brew install uv" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }

echo "==> worker: uv sync (pinned via worker/uv.lock)"
(cd "$ROOT/worker" && uv sync)

echo "==> vendor BrainFlow native library"
"$ROOT/scripts/vendor_brainflow.sh"

echo "==> generate BCIWorkspace.xcodeproj"
(cd "$ROOT" && xcodegen generate)

echo
echo "Done. Open BCIWorkspace.xcodeproj, or:"
echo "  xcodebuild -project BCIWorkspace.xcodeproj -scheme BCIWorkspace test"
