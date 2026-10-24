# Agent Instructions

Guidance for AI coding agents (Claude Code, Copilot, etc.) working in this repository.

## Git commit messages: Google style

Follow Google's change-description conventions for every commit.

- **Subject line**: a short, imperative summary of what the change does, written
  as a complete sentence fragment. Capitalize the first word, no trailing
  period, aim for 50 characters or fewer (hard limit 72).
  Good: `Fix clip ordering when building the composition`.
  Bad: `fixed stuff`, `Fixes bug.`, `Update EditorView.swift`.
- **No type prefixes**: do not use Conventional Commits tags such as `feat:` or
  `fix:`. A short area prefix is fine when it adds clarity, for example
  `Exporter: Skip empty tracks`.
- **Blank line** after the subject, then a **body** wrapped at 72 columns.
- **Body explains why**, not just what: the problem, the reason for this
  approach, and any trade-offs or limitations. The diff already shows what
  changed. Leave the body out only for truly trivial changes.
- One logical change per commit. Do not mix unrelated fixes.
- Reference bugs or issues in a footer (`Bug: #123`) when applicable.
- Use real newlines in the message (pass it through a HEREDOC); never write a
  literal `\n`.
- Do not skip hooks or amend published commits. Only commit when asked.

## Project notes

- One target, `Sources/AnimationMeetsVideo`, grouped by folder for
  organization only; preference keys live in `App/Preferences.swift`.
  Put new UI code in the folder of the area that uses it, one main view per
  file; keep non-UI logic out of `UI/`.
- Tests in `Tests/AnimationMeetsVideoTests` mirror the source folders, with
  shared fixtures and harnesses in `Support/`.
- To look at a UI change without launching the app, run
  `SNAPSHOT_DIR=<folder> swift test --filter UISnapshots`. It renders
  the views in `Tests/AnimationMeetsVideoTests/UI/UISnapshots.swift` to
  PNGs in that folder, and is skipped when the variable isn't set. Add a
  case there for a view you change that has none.
- New UI follows the rules in `docs/accessibility.md`: drawn or gesture-
  driven views need an accessibility element with actions, icon-only
  buttons need labels, and anything a drag does needs a keyboard path.
- Design docs live in `docs/` (start at `docs/README.md`). Each states whether
  it describes existing or planned behavior; keep them in sync with the code.
- CI (`.github/workflows/build.yml`) builds and tests every push on a
  macOS runner; check it when a change couldn't be built locally.
- `scripts/build-app.sh` wraps the executable into `AnimationMeetsVideo.app`
  with `Packaging/Info.plist`, which declares the `.amv` project type and
  the `.amveffect` effect package type; keep their type identifiers in
  sync with `ProjectStore.packageTypeIdentifier` and
  `EffectPackageStore.packageTypeIdentifier`. It also copies the resource
  bundle, which holds the effect packages that ship with the app.
- Building requires full Xcode (SwiftUI macro plugins are missing from the
  standalone Command Line Tools).
