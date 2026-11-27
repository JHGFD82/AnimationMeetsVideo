# Code review notes

Status: **review notes** for the first pass of
[code-review-plan.md](code-review-plan.md). Phases 1 to 3 have been
reviewed (phase 1 only in part), phase 4 is being reviewed, and the
plan's stabilization checkpoint is done but for F4's hang, which hasn't
recurred to be captured; phases 5 to 12 haven't started. Many findings
are still open: being reviewed is not being resolved. Where each phase
stands is under "Where each phase stands"; every finding is in the
ledger.

## Reading this ledger

The fields follow the plan's "Recording findings":

- **Confidence**: *suspected* (a lead), *reported* (one reviewer read
  the code path and nobody has re-checked it), *code-verified* (read
  again and confirmed before acting), *reproduced* (a test, probe or run
  showed it).
- **Resolution**: *open*, *fixed*, *accepted risk* (with the reason and
  who accepted it), or *decision* (waiting on the owner).
- **Fix · verification**: the fix commit, and its test: *fails without*
  (the test was run against the code without the fix and failed),
  *test* (a regression test, not run against the unfixed code), or *no
  test*. Every commit on this branch passed the full suite
  (`swift test`, gated suites excluded) in the project's pre-commit
  hook at that commit; gated suites (`UI_EVENTS`, `AMV_PYTHON`) are
  noted where they were run.
- **Gate**: *blocking* or *nonblocking* for a release, as proposed by
  this review; the owner decides.
- Severity is the plan's triage rank by impact (1 data safety and
  security, 2 crash or hang, 3 correctness, 4 performance, 5 usability,
  6 cosmetic), kept apart from the category.

The evidence is this pass's: the runs, probes and tests were made on the
branch `worktree-code-review-phase1`, on the Mac described under
"Phase 1 baseline", and the reviews' readings were by this pass's
reviewers. Nothing here has been checked by anyone outside it.

## Where each phase stands

| Phase | Coverage | What keeps it from complete | Open findings |
| --- | --- | --- | --- |
| 1. Scope and build baseline | Partial | The performance baseline is of the benchmarks' own timelines; the generated dense edit (checkpoint D) is yet to be benchmarked; the whole suite under `UI_EVENTS` has hung once (F4) | F4, F5, F7, F24 |
| 2. Architecture and maintainability | Complete | | F30–F47; its severity-1 findings are fixed |
| 3. Security, privacy and dependencies | Complete | | F53–F55, F59–F62 |
| Stabilization checkpoint | Done but for F4 | F4 not reproduced in two runs since, to be captured by `run-tests.sh` when it recurs | F4 |
| 4. Project model and persistence | Partial | Three reviews made and recorded; its severity-1 findings fixed but F72's stems prompt | F67, F69, F70, F72, F73, F75–F80, F82–F88 |
| 5 to 12 | Not started | May start: checkpoint A to C are closed but for F4 | |

## Stabilization checkpoint

From the plan's checkpoint, with the findings each part covers.

- **A. Data-loss paths. Done.** Fixed: F25 (Beat Match Confirm), F26
  (viewer handle drag), F27 (no lock without `flock`), F28 (provenance),
  F29 (backups across a clock change), F51 (names made into paths), F52
  (clips dropped at load), F71 (failed import), F74 (folder marked
  before load), F79 (package replaced), F81 (undo past arrived
  analysis, reproduced first); F72 (export over a source) fixed but for
  asking before stems replace same-named files.
- **B. Untrusted input. Done.** Fixed: F48 and F49 (numbers, text
  runs), F50 (timeline cycles), F56 (non-finite samples), F57 (helper
  budgets: payloads at most 1 GiB, 10,000 unread frames, no per-frame
  copies), F58 (script rational times). Defensive checks stay at the
  operations too (F16, F17, F23).
- **C. Trust in the test harness. Done but for F4.**
  `scripts/run-tests.sh` (`c55c39b0`, `9bd1b800`, `4bc6cf20`) passes a
  run only on Swift Testing's summary, with `MIN_TESTS` and
  `REQUIRED_SUITES`, samples and stops only its own processes when no
  test finishes for `STALL_SECONDS`, and keeps logs; CI runs it. Tried:
  a run below `MIN_TESTS`, one whose required suite was skipped, and a
  stand-in hang beside a decoy test process (only the run's own was
  sampled and stopped). F4 didn't recur in two whole-suite `UI_EVENTS`
  runs through it at `ccdb6ea7`; it stays open until captured.
- **D. Representative fixtures. Done** (`683801be`). `ReviewFixtures`
  makes numbered long-GOP movies at five rates and a variable one, held
  drawings, flashes, fades, a gradient and outlines, click tracks on
  exact samples, and a 320-cut dense edit; `REVIEW_FIXTURES=<folder>`
  writes the set (38 MB). Real footage stays for a later qualitative
  check (D7).

## Findings ledger

