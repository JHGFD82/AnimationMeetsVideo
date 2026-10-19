---
name: snapshot
description: Render AnimationMeetsVideo's SwiftUI views to PNGs with the UISnapshots tests and look at them. Use after changing a view under Sources/AnimationMeetsVideo/UI to check it by eye, since the running app can't be screenshotted from a session. Adds a snapshot case when the changed view has none.
argument-hint: "[test name, e.g. editor]"
---

# Snapshot the UI

The app's window can't be captured from a Claude session (no Screen
Recording permission), so the way to see a view is the `UISnapshots`
suite in `Tests/AnimationMeetsVideoTests/UI/UISnapshots.swift`. It runs
only when `SNAPSHOT_DIR` is set, and writes `<name>.png` files there via
`SnapshotSupport.render`.

## Steps

1. **Find the case.** Read `UISnapshots.swift` and find the test that
   shows the view that changed. If `$ARGUMENTS` names a test, use that.
   If no test shows the view, add one first (step 4).
2. **Render** into a fresh folder in the scratchpad directory (never the
   repo or the user's folders):

   ```bash
   SNAPSHOT_DIR=<scratchpad>/snaps swift test --filter 'UISnapshots/<testName>'
   ```

   Leave out `/<testName>` to render every case. A build started while
   the debug app or lldb is running hangs; quit those first.
3. **Look** at each PNG it wrote with the Read tool, and describe what
   you see against what the change was meant to do: layout, clipping,
   text that doesn't fit, contrast against `Design` tones.
4. **Add a case** when the view has none: a `@Test func` in
   `UISnapshots`, built the way the neighbouring tests are (an
   `EditingProject.empty` set up with what the view needs,
   `SnapshotSupport.clickSong(named:)` for audio, then
   `SnapshotSupport.render(view, "name", size:)`). Give it a doc comment
   saying what the picture shows. Render it once to check it works.

## Known differences from the real window

Offscreen, the window is never key, so prominent buttons draw unfilled,
and a Settings scene's toolbar tabs draw as a blank placeholder. Don't
report those as bugs. Views render in the editor's dark appearance.

Snapshots show layout, not behaviour: playback and drags still need the
user to check them in the app.
