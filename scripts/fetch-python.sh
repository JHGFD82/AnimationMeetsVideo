#!/bin/sh
# Puts the Python that scripts and expressions run on into the app bundle
# (docs/python-scripting.md, "Which Python"): a relocatable CPython from
# python-build-standalone, pinned below by release, version and SHA-256,
# so everyone on one version of the app has one Python and an expression
# gives the same keyframes on every Mac.
#
# The archive is kept in build/python/ between builds and checked against
# its SHA-256 every time. It is trimmed of what the helper can't use
# (IDLE, Tk, ensurepip and the test suite), copied to the destination and
# each binary in it signed, before build-app.sh signs the app around it.
#
# Usage: scripts/fetch-python.sh <destination, such as App.app/Contents/Resources/Python>
# Exit status 3: nothing is pinned yet, and nothing was copied.
set -eu

cd "$(dirname "$0")/.."
destination="${1:?Usage: scripts/fetch-python.sh <destination folder>}"

# The pinned archive. To move to a new Python, take the
# aarch64-apple-darwin-install_only_stripped archive of a release at
# https://github.com/astral-sh/python-build-standalone/releases, and its
# SHA-256 from that release's SHA256SUMS. Overriding these from the
# environment is for trying a release, never for shipping one.
release="${PYTHON_RELEASE:-}"   # The release tag, such as 20251014.
version="${PYTHON_VERSION:-}"   # The CPython version, such as 3.14.0.
sha256="${PYTHON_SHA256:-}"     # The archive's SHA-256, in hex.

if [ -z "$release" ] || [ -z "$version" ] || [ -z "$sha256" ]; then
    echo "fetch-python.sh: no Python release is pinned yet; set release, version and sha256 in scripts/fetch-python.sh." >&2
    exit 3
fi

name="cpython-$version+$release-aarch64-apple-darwin-install_only_stripped.tar.gz"
cache="build/python"
archive="$cache/$name"
mkdir -p "$cache"
if [ ! -f "$archive" ]; then
    curl --fail --location --silent --show-error --output "$archive.partial" \
        "https://github.com/astral-sh/python-build-standalone/releases/download/$release/$(printf '%s' "$name" | sed 's/+/%2B/')"
    mv "$archive.partial" "$archive"
fi

found="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$found" != "$sha256" ]; then
    echo "fetch-python.sh: $name has SHA-256 $found, not the $sha256 pinned. It was removed; nothing was copied." >&2
    rm -f "$archive"
    exit 1
fi

unpacked="$(mktemp -d)"
trap 'rm -rf "$unpacked"' EXIT
tar -xzf "$archive" -C "$unpacked"
python="$unpacked/python"
minor="$(printf '%s' "$version" | cut -d . -f 1-2)"
stdlib="$python/lib/python$minor"
rm -rf "$stdlib/idlelib" "$stdlib/tkinter" "$stdlib/turtledemo" "$stdlib/ensurepip" "$stdlib/test"
rm -f "$stdlib"/lib-dynload/_tkinter*.so
rm -rf "$python"/lib/libtcl* "$python"/lib/libtk* "$python"/lib/tcl* "$python"/lib/tk* "$python/lib/itcl"* "$python/lib/thread"*
rm -rf "$python/share" "$python/include"
find "$python" -name '__pycache__' -type d -prune -exec rm -rf {} +

rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
cp -R "$python" "$destination"

# Each binary inside is signed before the app is, as nested code must be.
find "$destination" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) | while read -r file; do
    if file "$file" | grep -q 'Mach-O'; then
        codesign --force --sign - "$file"
    fi
done

echo "Bundled Python $version ($release)"
