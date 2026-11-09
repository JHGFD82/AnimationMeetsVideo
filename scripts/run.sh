#!/bin/sh
# Builds AnimationMeetsVideo.app (debug, for speed) and opens it. Use this
# rather than `swift run`: without a bundle, the system save panel that
# New Project shows doesn't take typing, and macOS doesn't know the
# project and effect package types.
#
# A copy already running is asked to quit first, as Quit in its menu
# would (so it offers to save), since `open` would otherwise just bring
# that older build forward.
#
# Usage: scripts/run.sh [release]
set -eu

cd "$(dirname "$0")/.."
bundle_id="$(plutil -extract CFBundleIdentifier raw Packaging/Info.plist)"

CONFIGURATION="${1:-debug}" scripts/build-app.sh build

if [ "$(osascript -e "application id \"$bundle_id\" is running")" = "true" ]; then
    echo "Quitting the running copy…"
    osascript -e "tell application id \"$bundle_id\" to quit" || true
    while pgrep -f "AnimationMeetsVideo.app/Contents/MacOS/AnimationMeetsVideo" >/dev/null; do
        sleep 0.5
    done
fi

open build/AnimationMeetsVideo.app
