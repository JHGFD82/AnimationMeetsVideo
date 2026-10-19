#!/bin/bash
# PostToolUse hook for Edit/Write: after Packaging/Info.plist or
# ProjectStore.swift changes, check that the .amv type identifier still
# matches in both. Exit 2 shows the mismatch to Claude.

file=$(jq -r '.tool_input.file_path // ""')
case "$file" in
    */Packaging/Info.plist|*/Project/ProjectStore.swift) ;;
    *) exit 0 ;;
esac

root=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null) || exit 0
plist="$root/Packaging/Info.plist"
store="$root/Sources/AnimationMeetsVideo/Project/ProjectStore.swift"
[ -f "$plist" ] && [ -f "$store" ] || exit 0

in_plist=$(grep -A1 '<key>UTTypeIdentifier</key>' "$plist" | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | head -1)
in_store=$(sed -n 's/.*static let packageTypeIdentifier = "\(.*\)".*/\1/p' "$store" | head -1)

if [ "$in_plist" != "$in_store" ]; then
    echo "The .amv type identifier no longer matches: Info.plist UTTypeIdentifier is \"$in_plist\" but ProjectStore.packageTypeIdentifier is \"$in_store\". Keep them the same (see AGENTS.md)." >&2
    exit 2
fi
exit 0
