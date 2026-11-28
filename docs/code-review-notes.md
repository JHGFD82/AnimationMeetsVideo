# Code review notes

Status: **review notes** for the first pass of
[code-review-plan.md](code-review-plan.md). Phases 1 to 3 have been
reviewed (phase 1 only in part), phases 4 and 5 are being reviewed, and
the plan's stabilization checkpoint is done but for F4's hang, which
hasn't recurred to be captured; the owner's decisions D3 to D8 are
recorded and built (F89, F90), but for release gates that wait for
phase 12; phases 6 to 12 haven't started. Many findings
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
| 1. Scope and build baseline | Partial | The performance baseline is of the benchmarks' own timelines; the generated dense edit (checkpoint D) is yet to be benchmarked; the whole suite under `UI_EVENTS` has hung once (F4) | F4, F5, F24 |
| 2. Architecture and maintainability | Complete | | F30–F47; its severity-1 findings are fixed |
| 3. Security, privacy and dependencies | Complete | | F54, F55, F59–F62 (F53 accepted under D8) |
| Owner's decisions D3–D8 | Done but for release gates | D6's signing, notarization and signed-app confinement wait for phase 12; D7's footage for phases 7 and 8 | |
| Stabilization checkpoint | Done but for F4 | F4 not reproduced in two runs since, to be captured by `run-tests.sh` when it recurs | F4 |
| 4. Project model and persistence | Partial | Three reviews made and recorded; its severity-1 findings fixed but F72's stems prompt | F67, F69, F70, F72, F73, F75–F80, F82–F88 |
| 5. Timeline, timing and music sync | Partial | Four reviews made and recorded; the end-to-end sync export test isn't built; the beat tick and MIDI taps read, not tried on hardware; detection quality judged on generated scores, not episodes (D7) | F105, F106, F108, F109, F112 |
| 6 to 12 | Not started | May start: checkpoint A to C are closed but for F4 | |

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
| F7 | A clean checkout builds with no Python | 1 | packaging | 3 | reproduced | fixed | `96409e50` · tried both ways | blocking |
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
| F30 | Keyframes drift on speed-ramped clips | 2 | timing | 3 | reproduced | fixed | `f42d3664` · fails without | blocking |
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
| F53 | A kernel that never ends stalls the GPU | 3 | security | 4 | code-verified | accepted risk (D8) | `4c7ab74c` · approval and recovery launch | nonblocking |
| F54 | `audio.bin` with billions of levels | 3 | performance | 4 | reported | open | | nonblocking |
| F55 | One expressions helper for every project | 3 | security | 3 | reported | open | | blocking |
| F56 | Non-finite expression samples | 3 | data safety | 3 | code-verified | fixed | `5996cf1a` · test | blocking |
| F57 | Helper messages buffered without limit | 3 | security | 2 | code-verified | fixed | `2d03725a` · test (`AMV_PYTHON` run) | blocking |
| F58 | A script's rational time has no bound | 3 | crash | 3 | code-verified | fixed | `958abd9b` · test | nonblocking |
| F59 | Recording an app with permission refused | 3 | usability | 3 | suspected | open | | nonblocking |
| F60 | Confined code can stat any path | 3 | security | 5 | reported | accepted risk (proposed) | | nonblocking |
| F61 | Python's licenses not shipped | 3 | release | 1 | code-verified | open (part fixed) | `96409e50` · CPython's own license required | blocking |
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
| F77 | Sound-found offsets not snapped to frames | 4 | timing | 3 | reproduced | fixed | `d049d6d2` · fails without | blocking |
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
| F89 | Remembered script approval trusts a project's ID and path | D5 | security | 1 | code-verified | fixed | `5ab4864e` · test (`AMV_PYTHON` run) | blocking |
| F90 | External effect kernels compile without the person's approval | D8 | security | 1 | code-verified | fixed | `4c7ab74c` · test, snapshot | blocking |
| F91 | Rounded frame stamps show frames twice and skip others | 5 | timing | 3 | reproduced | fixed | `620c1ad1` · fails without | blocking |
| F92 | Tape scrub rests a tick before its frame | 5 | timing | 3 | reproduced | fixed | `909eb1d6` · fails without | blocking |
| F93 | Whole rates of 10 fps and under taken for NTSC | 5 | timing | 3 | reproduced | fixed | `59ba4470` · test | nonblocking |
| F94 | Pasted keyframes can land a tick before their frame | 5 | timing | 3 | reproduced | fixed | `fac2eb3f` · fails without | nonblocking |
| F95 | A script's split at a fraction is off the frames | 5 | timing | 3 | reproduced | fixed | `416ab9d4` · fails without | nonblocking |
| F96 | A viewer copy can be made again and again | 5 | performance | 4 | reproduced | fixed | `6c66b2ad` · test (old form shown short) | nonblocking |
| F97 | Fast scrub shows the next frame at a typed 23.976 | 5 | rendering | 5 | reproduced | fixed | `cc3c6a42` · fails without | nonblocking |
| F98 | Sound-only clips never join, so crossfades dip | 5 | sound | 3 | reproduced | fixed | `9a23eccb` · fails without | nonblocking |
| F99 | Detach Audio drops the fades under transitions | 5 | sound | 3 | reproduced | fixed | `6fc17175` · fails without | nonblocking |
| F100 | Scene-following splits land between frames | 5 | timing | 3 | reproduced | fixed | `49fe216a` · fails without | blocking |
| F101 | Two joints can overlap inside a short clip | 5 | rendering | 3 | reproduced | fixed | `61f0cf09` · fails without | nonblocking |
| F102 | A joint slip can leave a transition without footage | 5 | rendering | 3 | reproduced | fixed | `8b6ab67d` · fails without | nonblocking |
| F103 | A joint drawn beside a disabled clip | 5 | usability | 5 | reproduced | fixed | `5d8e870a` · fails without | nonblocking |
| F104 | Ramped clips' times cut down a tick | 5 | timing | 3 | reproduced | fixed | `50e32741` · fails without | blocking |
| F105 | Blend on slowed clips mixes in the next scene | 5 | rendering | 3 | code-verified | open | | nonblocking |
| F106 | Reversed clips show the frame before | 5 | timing | 3 | code-verified | open | | blocking |
| F107 | Export doesn't wait for running expressions | 5 | export | 3 | code-verified | fixed | `a7a486de` · test (the check; the alert by hand) | blocking |
| F108 | Beat Keys rewritten flat before beats load | 5 | correctness | 3 | suspected | open | | nonblocking |
| F109 | Speeds outside the time-pitch range untried | 5 | sound | 3 | suspected | open | | nonblocking |
| F110 | Detected beats about 10 ms early | 5 | timing | 3 | reproduced | fixed | `8d7f131a`, `10bba6bd` · fails without | blocking |
| F111 | Beat Keys pulses late or missing between frames | 5 | timing | 3 | reproduced | fixed | `41f74dc5` · fails without | blocking |
| F112 | Held drawings and two-frame flashes cut | 5 | correctness | 3 | reproduced | open | | nonblocking |

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
pace on real time. In phase 5's full runs at load 8 to 14, once each and
passing on the rerun: `AssetAnalysisTests.aReadThatFailsIsTriedAgainRatherThanAnalyzedOver`
(a 50 ms sleep) and `TapeScrubTests.theTapeRunsAtTheSpeedAskedAndComesToRest`
(a real audio engine against sleeps). *Next:* the same clock for
skimming's preroll waits, and for these two.

