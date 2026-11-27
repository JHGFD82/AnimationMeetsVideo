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
# The app always bundles the Python scripts/python-pin names, with its
# license, and the build fails without it; ALLOW_NO_PYTHON=1 builds one
# without, for development only (code-review-notes.md, decision D3).
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
# (PythonRuntime.builtInInterpreter), from the committed pin. A build that
# came out without it once only warned, and a clean checkout made an app
# with no scripting support at all.
status=0
AMV_APP_BUNDLE="$app" scripts/fetch-python.sh || status=$?
python="$app/Contents/Resources/Python"
minor="$(sed -n 's/^version=\([0-9]*\.[0-9]*\).*/\1/p' scripts/python-pin 2>/dev/null | head -n 1)"
if [ "$status" -eq 0 ] && [ -x "$python/bin/python3" ] && [ -f "$python/lib/python$minor/LICENSE.txt" ]; then
    :
elif [ "${ALLOW_NO_PYTHON:-}" = 1 ]; then
    echo "warning: built without a Python of its own (ALLOW_NO_PYTHON=1), for development only." >&2
else
    echo "error: the app has no bundled Python with its license (fetch-python.sh exit status $status)." >&2
    echo "  Check scripts/python-pin, or set ALLOW_NO_PYTHON=1 for a development build without one." >&2
    exit 1
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