| ID | Finding | Ph | Category | Sev | Confidence | Resolution | Fix · verification | Gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | Loop region's end edge couldn't be taken | 1 | usability | 5 | reproduced | fixed | `4d9e6481` · fails without | nonblocking |
| F2 | Event runs ended early and reported success | 1 | test harness | 2 | reproduced | fixed | `85a49bec` · fails without (lldb trace) | blocking |
| F3 | Convert to Path's refusal said "nil" | 1 | usability | 5 | code-verified | fixed | `98a9a862` · no test | nonblocking |
| F4 | Whole suite under `UI_EVENTS` can hang | 1 | test harness | 2 | reproduced | open | | blocking |
| F5 | Tests that fail when the Mac is busy | 1 | test harness | 5 | reproduced | open (part fixed) | `c23427a8` for `ScrubCacheTests` · reproduced at load 14 | nonblocking |
| F6 | Binaries recorded SDK 15.0 | 1 | packaging | 5 | reproduced | fixed | `193d3e4c` (minimum 26.0) · `otool` | nonblocking |
| F7 | A clean checkout builds with no Python | 1 | packaging | 3 | reproduced | decision (D3) | | blocking |
| F8 | A failed export lost the file it replaced | 2 | data safety | 1 | code-verified | fixed | `35d82288` · test | blocking |
| F9 | A take that couldn't be copied in was deleted | 2 | data safety | 1 | code-verified | fixed | `f2de65a3` · test | blocking |
| F10 | Outside edit marked seen under Motion Designer locks | 2 | data safety | 1 | code-verified | fixed | `d95d143a` · test | blocking |
| F11 | Stale background renders of effect inputs | 2 | export | 3 | reproduced | fixed | `7452ceb5` · fails without | blocking |
| F12 | Waveform and Audio Keys heard silenced clips | 2 | sound | 3 | code-verified | fixed | `b023f30b` · test | nonblocking |
| F13 | Beat match played a different sound track | 2 | timing | 3 | code-verified | fixed | `b8aa816e` · no test | nonblocking |
| F14 | Status lines behind the code | 2 | docs | 6 | code-verified | fixed | `14b20a60` | nonblocking |
| F15 | Logged names read as format strings | 3 | crash | 2 | reproduced | fixed | `e1d78893` · probe, no test | blocking |
| F16 | Matroska files that crash, hang or overrun | 3 | security | 2 | code-verified | fixed | `1fd07353` · tests and sweep | blocking |
| F17 | `audio.bin` start overflowed | 3 | crash | 2 | code-verified | fixed | `ca0cd751` · test | blocking |
| F18 | Edited viewer-copy index deleted any folder | 3 | data safety | 1 | reproduced | fixed | `221d4457` · fails without | blocking |
| F19 | Linked cache folder emptied | 3 | data safety | 1 | code-verified | fixed | `2305c751` · test | blocking |
| F20 | Allowed script imported code not allowed | 3 | security | 1 | code-verified | fixed | `d64fd738` · tests (`AMV_PYTHON` run) | blocking |
| F21 | Expressions could read terminals and home | 3 | security | 1 | reproduced | fixed | `ea881d27` · fails without (`AMV_PYTHON`) | blocking |
| F22 | Repeated IDs crashed the app | 3 | crash | 2 | code-verified | fixed | `17eb57a1` · test | blocking |
| F23 | Negative component; package repeats and delays | 3 | crash | 2 | code-verified | fixed | `1aaeaf0b`, `4a8566c8` · test, no test | blocking |
| F24 | macOS 26 deprecations; sync asset loads | 1 | structure | 6 | reproduced | open | | nonblocking |
| F25 | Beat Match Confirm writes over a changed map | 2 | data safety | 1 | code-verified | fixed | `30bb1a18` · test | blocking |
| F26 | Viewer handle drag puts back a stale clip | 2 | data safety | 1 | code-verified | fixed | `6361cdbd` · test (viewer event suites run) | blocking |
| F27 | No lock where `flock` is missing, only a log | 2 | data safety | 1 | code-verified | fixed | `f683cb3d` · no test (no lockless volume here) | blocking |
| F28 | Provenance rewritten after a failed read | 2 | data safety | 1 | code-verified | fixed | `eeb7eb61` · test | blocking |
| F29 | Backups ordered by name across a clock change | 2 | data safety | 1 | code-verified | fixed | `27f199a6` · test (rename case) | blocking |
| F30 | Keyframes drift on speed-ramped clips | 2 | timing | 3 | code-verified | open | | blocking |
| F31 | The Waveform builds its own mix | 2 | sound | 3 | reported | open | | nonblocking |
| F32 | Typed value edit leaves rendered stretches stale | 2 | rendering | 3 | reported | open | | nonblocking |
| F33 | Mono clip's pan dropped silently | 2 | export | 3 | reported | open | | blocking |
| F34 | Stale Matroska reference movie used | 2 | export | 3 | suspected | open | | nonblocking |
| F35 | Python console edits the wrong project | 2 | data safety | 3 | reported | open | | blocking |
| F36 | Render stretch may start between frames | 2 | timing | 3 | suspected | open | | nonblocking |
| F37 | Open projects can share IDs in app-wide tables | 2 | correctness | 3 | reported | open | | nonblocking |
| F38 | `TimelinePreviews.shared` serves every project | 2 | performance | 4 | reported | open | | nonblocking |
| F39 | Browser skim draws as export does | 2 | performance | 4 | reported | open | | nonblocking |
| F40 | Tape scrub restarts effects every 2 s | 2 | sound | 5 | suspected | open | | nonblocking |
| F41 | Beat-marker choices in app-wide defaults | 2 | structure | 5 | reported | open | | nonblocking |
| F42 | Color panel and refusals across windows | 2 | usability | 5 | reported | open | | nonblocking |
| F43 | Failures nobody hears | 2 | usability | 5 | reported | open | | nonblocking |
| F44 | Low Power Mode and heat read directly | 2 | test harness | 5 | reported | open | | nonblocking |
| F45 | Gesture-driven views without event tests | 2 | test harness | 5 | reported | open | | nonblocking |
| F46 | Logic in `UI/` that belongs elsewhere | 2 | structure | 6 | reported | open | | nonblocking |
| F47 | Files with more than one job | 2 | structure | 6 | reported | open | | nonblocking |
| F48 | Numbers no project has crashed on opening | 3 | crash | 2 | code-verified | fixed | `d7d4be2c` · test | blocking |
| F49 | Text runs past their words trapped | 3 | crash | 2 | code-verified | fixed | `d7d4be2c` · test | blocking |
| F50 | A timeline holding clips of itself | 3 | crash | 2 | code-verified | fixed | `d437134f` · test | blocking |
| F51 | Names made into paths without cleaning | 3 | data safety | 3 | code-verified | fixed | `c79dfff3` · test | blocking |
| F52 | Clips with a missing source dropped at load | 3 | data safety | 1 | code-verified | fixed | `361b2418` · test | blocking |
| F53 | A kernel that never ends stalls the GPU | 3 | security | 4 | code-verified | decision (D8) | | nonblocking |
| F54 | `audio.bin` with billions of levels | 3 | performance | 4 | reported | open | | nonblocking |
| F55 | One expressions helper for every project | 3 | security | 3 | reported | open | | blocking |
| F56 | Non-finite expression samples | 3 | data safety | 3 | code-verified | fixed | `5996cf1a` · test | blocking |
| F57 | Helper messages buffered without limit | 3 | security | 2 | code-verified | fixed | `2d03725a` · test (`AMV_PYTHON` run) | blocking |
| F58 | A script's rational time has no bound | 3 | crash | 3 | code-verified | fixed | `958abd9b` · test | nonblocking |
| F59 | Recording an app with permission refused | 3 | usability | 3 | suspected | open | | nonblocking |
| F60 | Confined code can stat any path | 3 | security | 5 | reported | accepted risk (proposed) | | nonblocking |
| F61 | Python's licenses not shipped | 3 | release | 1 | code-verified | open | | blocking |
| F62 | `--pin` trusts the first download | 3 | security | 5 | code-verified | open | | nonblocking |
| F63 | A save wrote over an outside edit not yet seen | 4 | data safety | 1 | code-verified | fixed | `667aaad6` · test | blocking |
| F64 | Saves and reloads not kept in order | 4 | data safety | 1 | code-verified | fixed | `667aaad6` · test | blocking |
| F65 | Unreadable reload marked seen, then saved over | 4 | data safety | 1 | code-verified | fixed | `667aaad6` · test | blocking |
| F66 | A renamed project's new backups deleted | 4 | data safety | 1 | code-verified | fixed | `27f199a6` · test | blocking |
| F67 | Moving the open package splits the project | 4 | data safety | 3 | reported | open | | blocking |
| F68 | A failed Restore says nothing | 4 | data safety | 3 | code-verified | fixed | `82160372` · no test (modal alert) | blocking |
| F69 | Forget Original deletes before saving | 4 | data safety | 3 | reported | open | | nonblocking |
| F70 | Errors don't name the project | 4 | usability | 5 | code-verified | open (part fixed) | `667aaad6`, `82160372` name the reload's and the open's | nonblocking |
| F71 | A failed import deletes a file in the package | 4 | data safety | 1 | reproduced | fixed | `76e74035` · fails without | blocking |
| F72 | An export can replace a source media file | 4 | data safety | 1 | code-verified | open (part fixed) | `2142ee55` · test; stems' prompt open | blocking |
| F73 | Backups copy all media off APFS | 4 | performance | 2 | reported | open | | blocking |
| F74 | Opening a folder marks and locks it first | 4 | data safety | 1 | code-verified | fixed | `82160372` · test | blocking |
| F75 | A file gone while open isn't offline | 4 | export | 3 | reported | open | | nonblocking |
| F76 | An MKV offline at open stays unreadable | 4 | export | 3 | suspected | open | | nonblocking |
| F77 | Sound-found offsets not snapped to frames | 4 | timing | 3 | suspected | open | | blocking |
| F78 | Replacement against stale used ranges | 4 | correctness | 3 | suspected | open | | nonblocking |
| F79 | Replacing a package deletes it first | 4 | data safety | 1 | code-verified | fixed | `f31e5d6b` · test | blocking |
| F80 | A take moved to a name already taken | 4 | data safety | 5 | reported | open | | nonblocking |
| F81 | Undo past arrived analysis drops redo and loops | 4 | data safety | 1 | reproduced | fixed | `bed9243e` · fails without | blocking |
| F82 | Copied Keyframing effects look hand-edited | 4 | correctness | 3 | reported | open | | nonblocking |
| F83 | Duplicate Timeline keeps old layer references | 4 | correctness | 3 | reported | open | | nonblocking |
| F84 | Matte-wipe media not counted as used | 4 | correctness | 3 | reported | open | | nonblocking |
| F85 | A refused script result reported as kept | 4 | data safety | 3 | reported | open | | nonblocking |
| F86 | Damaged approval store emptied silently | 4 | usability | 5 | reported | open | | nonblocking |
| F87 | Naming an edit costs a scene scan | 4 | performance | 4 | suspected | open | | nonblocking |
| F88 | Fields not saved or reset on reopen | 4 | correctness | 6 | reported | open | | nonblocking |