**F7 — A clean checkout builds with no Python.** *(fixed in
`96409e50`)* The pin is committed (D3) and `build-app.sh` fails unless
the app has the pinned Python and its license; tried without the pin
(fails, exit 1), with `ALLOW_NO_PYTHON=1` (builds, warns) and with it
(bundles 3.14.10).

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

**F30 — *(fixed in `f42d3664`)* Volume and effect keyframes drift on speed-ramped clips.**
*Observed (code-verified):* `CompositionFlattening.swift:76–83` gives a
clip's mix stage the speed at its in point, so on a ramp keyframes are
heard late in playback and export alike, while the volume line shows
them in place. *Fixed:* a ramped clip's mix stage carries the
root-to-source map of the pieces its sound is placed in (`MixTimeMap`),
searched without allocating on the tap thread; a volume step keyed at
source 2 s on a 50%→200% ramp was never heard (it fell past the clip's
end) and now is, at 2.44 s.

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
every frame; a Swift cancellation doesn't stop submitted work. *Accepted
under D8:* no time limit is promised; an outside package runs only once
approved for its content (F90), and a recovery launch leaves such
packages out.

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

**F61 — Python's licenses aren't shipped:** *(part fixed in
`96409e50`)* the CPython license (`lib/python3.14/LICENSE.txt`) is now
required in the bundle, but the notices of what the build links in
(OpenSSL, SQLite, libffi, zlib, and others python-build-standalone
documents) aren't in its archive. *Next:* gather them into a notices
file in the bundle and list it in an About window.

