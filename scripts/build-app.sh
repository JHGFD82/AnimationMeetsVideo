#!/bin/sh
# Builds AnimationMeetsVideo.app: the SwiftPM executable wrapped in an app
# bundle with Packaging/Info.plist, which declares the .amv project type
# so Finder shows projects as single documents and opens them in the app.
# `swift run` runs without a bundle, so it lacks that Finder integration,
# and the system save panel (New Project) doesn't take typing there;
# scripts/run.sh builds and opens this bundle instead.
#
# Usage: scripts/build-app.sh [output directory, default: build]
# CONFIGURATION=debug builds faster, for trying a change (scripts/run.sh).
set -eu

cd "$(dirname "$0")/.."
output="${1:-build}"
configuration="${CONFIGURATION:-release}"
app="$output/AnimationMeetsVideo.app"

# Apple silicon only, whatever Mac builds it: the app supports no Intel Mac.
swift build -c "$configuration" --arch arm64 --product AnimationMeetsVideo
bin="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
binary="$bin/AnimationMeetsVideo"
if [ "$(lipo -archs "$binary")" != "arm64" ]; then
    echo "error: $binary isn't built for Apple silicon alone." >&2
    exit 1
fi
# The resource bundle, which holds the effect packages that ship with the
# app and the Python helper's code; EffectPackageStore.builtInFolder and
# PythonRuntime.hostScript look for it in Contents/Resources.
resources="$bin/AnimationMeetsVideo_AnimationMeetsVideo.bundle"

plutil -lint Packaging/Info.plist
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/AnimationMeetsVideo"
cp -R "$resources" "$app/Contents/Resources/"
cp Packaging/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# The Python scripts and expressions run on, in Contents/Resources/Python
# (PythonRuntime.builtInInterpreter). Until a release is pinned in
# fetch-python.sh the app is built without one, and Settings > Scripting
# asks for one of the person's own.
status=0
AMV_APP_BUNDLE="$app" scripts/fetch-python.sh || status=$?
if [ "$status" -eq 3 ]; then
    echo "warning: built without a Python of its own; see scripts/fetch-python.sh." >&2
elif [ "$status" -ne 0 ]; then
    exit "$status"
fi

# Ad-hoc signed, so it runs on the Mac that built it. Sharing it with
# other Macs needs a Developer ID signature and notarization.
codesign --force --sign - "$app"

# Registers the bundle's types now rather than when Finder next notices it.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$lsregister" ]; then
    "$lsregister" -f "$app" || true
fi

echo "Built $app"
