#!/usr/bin/env bash
# Cut a signed, notarized, stapled Developer ID release of BCI Workspace (docs/RELEASING.md).
#
# Usage: scripts/release.sh <version> [build-number]
#   version       CFBundleShortVersionString, e.g. 0.1.0
#   build-number  CFBundleVersion; defaults to the commit count of HEAD
#
# Output: build/release/BCIWorkspace-<version>.dmg and BCIWorkspace-<version>.dmg.sha256
#
# Steps: temporary keychain with the Developer ID identity -> bundled worker, every Mach-O
# signed (hardened runtime, timestamp) -> xcodegen -> Release build signed by Xcode ->
# per-Mach-O verification -> notarize + staple the app -> DMG (app + /Applications) ->
# sign, notarize + staple the DMG -> Gatekeeper assessment of both.
#
# Signing material is read from outside the repo and never printed:
#   BCI_SIGNING_P12        Developer ID Application .p12   (default ~/.config/streamhijack-signing/developer-id.p12)
#   BCI_SIGNING_P12_PASS   file holding its password       (default ~/.config/streamhijack-signing/p12-password.txt)
#   BCI_ASC_CONFIG         env file with ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                          (App Store Connect API key for notarytool; default ~/.appstoreconnect/config.env)
#   BCI_KEYCHAIN_DIR       parent folder for the throwaway keychain (default $TMPDIR)
# The login keychain is never touched: the identity lives in a throwaway keychain that is
# removed, and the original keychain search list restored, on every exit path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <version, e.g. 0.1.0> [build-number]" >&2; exit 2; }
BUILD_NUMBER="${2:-$(git -C "$ROOT" rev-list --count HEAD)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "error: build number must be an integer" >&2; exit 2; }

P12="${BCI_SIGNING_P12:-$HOME/.config/streamhijack-signing/developer-id.p12}"
P12_PASS_FILE="${BCI_SIGNING_P12_PASS:-$HOME/.config/streamhijack-signing/p12-password.txt}"
ASC_CONFIG="${BCI_ASC_CONFIG:-$HOME/.appstoreconnect/config.env}"
TEAM_ID="V56DG94ZL5"

for f in "$P12" "$P12_PASS_FILE" "$ASC_CONFIG"; do
  [[ -r "$f" ]] || { echo "error: missing signing input: $f" >&2; exit 1; }
done
# shellcheck disable=SC1090
source "$ASC_CONFIG"
: "${ASC_KEY_ID:?ASC_KEY_ID not set in $ASC_CONFIG}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID not set}" "${ASC_KEY_PATH:?ASC_KEY_PATH not set}"
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
[[ -r "$ASC_KEY_PATH" ]] || { echo "error: App Store Connect key not readable" >&2; exit 1; }

OUT="$ROOT/build/release"
WORK="$OUT/work"
APP_NAME="BCIWorkspace"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
rm -rf "$WORK" "$DMG" "$DMG.sha256"
mkdir -p "$WORK"

# --- temporary keychain -------------------------------------------------------------------
KC_PARENT="${BCI_KEYCHAIN_DIR:-${TMPDIR:-/tmp}}"   # where the throwaway keychain lives
KC="$(mktemp -d "$KC_PARENT/bci-release.XXXXXX")/signing.keychain-db"
KC_PASS="$(uuidgen)"
ORIG_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && ORIG_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)

cleanup() {
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" 2>/dev/null || true
  security delete-keychain "$KC" 2>/dev/null || true
  rm -rf "$(dirname "$KC")"
  # The signed worker is embedded by now; leaving build/worker-dist would make the next
  # Debug build embed it too, and the tests expect the dev venv.
  rm -rf "$ROOT/build/worker-dist"
}
trap cleanup EXIT

echo "==> temporary signing keychain"
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings -lut 7200 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$P12" -k "$KC" -f pkcs12 -P "$(cat "$P12_PASS_FILE")" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
security list-keychains -d user -s "$KC" "${ORIG_KEYCHAINS[@]}"

IDENTITY_LINE="$(security find-identity -v -p codesigning "$KC" | grep "Developer ID Application: .*($TEAM_ID)" | head -1)"
[[ -n "$IDENTITY_LINE" ]] || { echo "error: no Developer ID Application identity for team $TEAM_ID in the .p12" >&2; exit 1; }
IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"
IDENTITY_NAME="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$IDENTITY_LINE")"
echo "   identity: $IDENTITY_NAME"

# --- build --------------------------------------------------------------------------------
echo "==> bundle the worker, signing every Mach-O"
"$ROOT/scripts/bundle_worker.sh" --sign "$IDENTITY_HASH"

echo "==> xcodegen"
(cd "$ROOT" && xcodegen generate --quiet)

echo "==> Release build $VERSION ($BUILD_NUMBER)"
DERIVED="$WORK/DerivedData"
set -o pipefail
xcodebuild -project "$ROOT/BCIWorkspace.xcodeproj" -scheme BCIWorkspace -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY_NAME" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $KC" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build >"$WORK/xcodebuild.log" 2>&1 || { tail -40 "$WORK/xcodebuild.log" >&2; echo "error: build failed (log: $WORK/xcodebuild.log)" >&2; exit 1; }
APP="$WORK/$APP_NAME.app"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"
[[ -x "$APP/Contents/Resources/worker/python/bin/python3" ]] || { echo "error: the worker was not embedded" >&2; exit 1; }

# --- verify -------------------------------------------------------------------------------
echo "==> verify signatures"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
FAILED=0; CHECKED=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  CHECKED=$((CHECKED + 1))
  info="$(codesign -dvvv "$f" 2>&1 || true)"
  if ! grep -q "^Authority=Developer ID Application: .*($TEAM_ID)" <<<"$info" \
     || ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$info" \
     || ! grep -q '^Timestamp=' <<<"$info"; then
    echo "   bad signature: ${f#$APP/}" >&2; FAILED=1
  fi
done < <(find "$APP" -type f -print0)
[[ $FAILED -eq 0 ]] || { echo "error: some Mach-O files lack Developer ID + runtime + timestamp" >&2; exit 1; }
echo "   $CHECKED Mach-O files: Developer ID ($TEAM_ID), hardened runtime, secure timestamp"

# --- notarize -----------------------------------------------------------------------------
notarize() { # <file> <label>
  local file="$1" label="$2" json id status
  echo "==> notarize $label (waits for Apple)"
  json="$WORK/notary-$label.json"
  xcrun notarytool submit "$file" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 1h --output-format json >"$json" || true
  id="$(/usr/bin/plutil -extract id raw -o - "$json" 2>/dev/null || true)"
  status="$(/usr/bin/plutil -extract status raw -o - "$json" 2>/dev/null || true)"
  echo "   submission ${id:-?}: ${status:-no status}"
  if [[ "$status" != "Accepted" ]]; then
    cat "$json" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
    fi
    echo "error: notarization of $label failed" >&2; exit 1
  fi
}

ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
notarize "$WORK/$APP_NAME.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# --- DMG ----------------------------------------------------------------------------------
echo "==> DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "BCI Workspace $VERSION" -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY_HASH" --keychain "$KC" "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper"
spctl -a -vvv -t install "$DMG"
spctl -a -vvv "$APP"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo
echo "release ready: $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
