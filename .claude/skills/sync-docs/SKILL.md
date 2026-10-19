---
name: sync-docs
description: Check AnimationMeetsVideo's design docs in docs/ against the code changed since a given commit, and fix the docs where they no longer describe it.
argument-hint: "[base commit or range, default: last 20 commits]"
disable-model-invocation: true
---

# Sync the design docs

`AGENTS.md` asks that the design docs in `docs/` stay in sync with the
code. Each doc opens with a `Status:` line (implemented, built, being
built, planned, replaced) and most end with a "Building it" or "Not
implemented yet" list. This skill finds where those have drifted.

## Steps

1. **Pick the range.** Use `$ARGUMENTS` as the base (`<base>..HEAD`) if
   given, otherwise `HEAD~20..HEAD`. Run
   `git log --oneline <range>` and `git diff --stat <range> -- Sources`.
2. **Map changes to docs.** `docs/README.md` has a table of what each doc
   covers. For each source folder that changed, pick the docs that cover
   it (for example `Rendering/` → `rendering.md`, `UI/Timeline/` →
   `timeline.md`, `Model/Effects/` → `effects.md`, anything under `UI/`
   → also `accessibility.md`'s key table and "Not implemented yet").
3. **Compare.** For each of those docs, read it and the changed code, and
   look for:
   - a feature listed as planned, remaining or "not implemented yet"
     that the commits built;
   - type, function or file names the doc mentions that were renamed or
     removed (grep for each);
   - behaviour the doc states (keys, defaults, limits, counts such as
     "25 kinds") that the code now does differently;
   - a `Status:` line, or the summary in `docs/README.md`, that is now
     out of date.
4. **Report** a short list per doc: what's out of date, the line, and the
   commit or code that changed it. Then ask before editing.
5. **Edit** the docs the user agrees to, in the docs' own plain style.
   Commit the doc changes on their own (Google-style message per
   `AGENTS.md`, area prefix `Docs:`), one commit per doc or per topic.

Only describe what the code does; don't change code to match a doc.