## Open findings: detail and next action

Every next action's owner is unassigned until the owner says otherwise.

### Phase 1

**F4 — The whole suite under `UI_EVENTS` can hang.** *Expected:* every
run ends with a summary. *Observed:* one of two full runs after F2's
fix stopped finishing tests about 31 s in and was still stuck 15 minutes
later: five event tests waited on the event lock (one held it), and
`WaveformTests.theSpectrogramShadesItsCellsAndIsEmptyInSilence` never
finished; two `RenderCacheTests` timed out alongside. Event suites by
filter, and the suite without `UI_EVENTS`, never hung. *Lead, not
diagnosis:* the spectrogram reads sound through `WaveformAudio`, whose
synchronous asset loads are deprecated (F24). *Since:* two whole-suite
`UI_EVENTS` runs through `scripts/run-tests.sh` at `ccdb6ea7` passed
(2,749 tests, 81 s each), so the hang is intermittent or was disturbed
by fixes since (F5's pacing among them). *Next:* run whole-suite event
runs through the runner (`STALL_SECONDS=60`) until it recurs; its
samples and unfinished list are the diagnosis to take before any change
to `WaveformAudio`. Until then run event suites by filter, as AGENTS.md
now says.

**F5 — Tests that fail when the Mac is busy.** *Expected:* results
independent of load. *Observed:* `ScrubCacheTests`' fast drag failed in
every full run at load 6 (fixed, `c23427a8`: pacing on a clock the test
drives); still open: `ViewerFramingRedrawTests.thePictureFollowsAScrollAtOnce`
(66), `ClipBlockInteractionTests.aClickSelectsWithTheArrowAndCutsWithTheBlade`
(99, 107) once under `UI_EVENTS`, and three `PlaybackSkimTests` that
pace on real time. *Next:* the same clock for skimming's preroll waits.

**F7 — A clean checkout builds with no Python.** `scripts/python-pin`
is git-ignored. *Next:* decision D3.

**F24 — Deprecations.** Nine `AVMutableVideoComposition` warnings since
the minimum became 26 (`ComposedTimeline`, `CompositionPlanning`,
`PlayheadPrerenderer`), synchronous `tracks(withMediaType:)` and
`formatDescriptions` in `WaveformAudio.swift:80–81`, and
`BrowserPanel.swift:118`'s drop result now unused. *Next:* move to
`AVVideoComposition.Configuration` and `load(_:)`, the latter after
F4's capture.

### Phase 2

**F25 — *(fixed in `30bb1a18`)* Beat Match's Confirm writes over a beat map changed
meanwhile.** *Expected:* Confirm asks, or merges, when the song's map
changed since the panel opened. *Observed (reported):* it writes the
draft without comparing (`BeatMatchController.swift:85–93`); a script,
a reload or another timeline window can change the map in between.
*Next (A):* session test, then compare with the map the panel opened on.

**F26 — *(fixed in `6361cdbd`)* A viewer handle drag puts back the clip as it was at its
start.** *Observed (reported):* `ViewerHandlesOverlay.swift:839` commits
the whole clip from drag start; a script finishing during the held drag
(`ScriptRunner.swift:159` sees no `editCount` change while writes are
held) has its change to that clip undone on release. *Next (A):* a
`ProjectState` test of hold, outside write, release; commit only the
fields the drag changed.

**F27 — *(fixed in `f683cb3d`)* No lock where `flock` is missing.** *Observed (reported):*
`ProjectLock.swift:42` opens without a lock and only logs it; two Macs
on a share can both save one project, and `trashPackage(checkingLock:)`
can trash one open elsewhere. *Next (A):* tell the person on opening,
and refuse trashing without a lock.

**F28 — *(fixed in `eeb7eb61`)* Provenance rewritten from nothing after a failed read.**
*Observed (reported):* `readProvenance` returns `[:]` on any failure
(`ProjectStore+Provenance.swift:18–46`) and the next record writes only
the new kind, dropping `.originalScores` for good. *Next (A):* refuse
to write when the file exists but can't be read.

**F30 — Volume and effect keyframes drift on speed-ramped clips.**
*Observed (code-verified):* `CompositionFlattening.swift:76–83` gives a
clip's mix stage the speed at its in point, so on a ramp keyframes are
heard late in playback and export alike, while the volume line shows
them in place. *Next:* the mix following the clip's time map; a test
that keys a step on a ramped clip and finds it in `MixReading`.

**F31 — The Waveform builds its own mix.** Leaves out pan, fades and
crossfades, the dynamics effects and Keep Pitch, and indexes a
late-starting track from its first sample. Documented in
[waveform-effect.md](waveform-effect.md). *Next:* share the mix's stages,
or accept with the documentation as it is.

**F32 — A typed value edit while paused leaves rendered stretches
stale** (`PlaybackModel.showValues`, `:304`); export is right. *Next:*
test `playedUsesRenders` after `showValues`.

**F33 — A mono clip's pan is dropped silently** when its stereo copy
can't be made (`CompositionExporter.swift:150–156`,
`StereoProxies.swift:126`). *Next:* fail the export with the reason.

