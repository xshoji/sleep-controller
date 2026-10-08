#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(realpath "$0")")"
ARCH="${1:-$(uname -m)}"
APP="$ROOT/build/SleepController.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -warnings-as-errors -target "$ARCH-apple-macos13.0" \
    -framework AppKit "$ROOT/App.swift" -o "$APP/Contents/MacOS/SleepController"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
