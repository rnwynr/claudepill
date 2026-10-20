#!/bin/sh
# Reinstalls the freshly built app into /Applications and restarts it.
# Pass --dock to run it as a regular Dock app (handy for screenshots while developing).
set -e
cd "$(dirname "$0")/.."
A="/Applications/Claude Pill.app"
pkill -x ClaudePill 2>/dev/null || true
rm -rf "$A"
cp -R "build/Claude Pill.app" "$A"
if [ "$1" = "--dock" ]; then
  /usr/libexec/PlistBuddy -c "Set :LSUIElement false" "$A/Contents/Info.plist"
  codesign --force --sign - "$A" >/dev/null 2>&1
fi
open "$A"