**F34 — A stale Matroska reference movie is used** when remaking it
fails (`MatroskaMedia.swift:48`). *Next:* verify; refuse rather than
read moved bytes.

**F35 — The Python console edits the wrong project** with a Timeline
window in front (`ScriptConsole.swift:67–72`). *Next:* route by the key
window's session.

**F36 — A render stretch may start between frames**
(`SegmentRenderer.swift:26`). *Next:* compare exported frames of an
animated stretch off the grid with and without the cache (phase 7).

**F37 — Open projects can share IDs** (Save As keeps them all) while
`DetectedBeats`, `TimelinePreviews`, `EqualizerSpectrum` and
`ExpressionRunner.running` are keyed by them app-wide. *Next:* key by
session.

**F38–F47.** `TimelinePreviews.shared` drops another project's previews
(`TimelinePreview.swift:141–229`); browser skim and effect thumbnails
draw as export does (`TimelinePreview.swift:40`,
`EffectThumbnails.swift:103`); tape scrub restarts the sound effects
every 2 s piece (`TapeScrub.swift:193–198`, suspected); beat-marker
choices live in app-wide defaults (`TimelineView.swift:113`); closing
any editor window ends the color panel and refusals show in whichever
window is key (`EditorView.swift:238`); failures nobody hears
(`MediaReplacer.swift:127`, `Waveform.swift:174`, `Spectrogram.swift:254`,
Save As folder listing, `PresetStore.swift:89`, `BlankFrame.swift:33`,
`EffectFolderWatcher.swift:44`); `ScrubCache.swift:150` and
`RenderScheduler.swift:246–250` read Low Power Mode and heat directly;
gesture-driven views without an `EventHarness` suite (`TimelineRuler`,
`BeatMatchWaveform`, `ToneGraph`, `EqualizerGraph`, the lanes, the
transition curve and gradient editors, `NumericField` scrubbing, the
tape scrubber, the scene splitter); logic in `UI/` (the export queue,
`MediaReplacementController`'s change detection, `MediaImportFlow`,
`TimelineEditorSurface.handle(_:)`); and files with more than one job
(`Keyframing`, `AssetAnalysis`, `EffectPackageStore`, `ClipTransition`,
`BeatMatchSession`). *Next:* phases 6, 9, 10 and 11, in that order.