**F62 — `--pin` trusts the first download:** it takes the hash from the
same release it fetches. Since D3 a new pin lands only in a reviewed
commit of its own, which narrows it to a release compromised when the
pin is made. *Next:* check the hash against a second source (the
release's signed attestation), or the owner accepts the risk.

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

**F77 — *(fixed in `d049d6d2`)* Offsets found from sound aren't snapped to frames:** in
hundredths of a second, a one-frame shift at 24 fps (41.7 ms) comes back
as 40 ms, and every cut then shows the frame before
(`MediaAlignment.swift:79–81`, `MediaReplacer.swift:146`). Worse, the
in-sync check allowed a whole frame, so that file was taken for aligned
at no offset and replaced without asking. *Fixed:* the suggestion goes
to the new file's nearest frame, and in sync means within half a frame
(an envelope step for sound alone).

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

### Phase 5

Fixed this pass, each with a test that fails without it: **F91** (rounded
frame stamps: footage is read a tick of its track's timescale late, at
most a quarter frame; at 90 kHz a 23.976 file had shown every fourth
frame twice), **F92** (the tape scrubber rests on its frame's exact
start), **F93** (8 and 10 fps had NTSC frame lengths; test only),
**F100** (scene-following splits on the timeline's frames, as the blade
does, and joins what it split), **F104** (ramp times rounded to the
nearest tick, the trim itself when no time has passed), **F111** (Beat
Keys pulses on the beat's nearest frame, at full height, and a decay
under a frame over by the next one), **F94** (pasted keyframes on the
nearest frame), **F95** (a script's split on the nearest frame for a clip
with pictures), **F96** (viewer copy records keep their ends exactly; an
older index reads by seconds and is remade once), **F97** (the scrub
cache counts frames in the exact frame duration), **F107** (Export…
asks, Wait or Export Anyway, while expressions or Keyframing effects are
still being written; never refuses, since an expression can wait for
good without Python), **F110** (detected beats refined between frames
and moved by a measured 180-sample lead; saved beats detected again),
**F98** (sound clips join one another at a cut and crossfade over their
spare sound), **F99** (detached sound takes the fades it had under the
picture's transitions: copies of joined clips join, others fade over the
same span, lengthened into a joint that stays), **F101** (a joint is
fitted clear of the outgoing clip's way in and of the joint after the
incoming clip), **F102** (a slip stops where a joint at either end would
lose footage it plays), **F103** (a disabled clip joins nothing, so the
timeline draws the transition at an open end as the export plays it).

**F94 — *(fixed in `fac2eb3f`)* Pasted keyframes can land a tick before their frame.**
`KeyframeCopying.swift:13,73` keeps offsets as `Double` and `:107` makes
them with truncating `CMTime(seconds:)`; at 23.976, 234 of 995 offsets
came out 1/240000 s early, and later edits at that frame, matched by
exact time (`AnimatedValue.swift:191`), add a second keyframe beside it.
*Next:* keep offsets as `CMTime`, snapped to the frame; a paste test at
23.976.

**F95 — *(fixed in `416ab9d4`)* A script's split at a `Fraction` leaves a picture clip off the
frames** (`ProjectBridge.swift:518–519`, `EditingProject.swift:284`).
*Next:* round through `placementTime(.nearest, frameLocked:)`.

**F96 — *(fixed in `6c66b2ad`)* A viewer copy can be made again and again.** Its record's range
is rebuilt from `Double` seconds (`ViewerCopies.swift:161–165`), and with
edges whose timescales' common multiple overflows 32 bits it comes back
a little smaller, so `missing` (`:266–270`) never finds it covered and
the copy is made again (reported: arithmetic reproduced, loop not run).
*Next:* store value and timescale; a round-trip test with mixed
timescales.

**F97 — *(fixed in `cc3c6a42`)* Fast scrubbing shows the next frame at a typed 23.976**
(`ScrubCache.swift:66–68`, `floor(t·rate)`); the exact landing corrects
it. *Next:* index by the exact frame duration, as F92.

**F98 — *(fixed in `9a23eccb`)* Sound-only clips never join** (`ClipTransition.swift:516–519`
needs `playsVideo`), so a Crossfade dropped between two sound clips
fades one out to silence and cuts the next in, against
transitions.md:162–165. *Next:* joinable sound clips; a loudness test at
the cut. *Left:* projects saved before keep such a transition as the
first clip's way out, and a way out at a cut now also fades the next
clip in under it, from before its in point where its file has spare
sound: what was a dip at those cuts becomes a crossfade, with no saved
setting changed. That is the documented behavior, but it changes how
existing edits sound. *Next:* listen to a project with fades between
song pieces or sound clips.

**F99 — *(fixed in `6fc17175`)* Detach Audio drops the fades under picture transitions**
(`LinkedAudio.swift:100–101`), against its own comment that the sound
plays as before. *Next:* give the sound the matching Audio transition,
after F98. *Left:* at an open end a picture transition's sound follows
its curve, which an Audio transition hasn't; the copy fades at equal
power over the same span, the same fade only where the curve was linear.

**F101 — *(fixed in `61f0cf09`)* Two joints can overlap inside a short middle clip:**
`fittedJoint` (`ClipTransition.swift:575–577`) subtracts only the clip's
own way out, not the next joint's lead. *Next:* subtract both
neighbors' shares; a widening test.

**F102 — *(fixed in `8b6ab67d`)* A joint slip can leave the transition without footage**
(`ClipTransition.swift:649`, `slipClip` bounded only by the file).
*Next:* refit after the slip, as `rollCut` does.

**F103 — *(fixed in `5d8e870a`)* A joint is drawn beside a disabled clip** that export plays as
a gap (`LayerClipRow.swift:293,402`). *Next:* leave disabled clips out
of the drawn joint.

**F105 — Blend and Optical Flow on slowed clips mix in the frame after
the trim** (`CompositionFlattening.swift:263–264`,
`LayeredCompositor.swift:759–781`): at 50% the last frame is half the
next shot's first. *Next:* no blend past the trim's last frame; a
colored next-frame test.

**F106 — Reversed clips show the frame before the one their source time
names:** a reversed piece reads from `sourceTime(b)`, effects are
evaluated at `sourceTime(a)` (`CompositionFlattening.swift:503–510`,
`ClipStack.swift:95–96`), so keyframes sit a frame off after Reverse and
Blend steps back and forth. No rule is written for which timeline frame
a repeated source frame maps back to; forward clips give the first.
*Next:* decide and document one convention, evaluate at the frame shown;
scene-following splits of reversed clips (F100) follow it.

**F107 — *(fixed in `a7a486de`)* Export doesn't wait for running expressions** or Audio Keys
still reading: nothing in `Export/` checks `waitingExpressions()` or
`keyframingFreshness`, so an export started at once has the old values.
*Next:* wait, or refuse with a note.

**F108 — Beat Keys is rewritten flat before beats load**
(`Keyframing.swift:465–470,610,637`; Audio Keys has the guard,
`:621–631`), into the undo step and the autosave (suspected). With F37,
which open project's detected beats win is arbitrary. *Next:* treat
beats not yet loaded as Audio Keys treats sound not yet read.

**F109 — Speeds below 3.125% or above 3200%** are outside the documented
time-pitch range (1/32 to 32) and untried in playback and export
(`CompositionFlattening.swift:244`). *Next:* try 1%, 2%, 5000% and
10,000%; mute or clamp outside, and document it.

**F110 — *(fixed in `8d7f131a`, `10bba6bd`)* Detected beats are about 10 ms early:** reported at the
analysis window's center (`BeatDetection.swift:201–202`,
`OnsetAnalyzer.swift:14–16`) while spectral flux peaks before the hit;
on a copy of the analyzer, clicks came 3.4 to 14.2 ms early (median
10.3). Rounded to frames, about a quarter of beats land a frame early at
24 fps and over half at 60. `BeatFitting` already corrects its own lead
(`onsetLead`); `BeatDetectorTests` allows 50 ms. *Next:* measure the lead
at hop 256 as `onsetLead` was, correct it, and test a click file to
under 3 ms. *Fixed:* measured on the detector itself first (median
9.0 ms early, 3 to 14.7); each beat is now the onset curve's peak by
parabola between frames, moved 180 samples later, which leaves click
tracks at 100, 120 and 150 BPM within ±2 ms (the lead was set on the 120
BPM ones). The tracker's tempo, from whole frames, is unchanged. The
beat analysis's algorithm version is 6, so saved beats are detected
again; confirmed beat maps aren't touched. *Left:* the lead was measured
on sharp synthetic clicks only, and every project's saved beats are
detected again with it. Softer attacks (pads, bass, vocals) may peak
later relative to the hit, so on real songs some beats could now land
slightly late rather than on time. *Next:* with the licensed songs (D7),
check detected beats against the music by ear, and measure the lead on
softer generated attacks, before cuts snapped to detected beats are
trusted.

