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
  up, and while every window has a project.
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
  Locate… and Check Sync…; Export Finished with Show in Finder.

## Known gaps

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