### Phase 3

**F50 — *(fixed in `d437134f`)* A timeline holding clips of itself** loads; rendering refuses
it, but the Waveform's walk (`WaveformEffect.swift:548`) has no visited
set and makes N^8 calls. *Next (B):* refuse cycles at load, through
effect inputs that take a timeline too.

**F51 — *(fixed in `c79dfff3`)* Names made into paths without cleaning:** Duplicate of a package
named `../../Desktop/x`, Make Package, backups named for the project
(`EffectPackageStore.swift:386–425`, `ProjectBackups.swift:105–209`).
Each only creates and never overwrites, so far as read. *Next (A):*
clean every name used as a path with one function, as
`PresetStore.freeID` does.

**F52 — *(fixed in `361b2418`)* Clips whose source can't be resolved are dropped at load**
(`ProjectStore+Load.swift:85`, `compactMap`), and the next save loses
them. A missing *file* doesn't lead here (it loads offline); a missing
*asset entry* or nested timeline does. *Next (A):* refuse the file
naming the clip, rather than drop it.

**F53 — A kernel that never ends** stalls the GPU until the watchdog,
every frame; a Swift cancellation doesn't stop submitted work. *Next:*
decision D8.

**F54 — `audio.bin` with billions of levels** asks for memory in
proportion (its count must equal its length). *Next:* cap the levels.

**F55 — One expressions helper serves every project,** with real
builtins: approved code in one can patch the helper's caches or leave a
thread answering later runs (`expressions.py:311,340`). A helper per
project limits it across projects, not between runs of one. *Next:*
restart the helper after a run that leaves threads, and per project.

**F56 — *(fixed in `5996cf1a`)* Non-finite expression samples** are counted, not checked, in the
app (`PythonHelper.swift:167–176`); NaN keyframes would fail saving.
*Next (B):* refuse non-finite samples.

**F57 — *(fixed in `2d03725a`)* Helper messages are buffered without limit:** payload sizes up
to 9×10^15 (`ScriptMessages.swift:53–57`), frames queued while no run
reads, the buffer copied per frame (`PythonHelper.swift:352`). *Next
(B):* budgets: payload at most what the request asked for, frames
dropped outside a run, a read offset instead of copies.

**F58 — *(fixed in `958abd9b`)* A script's time as `[n, d]` has no bound**
(`ProjectBridge.swift:506–515`), unlike one in seconds. *Next (B):* the
same bound as `TimeEntry`.

**F59 — Recording another app with its permission refused** probably
gives a silent take with no message (`AudioCapture.swift:79–116`).
*Next:* try with `tccutil reset`.

**F60 — Confined code can stat any path** (`file-read-metadata`), and
whether `cfprefsd` refuses it a write is untested. Proposed as accepted
risk: an expression learns a file exists and its size, and can send out
only numbers.

**F61 — Python's licenses aren't shipped:** nothing copies the CPython
build's license or those of what it bundles (OpenSSL, SQLite, libffi,
zlib). *Next:* copy them into the bundle and list them in an About
window or a notices file.

**F62 — `--pin` trusts the first download:** it takes the hash from the
same release it fetches. *Next:* check it against a second source, or
accept with D3.

### Phase 4

**F67 — Moving or renaming the open package splits the project.**
Nothing notices the move; the next save's `preparePackage` recreates a
package at the old path with `Media/` paths into nothing, unlocked
(`ProjectStore.swift:101–108`, `ProjectSession.swift:305,387`). *Next:*
refuse to save where the package was moved from, or follow it.

**F68 — *(fixed in `82160372`)* A failed Restore says nothing** (`ProjectSession.swift:223`,
`try?`): the saved version opens, and the first save makes the autosave
look older, so it is never offered again. *Next:* say so and keep
offering it.

