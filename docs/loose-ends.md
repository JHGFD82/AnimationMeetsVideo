# Loose ends

Status: **temporary**. What is left over from the UX pass of October
2026 (PR #24): checks not yet made and small gaps knowingly left. Tick
items off or move them into the document they belong to; delete this
file when it is empty.

## Before merging

- [ ] **CI can't run.** GitHub doesn't start the macOS job: "recent
  account payments have failed or your spending limit needs to be
  increased" (Settings > Billing & plans). `main` fails the same way.
  Every commit was built and tested locally; run CI once billing is
  fixed.
- [x] **Accessibility review.** The `accessibility-reviewer` agent went
  over the new and changed views against [accessibility.md](accessibility.md),
  "Rules for new UI". Fixed: the media problems bar's button is its own
  element again (its stand-in action ignored the button's dimming), the
  Keyboard Shortcuts window reads keys by name, and the backup folder's
  buttons say what they act on. The rest passed.

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
- [ ] **VoiceOver** over the views reviewed above (the review was made
  from the code): the media problems bar's count and button, a row of
  the Keyboard Shortcuts window, the start sheet's recent projects.
- [ ] **Earlier in the PR**: the title bar's name, proxy icon and edited
  dot; File > Import Media and Export; Open Recent and the start sheet;
  Locate… and Check Sync…; the Export window's finished note with Show
  in Finder.
- [ ] **UX review fixes (November 2026)**, which depend on how AppKit
  and SwiftUI behave at run time:
  - Type in a Text clip's words, click a clip, press Space and Delete:
    the timeline plays and deletes; the letters picked stay picked.
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
    undoes the retiming first. In a Timeline window, move, trim, delete,
    split or add an effect to a designed clip, paste over it, and ⌘Z:
    each beeps and changes nothing; other clips edit as usual. Right-click an unselected point: the menu
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

## Known gaps

- **Left from the UX review.** The Timeline menu's Delete Selection,
  Nudge and Turn Clip Off or On stay enabled with nothing selected (they
  do nothing then). Return adds a clip to the timeline in the Clips tab
  but renames in the Timelines tab, as documented in
  [browser.md](browser.md); one meaning for both is a design decision.
  While the Motion Designer is open its clips are locked
  ([motion-designer.md](motion-designer.md)): edits from elsewhere that
  would change them are refused with a beep, but nothing marks the
  clips as locked in a Timeline window or the inspector beforehand, a
  song moved elsewhere leaves a locked clip attached to it behind, a
  redo refused meanwhile is lost, and an undo refused clears the redo
  stack.

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