**F112 — Held drawings and two-frame flashes give false cuts**
(`SceneDetection.swift:261–271,280–290`): on twos the background median
is half a drawing's change, so each drawing is a peak, a cut every 0.42 s
from a change of 60; a two-frame white flash cuts, since `isFlash`
covers one frame. Shown on the detector's algorithm with made scores,
not on episodes. *Next:* `SceneReviewTests` cases from
`ReviewFixtures`' held and flash pictures; a background over non-zero
scores, and flashes up to three frames.

### From the owner's decisions

**F89 — Remembered script approval trusts a project's ID and path**
(D5). *Expected:* remembered approval covers an exact snapshot of the
code that runs and is asked again when it changes. *Observed:* "Always
Run This Project's Scripts" stores the project's ID and package path
(`CodeApproval.allowedProjects`), and every script later at that path
runs without asking, a `git pull` or synced change included; projects
made on this Mac are allowed that way at creation
(`ProjectSession.swift:170`). The helper imports the script's siblings
from the folder itself after approval, so a file changed between the
check and the import runs unreviewed, and links in the folder are
hashed through to their targets. *Fixed in `5ab4864e`:* approval is of
a `ScriptSnapshot` (the script and every file of its folder, read once;
links and folders over 2,000 files or 64 MB refused; `__pycache__` left
out), whose files are copied to a private folder the helper imports
from; the project allowance is gone; "Remember approval for these
scripts" is a checkbox; the prompt says what scripts can reach and that
modules from outside the folder aren't checked. Tested in Swift and in
the helper's Python tests (the approved copy is imported, not the
changed folder). *Cost, as decided:* the person's own scripts ask again
after every edit. *Left:* F20's residual (the interpreter's `site` and
user site-packages, threads outliving a run).