**F69 — Forget Original deletes `Reference/<id>` before `project.json`
is written** (`ProjectStore+Save.swift:91–94` against `:105`); a failed
write leaves the file saying the original is kept. *Next:* delete after.

**F70 — *(part fixed in `667aaad6`, `82160372` name the reload's and the open's)* Errors don't name the project** (`ProjectSession.swift:259`);
the reload's alert now does (`667aaad6`).

**F71 — *(fixed in `76e74035`)* A failed import deletes a file already in the package.**
*Observed (reported):* `copyIntoPackage` returns the source itself when
it is inside the package, and the import's `catch` removes that "copy"
(`MediaImportFlow.swift:66–69,85`, `ProjectStore+MediaConsolidation.swift:79`):
a file in a subfolder of `Media/`, one already used, or one through a
linked folder is deleted for good on any import error. *Next (A):*
verify with a test, then delete only a file the import made.

**F72 — *(part fixed in `2142ee55`)* An export can replace a source media file.** Only other
exports' destinations are checked (`ExportDestinations.conflict`), so
exporting over `clip.mov` that the timeline plays reads it while
rendering and then replaces it; stems overwrite same-named files in a
chosen folder unasked. *Next (A):* refuse a destination any clip, effect
input or matte uses, and ask before replacing stems.

**F73 — Backups copy all of `Media/` off APFS** every 15 minutes, up to
ten kept, holding saves behind them (`ProjectBackups.swift:145–166`).
*Next:* skip media, or warn, where `volumeSupportsFileCloning` is false.

**F74 — *(fixed in `82160372`)* Opening any folder with a `project.json` marks it a package and
writes `.lock` into it before the format is checked**
(`ProjectSession.swift:214–217`). *Next (A):* mark and lock after the
load succeeds.

**F75 — A file that disappears while open isn't treated as offline:**
`MediaTrackCache` keeps the asset (`MediaReplacementController.swift:154–181`),
so the viewer and export fail with a generic error. *Next:* drop the
cache entry for missing files too; a test that deletes one.

**F76 — An MKV offline at open stays unreadable after it returns:** its
reference movie was removed at load and nothing remakes it until a save
(`ProjectStore+Load.swift:187`, `MatroskaMedia.swift:44–48`). *Next:*
make it when the file returns.

**F77 — Offsets found from sound aren't snapped to frames:** in
hundredths of a second, a one-frame shift at 24 fps (41.7 ms) comes back
as 40 ms, and every cut then shows the frame before
(`MediaAlignment.swift:79–81`, `MediaReplacer.swift:146`). *Next:* a
test with a candidate delayed exactly one frame; snap to the candidate's
frame grid.

**F78 — Replacement against stale used ranges:** `used` is taken before
a slow analysis and not taken again; spare frames under dissolves aren't
counted; effect inputs bound by file time (`MediaReplacementController.swift:410–427`,
`EffectInputs.swift:65`). *Next:* verify.

**F79 — *(fixed in `f31e5d6b`)* Replacing an installed effect package deletes the old one before
copying the new** (`EffectPackageStore.swift:482–484`), losing a
package the person wrote if the copy fails. *Next (A):* copy beside,
then swap in.

**F80 — A take is moved to a fixed name** (`AudioRecorder.swift:138`);
two in one second throw and leave it in `/tmp` without saying.
*Next:* a unique name.

**F81 — *(fixed in `bed9243e`)* An undo past newly arrived analysis records a new step, drops
the redo stack and can't go further back.** *Observed (suspected,
strong):* arriving beats update only the history's baseline
(`EditorView.swift:322–356`); after an undo, `refreshKeyframing(after:)`
regenerates keyframes from the stale snapshot, which registers as a new
step. *Next (A):* reproduce with a session test and a real
`UndoManager`; refresh inside the restore, or guard it as `followMusic`
is.

**F82 — A copied clip's Keyframing effects look hand-edited:**
`duplicated()` doesn't recompute `writtenPrint`
(`ClipPasting.swift:26–60`; `duplicateEffect` does). *Next:* recompute.

**F83 — Duplicate Timeline doesn't remap references inside effects:**
`beatLayer`, Audio Keys' `audioSource`, Waveform `listensTo`, expression
`reads` (`TimelineTree.swift:99–124`). *Next:* remap as `reach` is.

**F84 — Matte-wipe media isn't counted as used** by paste or removal
(`PasteSources.swift:32–45`, `ItemUses.swift:37–100`). *Next:* count it.

**F85 — A script result refused at the end is reported as kept,** and
its step name sticks to the next edit (`ScriptRunner.swift:153–161`).
*Next:* report the refusal; clear the name.

**F86 — A damaged approval store is emptied silently** and the next
approval writes over it (`CodeApproval.swift:54–58,176–185`). *Next:*
keep it aside and say so.

**F87 — Naming an edit runs a scene scan** of the clip's whole file per
keystroke (`ProjectChange.step` before the merge check,
`EditorView.swift:410–412`). *Next:* measure on a dense fixture (D).

**F88 — Fields not saved or reset on reopen:** an animated value's
`value`, `BeatMap.usesSections` without sections, held package controls
(intended); clip, effect and control IDs not checked for repeats at
load. *Next:* decide which matter; a round-trip test over generated
projects (phase 11).

## Fixed findings: detail

