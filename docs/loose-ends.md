# Loose ends

Status: **temporary**. Known gaps left from the UX pass of October
2026 (PR #24, merged as c17953e) and since. The in-app checklist was
completed in November 2026. Resolve these notes or move them into the
documents they belong to; delete this file when it is empty.

## Known gaps

- **Sound renders that come out wrong only on CI.** Three tests that
  read the mix offline failed once each on a loaded runner, while the
  same commits passed elsewhere: `ScrubAudioTests`
  (`aGrainIsTheMixUnderThePlayheadFadedAtItsEnds`, the middle of a grain
  read as silence or doubled), `DetachAudioTests`
  (`aNestedTimelinesSoundDetaches`, levels before and after differed)
  and `LoudnessMasteringTests` (`aQuietMixIsRaisedToTheTarget`, a 3 s
  render came out 3.072 s and 0.3 dB off). A voice isolation render was
  once 2.048 s for 2 s, too. Both lengths are whole slices of 4096
  frames, so the reader seems to hand over extra or silent slices under
  load; all of these read through `AVAssetReaderAudioMixOutput` and the
  taps of `AudioLevelTap`. The load is the suite itself: uncapped,
  Swift Testing starts nearly every test at once, and on the runner's
  few cores almost all of them took over 100 s, with beat and scene
  analysis (utility priority) stuck at 0% past their two-minute waits.
  Run locally under `taskpolicy -b` with every core busy, the whole
  suite failed the same way (147 issues); capped at eight tests at a
  time it passed, no slower. CI now runs with that cap
  (`--experimental-maximum-parallelization-width 8` in
  `.github/workflows/build.yml`). Still open: whether an export on a
  Mac that busy can get gaps too. If so, the fix is to mix offline
  reads without taps (track readers through each track's effects and
  curves).

- **The export queue lives in UI/.** `ExportWindow`
  (`UI/Export/ExportWindow.swift`) holds the queue's logic (starting,
  queuing, stopping, the destinations in use) beside the window it
  shows. AGENTS.md would put that logic in a non-UI type such as
  `Export/ExportQueue.swift`, with the window reading it; left until
  the queue next changes, since it moves every reference to it.
- **Exports in use are told apart by their exact place.**
  `ExportDestinations.conflict` refuses a destination only when it is
  the same path as one under way or waiting. A WAV Stems export's
  destination is its folder, so a WAV Mix saved inside that folder
  under the name of one of its stems ("Name - Layer.wav") is still
  written over. Paths are compared without case, so on a case-sensitive
  volume "a.mov" is refused while "A.mov" is in use; chosen when the
  check was added, since the Mac's volumes ignore case by default.

- **Speed: the Timeline menu follows playback.** To keep every item's
  on or off state exact, `TimelineMenuStatePublisher` checks the playing
  time once a frame while a timeline plays (the menu bar is rebuilt
  only when an item turns on or off). Not yet measured. If playback,
  scrubbing or the menu bar is reported slow, suspect this first: lower
  its `playingChecksPerSecond`, or check only while a menu is open.

- **Left from the UX review.** While the Motion Designer is open its
  clips are locked ([motion-designer.md](motion-designer.md)): edits from
  elsewhere that would change them are shown locked and not offered, and
  refused with a beep if they come anyway. Still only refused, not
  greyed: the timeline's keys (B, Delete, the nudge keys), the keyframe
  lanes on the timeline, the browser's commands, and a drop on empty
  track that would push a locked clip. A song moved elsewhere leaves a
  locked clip attached to it behind, a redo refused meanwhile is lost,
  and an undo refused clears the redo stack.

- **Pasted media is analyzed again.** Scene detection runs anew in the
  project it is pasted into instead of taking the results the other
  window already has in memory. Its saved reference data does come along
  at the next save. Taking them would mean seeding `AssetAnalysis` with
  each result's source file, unsaved state and held pictures, which its
  race tests guard closely; left until it is worth that care.
- **Reference data of media referenced in place** comes along with a
  paste only while the project it came from is open in a window: the
  app finds that project through its window. Media inside the other
  project's package is found by its path and doesn't need that.
- **Closing the last window quits the app.** Kept on purpose; with
  recent projects and reopening at launch, getting back is quick.
