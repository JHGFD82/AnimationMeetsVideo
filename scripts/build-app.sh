#!/bin/sh
# Builds AnimationMeetsVideo.app: the SwiftPM executable wrapped in an app
# bundle with Packaging/Info.plist, which declares the .amv project type
# so Finder shows projects as single documents and opens them in the app.
# `swift run` works without this, just without that Finder integration.
#
# Usage: scripts/build-app.sh [output directory, default: build]
set -eu

cd "$(dirname "$0")/.."
output="${1:-build}"
app="$output/AnimationMeetsVideo.app"

swift build -c release --product AnimationMeetsVideo
bin="$(swift build -c release --show-bin-path)"
binary="$bin/AnimationMeetsVideo"
# The resource bundle, which holds the effect packages that ship with the
# app; EffectPackageStore.builtInFolder looks for it in Contents/Resources.
resources="$bin/AnimationMeetsVideo_AnimationMeetsVideo.bundle"

plutil -lint Packaging/Info.plist
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/AnimationMeetsVideo"
cp -R "$resources" "$app/Contents/Resources/"
cp Packaging/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Ad-hoc signed, so it runs on the Mac that built it. Sharing it with
# other Macs needs a Developer ID signature and notarization.
codesign --force --sign - "$app"

# Registers the bundle's types now rather than when Finder next notices it.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$lsregister" ]; then
    "$lsregister" -f "$app" || true
fi

echo "Built $app"
