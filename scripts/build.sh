#!/bin/sh
# Builds "build/Claude Pill.app" from source.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Claude Pill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudePill "$APP/Contents/MacOS/ClaudePill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp hooks/pill-hook.sh "$APP/Contents/Resources/pill-hook.sh"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