**F1 — The loop region's end edge couldn't be taken.**
`UI/Components/LoopBar.swift:177`. The edge handles straddle the chip's
ends, but the region's content shape was the chip's own rectangle, which
limits hits for everything inside it: the outer half of each handle was
dead and a press exactly on the end edge reached nothing.
`LoopBarInteractionTests` failed its edge click and drag on every
`UI_EVENTS` run, hidden by F2. The content shape now reaches half a
handle past each end, sideways only.

**F2 — Event runs ended early and reported success.** A test pressed
Space on a focused `NSButton`; its click flash left a `CFRunLoopStop`
that, landing on the main run loop Swift Testing runs on, made the
process `exit(0)` without a summary, so later tests never ran and
printed failures still exited 0. Traced in `lldb` on `CFRunLoopStop` and
`exit`. The button's cell now counts the click instead of flashing.

**F3 — Convert to Path's refusal said "nil".**
`EffectsPanelEffects.swift:329` interpolated the optional `Effect.name`;
it uses `displayName`.

**F6 — The binaries recorded SDK 15.0** (`LC_BUILD_VERSION`), the
deployment target, though built with the 27.2 SDK. With the minimum at
26.0 they record 26.0: behavior "linked on or after 26" is had, behavior
new in 27 isn't. Residual, nonblocking.

**F8 — A failed export lost the file it was replacing.** Movie, WAV Mix
and stems exports deleted the destination before writing. Each writes
beside it (`Export/ExportFile.swift`) and swaps in only when whole;
tests stop a mix and a stems export halfway.

**F9 — A take that couldn't be copied into the project was deleted** by
a `defer`. It is kept in the Recordings folder and the error names it.

**F10 — An outside edit was marked seen while the Motion Designer
refused it,** and the next save wrote over it. It waits until the locks
go.

**F11 — Stale background renders for effect inputs.** The render key
never read `DrawClip.inputs`; it names the input's file, stamp and
played stretches, or describes the nested timeline. The test fails three
ways without the fix.

**F12 — The Waveform and Audio Keys heard silenced clips;** one check,
`EditingProject.soundIsHeard`, states the mix's rule.

**F13 — Beat match played every enabled sound track** while its
waveform, the timeline and export use the first. It plays the first.

**F14 — Status lines behind the code,** corrected in the docs.

**F15 — Logged names were read as format strings.** Thirteen `NSLog`
calls interpolated into the format; twelve `%@` in a project's name
crashed a probe with a bus error. Each logs `"%@"` with the text as its
argument.

**F16 — Matroska files that crash, hang or overrun the index:** lacing
running past its block (a trap), children bounded by the file rather
than their parent, fixed lacing over nothing, a million tracks with a
linear lookup, a timestamp scale of 0, PCM samples past the file. Each
is refused or not indexed; a sweep of every cut and changed byte of a
small laced file reads or refuses, never traps. Not yet run under the
address sanitizer.

**F17 — `audio.bin`'s start overflowed** (Int64.min); starts beyond
2^40 windows are damage.

**F18 — An edited viewer-copy index could delete any folder**
(`../../..`); only plain names with times that fit are read. The test's
sibling file was deleted without the fix.

**F19 — A cache folder linked out of the package was emptied;** both
clean-ups clear only a folder resolving inside the package.

**F20 — An allowed script could import code no one allowed.** Allowing
covers the name and hash of every other file in the script's folder, and
the helper forgets a script's own modules when it ends. Residual, open
under F55 and the plan's approval criteria: links and imports reaching
outside the folder, the interpreter's start-up (`site`, `.pth`), and
threads outliving a run aren't covered.

**F21 — Expressions could read terminals and the home folder.** `/dev`
is gone from the readable list, an installation that is or holds the
home folder is left out, and fork, `posix_spawn` and `subprocess` of the
interpreter are tested refused.

**F22 — Repeated IDs crashed the app;** a file repeating a media file's,
timeline's, layer's or section's ID is refused, naming which.

**F23 — A negative keyframing component trapped, and package repeats and
delays trapped or hung;** components outside the control write nothing,
passes are finite and at most 256, a delay too far draws the present.

**F29 and F66 — Backups ordered by name.** Outside backups begin with the
project's name, so after a rename each new one was pruned as soon as it
was written; package autosaves were named in local time, which repeats
an hour when clocks go back. Outside backups are ordered by the time in
their `backup.json`; autosave names are in UTC.

**F48 and F49 — Numbers no project has, and text runs past their
words,** crashed on opening or the first redraw. Times beyond 10^9 s are
refused where read; frame sides outside 1 to 16,384, frame rates outside
0 to 1,000, beat positions past 2^20 and runs outside their words are
refused at load with a message.

**F63, F64 and F65 — Saves and outside edits.** A save half a second
after an edit came before the two-second check and wrote over an outside
edit; saves and reloads shared a busy flag the save cleared mid-reload;
and a file that couldn't be read was marked seen and then saved over. A
save now waits for a reload and takes a change first, asking while there
are unsaved edits; a change it can't take is never written over by an
automatic save and Save asks; an unreadable file is read again once and
then told, naming the project.

## Decisions for the owner

- **D1. macOS 26 and later.** Decided by the owner; done (`193d3e4c`).
- **D2. Apple silicon only.** Decided by the owner; `build-app.sh`
  builds arm64 and checks it. The CPU fallback for a missing Metal
  device stays, unsupported, rather than crash a virtual machine.
- **D3. Commit `scripts/python-pin`?** Recommended: yes, for builds
  that bundle the same Python from any checkout (F7, F62).
