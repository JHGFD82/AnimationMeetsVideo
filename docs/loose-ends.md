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
- [ ] **Accessibility review.** Run the `accessibility-reviewer` agent
  over the new and changed views (see [accessibility.md](accessibility.md),
  "Rules for new UI"): the empty Clips list, the media problems bar, the
  Timelines tree, the start sheet's recent projects, Settings > Projects,
  the Keyboard Shortcuts window and the toolbar warnings.

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
  original's folder away first and check it asks where to restore.
- [ ] **Earlier in the PR**: the title bar's name, proxy icon and edited
  dot; File > Import Media and Export; Open Recent and the start sheet;
  Locate… and Check Sync…; Export Finished with Show in Finder.

## Known gaps

- **Pasted media is analyzed again.** Scene detection runs anew in the
  project it is pasted into instead of taking the results the other
  window already has in memory. Its saved reference data does come along
  at the next save.
- **Reference data of media referenced in place** comes along with a
  paste only while the project it came from is open in a window: the
  app finds that project through its window. Media inside the other
  project's package is found by its path and doesn't need that.
- **No list of backups in the app.** A backup is opened from Finder or
  File > Open; Settings > Projects can show the folder. A window
  listing a project's backups with their dates, to open one, would save
  the trip.
- **A restored project keeps the original's project ID.** It has its own
  package and opens and saves on its own, but nothing tells the two apart
  by ID if both are open; nothing relies on that yet.
- **Closing the last window quits the app.** Kept on purpose; with
  recent projects and reopening at launch, getting back is quick.
