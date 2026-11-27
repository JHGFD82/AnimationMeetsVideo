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
# Usage:
#   scripts/fetch-python.sh --pin [release]
#       Looks up a release (the latest, or one such as 20251014), takes its
#       newest CPython 3.14 (PYTHON_MINOR to choose another) and the
#       archive's SHA-256 from the release's own checksums, and writes the
#       three to scripts/python-pin. The pin is committed: change it in a
#       commit of its own, after the helper's tests pass on the new Python
#       (AMV_PYTHON=build/AnimationMeetsVideo.app/Contents/Resources/Python/bin/python3
#       swift test --filter "PythonHelper|Confinement", and its Python tests)
#       and its license notice is checked to be in the bundle.
#   scripts/fetch-python.sh
#       Bundles the pinned Python into the app, always at
#       Contents/Resources/Python: build/AnimationMeetsVideo.app, which
#       build-app.sh makes (and runs this for), and signs the app again.
#       Before the app is built, it only fetches and checks the archive.
#       A Python already on the Mac can't be bundled (it isn't
#       relocatable); choose it in the app's Settings > Scripting instead.
# Exit status 3: nothing is pinned yet, and nothing was copied.
set -eu

cd "$(dirname "$0")/.."

# The pinned archive, kept in scripts/python-pin, which --pin writes and
# is committed, so every checkout bundles the same Python. Setting these in
# the environment overrides the file, for trying a release.
pin_file="scripts/python-pin"
pinned_value() {
    if [ -f "$pin_file" ]; then sed -n "s/^$1=\\([^[:space:]]*\\)$/\\1/p" "$pin_file" | head -n 1; fi
}
release="${PYTHON_RELEASE:-$(pinned_value release)}"   # The release tag, such as 20251014.
version="${PYTHON_VERSION:-$(pinned_value version)}"   # The CPython version, such as 3.14.0.
sha256="${PYTHON_SHA256:-$(pinned_value sha256)}"      # The archive's SHA-256, in hex.

releases="${PYTHON_RELEASES_API:-https://api.github.com/repos/astral-sh/python-build-standalone/releases}"
suffix="aarch64-apple-darwin-install_only_stripped.tar.gz"

pin() {
    wanted="${1:-latest}"
    minor="${PYTHON_MINOR:-3.14}"
    if [ "$wanted" = latest ]; then url="$releases/latest"; else url="$releases/tags/$wanted"; fi
    json="$(curl --fail --location --silent --show-error "$url")" || {
        echo "fetch-python.sh: couldn't fetch the release from $url." >&2
        exit 1
    }
    tag="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ -n "$tag" ] || { echo "fetch-python.sh: couldn't read a release from $url." >&2; exit 1; }
    # The newest CPython of that minor version in the release.
    found_version="$(printf '%s' "$json" \
        | grep -o "\"name\": *\"cpython-$minor\.[0-9]*+$tag-$suffix\"" \
        | sed "s/.*cpython-\\([0-9.]*\\)+.*/\\1/" \
        | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)"
    [ -n "$found_version" ] || {
        echo "fetch-python.sh: release $tag has no CPython $minor for Apple silicon ($suffix)." >&2
        exit 1
    }
    name="cpython-$found_version+$tag-$suffix"
    # The release's checksums: SHA256SUMS, or in older releases a .sha256
    # beside each archive.
    sums_url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*/SHA256SUMS"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -n "$sums_url" ]; then
        found_sha="$(curl --fail --location --silent --show-error "$sums_url" | awk -v n="$name" '$2 == n { print $1 }')"
    else
        own_url="$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*-$suffix.sha256\"" \
            | grep "cpython-$found_version" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
        found_sha="$( [ -n "$own_url" ] && curl --fail --location --silent --show-error "$own_url" | cut -c 1-64)"
    fi
    if ! printf '%s' "$found_sha" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "fetch-python.sh: release $tag gives no SHA-256 for $name." >&2
        exit 1
    fi
    printf '# The Python scripts/fetch-python.sh bundles, written by --pin.\nrelease=%s\nversion=%s\nsha256=%s\n' \
        "$tag" "$found_version" "$found_sha" > "$pin_file"
    echo "Pinned CPython $found_version, release $tag, SHA-256 $found_sha."
    echo "Written to $pin_file. Commit it once the helper's tests pass on it."
}

if [ "${1:-}" = "--pin" ]; then
    pin "${2:-latest}"
    exit 0
fi

if [ $# -gt 0 ]; then
    echo "fetch-python.sh: it takes no folder: the Python always goes into the app. Run it with no arguments, or with --pin." >&2
    exit 2
fi
# The app, as build-app.sh makes it; build-app.sh names it when it builds
# into another folder.
app="${AMV_APP_BUNDLE:-build/AnimationMeetsVideo.app}"
destination="$app/Contents/Resources/Python"

if [ -z "$release" ] || [ -z "$version" ] || [ -z "$sha256" ]; then
    echo "fetch-python.sh: no Python release is pinned yet. Run scripts/fetch-python.sh --pin to pin the latest." >&2
    exit 3
fi

name="cpython-$version+$release-$suffix"
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
# The Python goes out with its license (lib/pythonX.Y/LICENSE.txt), or not
# at all. The archive doesn't carry the notices of the libraries built
# into it (OpenSSL, SQLite and the rest); see code-review-notes.md, F61.
if [ ! -f "$stdlib/LICENSE.txt" ]; then
    echo "fetch-python.sh: $name has no lib/python$minor/LICENSE.txt; a bundled Python must carry its license." >&2
    exit 1
fi
rm -rf "$stdlib/idlelib" "$stdlib/tkinter" "$stdlib/turtledemo" "$stdlib/ensurepip" "$stdlib/test"
rm -f "$stdlib"/lib-dynload/_tkinter*.so
rm -rf "$python"/lib/libtcl* "$python"/lib/libtk* "$python"/lib/tcl* "$python"/lib/tk* "$python/lib/itcl"* "$python/lib/thread"*
rm -rf "$python/share" "$python/include"
find "$python" -name '__pycache__' -type d -prune -exec rm -rf {} +

if [ ! -d "$app/Contents" ]; then
    echo "Fetched and checked Python $version ($release). scripts/build-app.sh puts it into the app."
    exit 0
fi
rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
cp -R "$python" "$destination"

# Each binary inside is signed before the app is, as nested code must be.
find "$destination" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) | while read -r file; do
    if file "$file" | grep -q 'Mach-O'; then
        codesign --force --sign - "$file"
    fi
done

# The app's signature covers its resources, so it is signed again around
# the Python just put in (build-app.sh signs it once more, which is fine).
codesign --force --sign - "$app"

echo "Bundled Python $version ($release) into $app"