**F90 — External effect kernels compile without the person's approval**
(D8). *Expected:* an external package's kernels are compiled or run only
after the person approved its exact content. *Observed:* every package
in the library folder, installed from the Finder or changed there, is
compiled in the background as soon as it is found (at launch, on
install, on each live reload: `EffectPackageStatus.compile`), whether or
not a project uses it. Projects don't embed packages today; D8's rule
covers them if they come to. *Fixed in `4c7ab74c`:* `EffectApproval`
keeps the SHA-256 of each approved package's effect.json and kernel;
`PackageKernels` compiles and draws only built-in and approved ones, one
gate for launch, install, reload and render; render keys carry the
approval; the library lists waiting packages with Approve…; opening
from the Finder and adding a waiting effect ask; Shift at launch (or
`disableExternalEffects`) leaves every outside package out. Shown by
a test that a broken kernel reports nothing until approved (it was
never compiled) and something after. *Left:* no Settings button yet to
forget approved packages, as Forget Allowed Code does for Python.

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
The owner decided D3 to D8 on 2026-11-27. They are policies for the
review, not claims that the code meets them; each says what is done.

- **D3. The Python pin is committed.** Decided: yes. The release,
  artifact and SHA-256 are in the repository; release packaging fails
  without the pin or the bundled Python (Python-free development builds
  only through an explicit option); the pin changes in a reviewed commit
  of its own, with the helper's tests on the new Python and its license
  notices checked. *Done* (`96409e50`): `ALLOW_NO_PYTHON=1` is the
  option; the helper's suites (23) and Python tests (53) pass on the
  bundled 3.14.10. The notices of the libraries built into CPython are
  still F61.
- **D4. CI's actions pinned by commit.** Decided: yes, every external
  action by full SHA with its release in a comment, updates proposed by
  Dependabot. *Done* (`7b323e77`). A pinned commit fixes which revision
  runs; it doesn't establish that the revision is safe.
