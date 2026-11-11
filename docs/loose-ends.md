# Loose ends

Status: **temporary**. What is left over from the UX pass of October
2026 (PR #24, merged as c17953e) and since: things to try in the app and
small gaps knowingly left. Tick items off or move them into the document
they belong to; delete this file when it is empty.

## To try in the app

Built and tested in code, never run on screen.

- [ ] **Several windows**: open two projects; open one already open
  (its window comes forward); close a window with unsaved changes
  (saving after every change off); quit with several open and relaunch
  (all reopen); double-click a project in Finder while a start sheet is
  up, and while every window has a project; Open Recent on a damaged
  project while another is open (its new window closes after the
  alert).
- [ ] **Saving after every change**: edit, nudge, drag a value; check
  `project.json` is written once a drag ends and not during it; undo and
  redo; make a save fail (a read-only volume) and see **Not saved**.
- [ ] **Undo names**: several quick edits of different kinds undone one
  at a time; names of clips of a video whose scenes are found ("Scene 23
  of …") and of one still being analyzed.
- [ ] **Pasting between projects**: a clip of footage copied into the
  other project's package, a nested timeline, clips copied together;
  after the next save, the media is in the target's `Media/` and its
  `Reference/` folder came along.
- [ ] **Backups**: set the interval to 5 minutes, let one be written,
  check its contents and the clone (no extra space on the same volume);
  double-click it (after `scripts/build-app.sh`, so Finder knows
  `.amvbackup`) and check the new project beside the original; move the
  original's folder away first and check it asks where to restore;
  File > Open Backup… starts in the project's backups and opens one the
  same way.
- [ ] **VoiceOver** over the views the accessibility review of the PR
  went over (it was made from the code, against
  [accessibility.md](accessibility.md)): the media problems bar's count
  and button, a row of the Keyboard Shortcuts window, the start sheet's
  recent projects.
- [ ] **Earlier in the PR**: the title bar's name, proxy icon and edited
  dot; File > Import Media and Export; Open Recent and the start sheet;
  Locate… and Check Sync…; the Export window's finished note with Show
  in Finder.
- [ ] **UX review fixes (November 2026)**, which depend on how AppKit
  and SwiftUI behave at run time:
  - Type in a Text clip's words, click a clip, press Space and Delete:
    the timeline plays and deletes; the letters picked stay picked. The
    click that ends typing still does what it was aimed at (selects the
    clip, presses the button): the event tests can't check this, since
    their clicks reach no plain SwiftUI view.
  - Curves and EQ: Delete removes the picked point, arrows move it, Tab
    leaves the graph; then click a clip and Delete deletes the clip.
  - Escape mid-drag on an EQ dot, a Curves point, a range handle, a
    lasso, a section, a keyframe and a layer header (one auto-scrolling
    its area): each goes back and the selection stays.
  - Press Delete while holding a value drag: the pointer comes back.
  - Scroll the effects panel past an EQ with a trackpad and a mouse
    wheel: no Q change.
  - ⌘Z after moving a keyframe in a graph panel, and in the external
    display in both modes.
  - Hold → in the Tape Scrubber, click the main window: the tape stops.
  - Trim a clip's end until auto-scroll takes its start out of view:
    the trim commits.
  - Motion Designer, open: edit in a Timeline window and import a file,
    then retime; both edits stay after Done and after Cancel, and ⌘Z
    undoes the retiming first. In a Timeline window, a designed clip is
    hatched with a lock chip and won't drag, trim, take a drop or show
    a blade line; its menu has only Copy and Show in Clips Browser; the
    Timeline menu's Split (playhead in it), Nudge, Delete Selection and
    Turn Off, and the Edit menu's Cut, Duplicate, Delete and Paste over
    it, are greyed; the inspector and effects panel show it disabled
    under "Open in the Motion Designer"; B, Delete and ⌘Z on it beep and
    change nothing; other clips edit as usual. Right-click an unselected point: the menu
    acts on it. Clips in the footage strip are grabbed where drawn.
  - Start a drag in Beat Match or the designer, open a sheet (⌘. or H's
    conflict dialog), release, Keep Editing, click: nothing carries on.
  - Quit with each draft panel changed: each asks first.
  - Open Recent on a damaged project with another open: the new window
    closes after the alert.
  - Skimming off, click a clip frame, click the timeline, Space: the
    timeline plays with no browser frame over the viewer.
  - Replace Media… and ⌘J from a Timeline window open there; Skip in a
    batch replacement carries on.
  - Rename a clip in the browser and press Backspace and Return inside
    the field; ⌘D in a name field beeps.
  - At launch with the start sheet up, ⌘I and ⌘E are disabled.
- [ ] **Keyframe Designer ease fields**: in Handles…, Tab between the
  reach sliders and speed fields; enter arithmetic such as `100+150`,
  commit with Return and by clicking away, and cancel with Escape.
  Check VoiceOver reads the side, reach and speed and can change each.
  The snapshots cover the controls; native field editing needs a running
  app because AppKit can end the event-test process while tracking it.
- [ ] **Export queue fixes (November 2026)**, each with a long export
  running and another queued behind it:
  - Both finish: the window comes back once with both lines and the
    Dock bounces once. Cancel in the save panel adds nothing.
  - Export… suggests "<Project> Main", then "<Project> Main 2" while
    the first waits; typing a taken name, or picking the running file
    and agreeing to replace it, gets "Couldn't Export" and queues
    nothing. Every file shown as saved exists in Finder.
  - Change a control of an effect package a queued timeline uses from a
    number to a vector: the queued export starts and finishes. Replace
    Media on a Matte Wipe's map video: the viewer shows the new map, the
    running export the old one throughout.
  - Leave the save panel, or the Stop Export… question, up until the
    first ends: its line stays, and a late Stop Export leaves the next
    one exporting.
  - Stop Export… names the next file and offers Stop All; Stop Export
    starts the next, Stop All empties the window and toolbar, and a
    stopped export leaves a Stopped line without bouncing the Dock.
    A stopped WAV Stems export leaves no folder.
  - Close or quit with one running: Stop Export then Keep Editing or
    Cancel leaves the export and queue going; Don't Save or Save goes
    ahead and leaves no partial file; one window with nothing unsaved
    quits after one alert.

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
