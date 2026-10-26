#!/bin/sh
# Builds "build/Claude Pill.app" from source.
#
# Signing matters: macOS ties the Screen Recording permission (and the Apple Events and
# Keychain prompts) to the app's signature. Ad-hoc signatures change on every build, so the
# permission silently stops matching. A stable identity is picked automatically, in this order:
#   1. $SIGN_IDENTITY, if set
#   2. an "Apple Development" / "Developer ID Application" certificate (free via Xcode)
#   3. the local "Claude Pill Local Signing" certificate from scripts/make-signing-cert.sh
#   4. ad-hoc, with a warning
set -e
cd "$(dirname "$0")/.."

LOCAL_CERT="Claude Pill Local Signing"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  # Self-signed certs aren't "valid" to the trust policy, so look them up without -v, by hash.
  SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$LOCAL_CERT\"" 'index($0, name) { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
  echo "⚠︎  No signing certificate found, falling back to ad-hoc signing." >&2
  echo "   macOS will forget the Screen Recording permission after every rebuild." >&2
  echo "   Fix once: scripts/make-signing-cert.sh   (or add an Apple Development cert in Xcode)" >&2
fi

swift build -c release

APP="build/Claude Pill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudePill "$APP/Contents/MacOS/ClaudePill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp hooks/pill-hook.sh "$APP/Contents/Resources/pill-hook.sh"
codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1

echo "Built $APP"