- **D4. Pin CI's actions by commit?** Recommended: yes.
- **D5. What "Always Run This Project's Scripts" trusts.** As built it
  trusts whatever later arrives at the project's ID and path, a `git
  pull` or a synced folder included; ID and path identify a project but
  don't vouch for its later code. Either keep it, with the prompt saying
  it trusts the project's future changes, or ask again when a script
  changed outside the app.
- **D6. App Sandbox.** Not adopted. Adopting it needs security-scoped
  bookmarks for media in place and on other drives, export destinations
  and the interpreter, and another way to confine expressions, as
  `sandbox-exec` can't run inside it. Confining expressions protects one
  boundary, not the app. *Residual risks without it:* media handed to
  system frameworks (AVFoundation, VideoToolbox, ImageIO) is parsed
  with the person's full access; package kernels are compiled and run;
  the app's own file operations reach anything the person can; approved
  scripts run unconfined by design. *Controls in its place:* the app's
  own parsers bounded and swept (F16, F17, F48), path checks on deletion
  (F18, F19), confined expressions (F21), approval of the code run
  (F20), no network. Recommended: defer, as a recorded product decision
  accepting those risks, and reconsider before distributing widely.
- **D7. Review projects.** Licensed footage replaced, for now, by
  generated fixtures (checkpoint D); real footage for a later
  qualitative check.
- **D8. Third-party kernels.** Whether to warn on installing a package
  from outside, since no time limit can be relied on (F53).

## Phase records

### Phase 1 baseline (historical, at `4387fb11`)

What phase 1 measured, as it was then. Since changed: the minimum is
26.0 and builds are arm64 only (D1, D2); F1 to F3 are fixed; the Mac's
load varied in later runs (F5).

| | |
| --- | --- |
| Mac | MacBook Pro (Mac16,8), Apple M4 Pro, 10 performance and 4 efficiency cores, 24 GB |
| macOS | 26.7.3 (25G342) |
| Xcode | 27.2 (27B52), as CI pins; macOS SDK 27.2 |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| Python | Homebrew 3.15.2 for `AMV_PYTHON`; the system's 3.9.6 is older than the helper's 3.11 minimum |

At the baseline the plan's facts table held (then: macOS 15.0 minimum,
ad hoc signing without entitlements or hardened runtime, no network
APIs, 531 source and 295 test files), except that `Resources/Effects/`
holds 78 folders (77 looks and the hidden `.template.amveffect`) and
Swift has no `print` calls (the two matches are in Python strings).

| Build | Result | Time (wall) |
| --- | --- | --- |
| `swift build`, clean | Passed | 26 s |
| `swift build -c release`, clean | Passed | 2 min 23 s |
| `swift build -c release -Xswiftc -enable-testing --build-tests` | Passed | 6 min 6 s |
| `scripts/build-app.sh` (release) | Passed; 43 MB, arm64, ad hoc signature verifies | 2 min 21 s |

`Packaging/Info.plist` lints, and its three exported types match the
code's identifiers. Seven compiler warnings then (F3, F24, and two
harmless: capture warnings at `TimelineEditorSurface.swift:445`, a
`var` at `WaveformDrawing.swift:248`); ten unused results in
`KeyingTests` (harmless); ten CoreMedia low-timescale warnings per run
from `SceneReviewTests.swift:261`, on purpose.

**Tests then:** 2,716 tests in 404 suites passed three times as CI runs
them (41.5 to 43.4 s, 211 skipped in gated suites); `AMV_PYTHON` 20
passed, the helper's Python 52 passed on 3.15; `SNAPSHOT_DIR` 100 passed
(143 pictures, not yet looked at); `UI_EVENTS` failed (F1, F2), then
passed by filter (89 tests) and hung once whole (F4). The suite is now
2,724 tests and more.

**Benchmarks (release), not representative** without review projects:

| `RenderThroughputBenchmark` (16 s, 1080p, 24 fps) | Fastest s | fps |
| --- | --- | --- |
| blur, 1 at once | 2.27 | 169.0 |
| blur, export without cache | 1.95 | 196.8 |
| motion, 1 at once | 6.96 | 55.1 |
| motion, export without cache | 6.43 | 59.8 |

`EdgeTransitionsBenchmark`: `effect(at:)` 14.9 ns, `transitionFrame(at:)`
110.3 ns a frame, `TransitionFrame.key` 255.9 ns.

`UIResponsivenessBenchmark` (main thread, ms a step, median / max):
value drags 0.2 to 3.1 / under 7; step-frame 4.2 / 15.3; nudge-clip
46.7 / 57.3; zoom 15.9 / 19.4; busy-zoom 61.8 / 66.5; busy zoomed-in
zoom 100.8 / 153.1; busy zoomed-in step-frame 5.4 / 72.0 (a stall every
twelfth step). The zooms and nudges are phase 9's first suspects.

### Phases 2 to 4

Phase 2 (at `ad3c3dc0`) and phase 3 (at `c23427a8`) each ran read-only
reviews side by side, one per group of the plan's items, and the fixes
were checked against the code before they were made. Phase 4 (at
`deec68d0`) ran three: saving, autosave, the lock and live reload;
identity, round trip and undo; and footage safety, with a table of every
write, move and delete in the sources, of which F71, F72, F79 and the
backup pruning (F66) were the unsafe ones. Privacy and dependency checks
in phase 3 found no network use and the logs holding error text and file
and package names, kept.
