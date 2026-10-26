#!/usr/bin/env bash
# Builds dist/Snappabl.app from the Swift package.
#
#   scripts/build-app.sh              # release build, ad-hoc signed
#   scripts/build-app.sh --install    # ...and copy to /Applications
#   scripts/build-app.sh --run        # ...and launch it
#
# Signing matters: macOS ties the Screen Recording permission to the app's signature.
# Ad-hoc signatures change on every build, so the permission silently stops matching.
# This script picks a stable identity automatically, in this order:
#   1. $SIGN_IDENTITY, if set
#   2. an "Apple Development" / "Developer ID Application" certificate (free via Xcode)
#   3. the local "Snappabl Local Signing" certificate from scripts/make-signing-cert.sh
#   4. ad-hoc, with a warning
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Snappabl"
LOCAL_CERT="Snappabl Local Signing"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # Self-signed certs aren't "valid" to the trust policy, so look them up without -v, by hash.
  SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$LOCAL_CERT\"" 'index($0, name) { print $2; exit }')"
fi
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="-"
  cat >&2 <<'EOF'
⚠︎  No signing certificate found, falling back to ad-hoc signing.
   macOS will forget the Screen Recording permission after every rebuild.
   Fix once: scripts/make-signing-cert.sh   (or add an Apple Development cert in Xcode)
EOF
fi
INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "▸ Building (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="dist/${APP_NAME}.app"
echo "▸ Bundling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Signing (${SIGN_IDENTITY})…"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Snappabl.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  APP="/Applications/${APP_NAME}.app"
fi

if [[ $RUN -eq 1 ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi

echo "✓ $APP"
