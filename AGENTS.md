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

- SwiftPM macOS app (`Package.swift`), sources in `Sources/AnimationMeetsVideo`.
- Building requires full Xcode (SwiftUI macro plugins are missing from the
  standalone Command Line Tools).
