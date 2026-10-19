#!/bin/bash
# PreToolUse hook for Bash: before a `git commit`, build (and test) the
# checkout the commit runs in. Exit 2 blocks the commit and hands the
# errors to Claude. Commits that touch no Swift skip the build.

input=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")

# Only commands that run `git commit` (also inside `git add … && git commit`).
grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)' <<<"$command" || exit 0

root=$(git -C "${cwd:-$CLAUDE_PROJECT_DIR}" rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
[ -f Package.swift ] || exit 0

# Nothing Swift changed (docs, scripts, plist): no build needed.
git status --porcelain | grep -Eq '\.swift"?$' || exit 0

# A build started while the app or lldb runs hangs with no output.
if pgrep -f '\.build/.*/AnimationMeetsVideo( |$)' >/dev/null || pgrep -x lldb >/dev/null; then
    echo "Not committing yet: the debug app or lldb is still running, and swift build hangs while it does. Quit it (or kill the one this session launched), then commit again." >&2
    exit 2
fi

plain() { sed $'s/\x1b\\[[0-9;]*m//g'; }

if ! out=$(swift build 2>&1 | plain; exit "${PIPESTATUS[0]}"); then
    errors=$(grep -E 'error:' <<<"$out" | head -20)
    { echo "swift build failed, so the commit was blocked:"; echo "${errors:-$(tail -30 <<<"$out")}"; } >&2
    exit 2
fi

if [ "${AMV_COMMIT_SKIP_TESTS:-0}" != 1 ]; then
    if ! out=$(swift test 2>&1 | plain; exit "${PIPESTATUS[0]}"); then
        failures=$(grep -E '✘|error:|failed' <<<"$out" | head -30)
        { echo "swift test failed, so the commit was blocked:"; echo "${failures:-$(tail -30 <<<"$out")}"; } >&2
        exit 2
    fi
fi
exit 0
