#!/bin/bash
# Builds Knolling and installs it to ~/Applications/Knolling.app, then opens it.
# Build scratch lives in ~/Library/Caches so iCloud doesn't sync it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HOME/Library/Caches/knolling-build"
APP="$HOME/Applications/Knolling.app"

# Your own bundle id and settings live in mine.env, which isn't part of the public repo.
[ -f "$HERE/mine.env" ] && source "$HERE/mine.env"
BUNDLE_ID="${KNOLLING_BUNDLE_ID:-com.example.knolling}"

swift build -c release --package-path "$HERE" --scratch-path "$SCRATCH"

pkill -x Knolling 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Knolling" "$APP/Contents/MacOS/Knolling"
sed "s/com.example.knolling/$BUNDLE_ID/" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$HERE/RECORD-STYLE.md" "$APP/Contents/Resources/RECORD-STYLE.md"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$HERE"/Fonts/*.ttf "$HERE/Fonts/OFL.txt" "$APP/Contents/Resources/Fonts/"
codesign --force --sign - "$APP"

open "$APP"
echo "Installed $APP"