- **D5. Remembered script approval trusts reviewed content, not future
  changes.** Decided: a project's ID and path never authorize changed
  code. Approval is remembered locally for an exact snapshot (the
  executable content, its dependencies as far as they can be bounded,
  and file names) and asked again when that content changes, inside the
  app or outside it; opening a project never runs an unrestricted
  script, and remembered approval only spares the prompt when the person
  runs unchanged code; links and imports outside the snapshot are
  refused or accounted for; the approved snapshot is what runs, not files
  read again after approval. The option becomes "Remember approval for
  these scripts", and the prompt says plainly that unrestricted scripts
  can reach files and the network with the person's permissions, and,
  where dependencies can't be bounded, that not every line run was
  reviewed. *Done* (`5ab4864e`, F89).
- **D6. App Sandbox deferred for the first release.** Decided: defer,
  kept as a separate security project and not a prerequisite for this
  review. *Release gates in its place,* before any public distribution:
  Developer ID signing, the hardened runtime and notarization; helper
  confinement validated on the signed app; confined expressions failing
  closed where confinement is unavailable; the release-blocking parser,
  file-system, approval and helper-protocol findings closed; and the
  documentation saying approved unrestricted scripts run with the
  person's permissions. These are not equivalent to the App Sandbox.
  *Residual risk accepted by the owner:* media handed to system
  frameworks (AVFoundation, VideoToolbox, ImageIO) is parsed with the
  person's full access; package kernels are compiled and run on the GPU;
  the app's own file operations reach anything the person can; approved
  scripts run unconfined by design. *Revisit* before a Mac App Store
  release or a significant growth in plugins or executable content.
  *Gates already met:* confined expressions fail closed, as an
  expressions helper refuses to start without `sandbox-exec`
  (`PythonHelper.swift`, `HelperConnection.init`); the scripting doc
  says approved scripts run with the person's permissions. *Open:*
  Developer ID signing, hardened runtime and notarization (phase 12),
  and confinement validated on the signed app.
- **D7. Licensed footage before the qualitative checks.** Decided:
  synthetic fixtures now (checkpoint D, done), never blocking the
  persistence, timing or security review; representative footage and
  music, with suitable permissions, acquired before phase 7's visual
  check and phase 8's listening check, and reused for phase 9's
  measurements and phase 10's hands-on editing. Each item's provenance
  and permitted uses are recorded; permission to test with it isn't
  permission to put it in fixtures, screenshots or sample projects. It
  covers line art, held animation, flashes, gradients, subtitles,
  long-GOP decoding and representative music. The synthetic fixtures
  stay the correctness oracle; real footage supplements them.
- **D8. Third-party effect packages approved before a kernel runs.**
  Decided: yes. An external package is executable GPU code, not a
  preset. Before its first compilation or run the app shows its name,
  where it came from when known, and whether it is built in or
  external, and says a faulty or malicious kernel may stall graphics or
  destabilize the app. Approval is remembered for the package's exact
  executable content and asked again when that changes, for packages
  installed from Finder, embedded in projects, live-reloaded, or found
  in the library folder alike; unapproved packages are listed without
  being compiled for thumbnails or previews; a recovery launch turns
  external effects off. The warning supplements validation and resource
  limits, and no GPU time limit is promised that the code can't enforce
  (F53). *Done* (`4c7ab74c`, F90), but for a Settings button to forget
  approved packages.

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

### Phase 5 (at `49447f74`)

Four read-only reviews side by side: the frame grid and seeking; edits
and transitions; retiming, keyframes and expressions; and scenes, beats
and sync. Probes were copies of the code's arithmetic and small
AVFoundation programs outside the repository. What held: frame rounding
in placement (`frameAligned`, exact at NTSC rates); Matroska timing
(B-frames, timestamp scales, AAC priming); the rough-then-exact seek
and viewer copies' frame times; beat maps computed from anchors, not
summed; song time to timeline time through retiming; Keyframing's
determinism and its refusal of hand edits; transitions' spare footage
for picture and sound alike; and scene detection's fixed defects
(`swift test --filter Scene`, 214 tests, and `BeatFittingGoldenTests`
at 0 samples' error on all four goldens). Not done: the end-to-end
white-frame-and-click export at 24, 29.97 and 60 fps and after ten
minutes; the review sketched it from `ReviewFixtures`'
`writeMovie(.flashes)`, `writeClicks` and an export read back by
`AVAssetReader`, gated behind a variable since it is slow.

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
