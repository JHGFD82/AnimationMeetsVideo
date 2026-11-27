# Code review notes

Status: **review notes** for the first pass of
[code-review-plan.md](code-review-plan.md). Phases 1 (scope and build
baseline), 2 (architecture and maintainability) and 3 (security,
privacy and dependencies) are done, with their open findings and the
decisions still wanted listed; phase 1 still lacks its review
projects. Phases 4 to 12 haven't started. Each
finding gives its phase, area, severity from the plan's
[triage order](code-review-plan.md#triage-order), place, how to see it,
and whether it was already failing at the baseline. Fixes are marked
with their commits.

## Phase 1: Scope and build baseline

Baseline commit `4387fb11` (Merge the code review plan), 2026-11-26.

### The reviewing Mac and toolchain

| | |
| --- | --- |
| Mac | MacBook Pro (Mac16,8), Apple M4 Pro, 10 performance and 4 efficiency cores, 24 GB |
| macOS | 26.7.3 (25G342) |
| Xcode | 27.2 (27B52), as CI pins; macOS SDK 27.2 |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| Python | Homebrew 3.15.2 for `AMV_PYTHON`; the system's 3.9.6 is older than the helper's 3.11 minimum |

### The project at a glance, checked

Every row of the plan's table still holds: macOS 15.0 minimum in
`Package.swift` and `Info.plist`, ad hoc signing with no entitlements or
hardened runtime, arm64 only, no `URLSession` or `Network`, 531 Swift
source files and 295 test files, the source and test counts per area in
phase 11's table. Two counts elsewhere in the plan need correcting:

- **Effect packages:** `Resources/Effects/` holds 78 folders: the 77
  looks that ship and the hidden `.template.amveffect` that new
  packages are made from (`EffectPackageStore.templateName`).
- **`print` calls:** none in Swift. The plan's phase 3 says 14; the
  only two textual matches are inside Python source strings
  (`ScriptLibrary.swift:111`, `PythonRuntime.swift:85`). The 22 `NSLog`
  and 279 `try?` are as stated, and so are phase 6's 43
  `@unchecked Sendable`, 26 `nonisolated(unsafe)`, 15 `Task.detached`
  and 2 `DispatchQueue.global`.

### Builds

| Build | Result | Time (wall) |
| --- | --- | --- |
| `swift build`, clean | Passed | 26 s |
| `swift build -c release`, clean | Passed | 2 min 23 s |
| `swift build -c release -Xswiftc -enable-testing --build-tests` | Passed | 6 min 6 s |
| `scripts/build-app.sh` (release) | Passed; 43 MB bundle, arm64, ad hoc signature verifies with `codesign --verify --deep --strict` | 2 min 21 s |
| `CONFIGURATION=debug scripts/build-app.sh` | Passed | 3 s (already built) |

`Packaging/Info.plist` passes `plutil -lint`, and its three exported
types match `ProjectStore.packageTypeIdentifier`,
`EffectPackageStore.packageTypeIdentifier` and
`ProjectBackups.typeIdentifier`. All three are declared as packages,
which `.amvbackup` is (a folder, `ProjectBackups`).

### Compiler warnings

The same seven in debug and release, with none from `sandbox-exec`
(it is started as a program, not called as an API):

| Kind | Where | Verdict |
| --- | --- | --- |
| Optional interpolated into text | `UI/Effects/EffectsPanelEffects.swift:329` | A defect, now fixed (finding 3) |
| Deprecated synchronous `tracks(withMediaType:)` and `formatDescriptions` | `Rendering/Compositor/WaveformAudio.swift:80`, `:81` | Open. Blocking asset loads on a global queue; phase 6 should move them to `load(_:)` |
| `weak` capture differs from implicit strong capture (×3) | `UI/Editor/TimelineEditorSurface.swift:445` | Not a leak: the outer closure is `onAppear`'s, held by SwiftUI, and `onDisappear` clears `drawWithPen`. Worth silencing |
| `var` never mutated | `Rendering/Compositor/WaveformDrawing.swift:248` | Cosmetic |

The test target adds ten "result unused" warnings in
`Tests/.../Rendering/KeyingTests.swift` (388 to 477): `masked(_:)`
returns the clip's ID, which those tests don't need; they check pixels,
so nothing is left unchecked. It wants `@discardableResult`.

At run time CoreMedia logs ten "error introduced due to very low
timescale" warnings per run. They come from `SceneBoundaryTests`
(`SceneReviewTests.swift:261`), which makes manual cuts at timescale 24
from random seconds on purpose; they aren't from the app.

### Tests

- **As CI runs them**, three times
  (`swift test --experimental-maximum-parallelization-width 8`): 2,716
  tests in 404 suites passed each time, in 41.5, 41.7 and 43.4 s; 211
  tests skipped, all in gated suites. None of the three load-sensitive
  audio tests in [loose-ends.md](loose-ends.md) (`ScrubAudioTests`,
  `DetachAudioTests`, `LoudnessMasteringTests`) failed, here or in the
  two full runs with `UI_EVENTS`.
- **`AMV_PYTHON`** (`PythonHelper|Confinement`): 20 tests in 3 suites
  passed. The helper's Python tests: 52 passed on 3.15; on the system's
  3.9 they fail with `Unknown option: -P`, as expected below the 3.11
  minimum that `PythonRuntime.oldestVersion` enforces in the app.
- **`SNAPSHOT_DIR`**: 100 tests passed and wrote 143 pictures (kept for
  phase 10, not looked at yet).
- **`UI_EVENTS`**: failed at the baseline in two ways, findings 1 and
  2. After their fixes the event suites by filter
  (`InteractionTests|FieldTextSelectionTests|TextEditEnding`) pass: 89
  tests in 11 suites, 50 s. The whole suite with `UI_EVENTS` passed once
  (2,716 tests, 77 s) and hung once (finding 4).

### Benchmarks (release)

The baseline for phase 9, on the Mac above, plugged in.

**`RenderThroughputBenchmark`** (16 s of 1080p at 24 fps, three runs):

| Workload | How | Fastest s | Median s | fps | First piece s |
| --- | --- | --- | --- | --- | --- |
| blur | 1 at once | 2.27 | 2.28 | 169.0 | 0.56 |
| blur | 2 at once | 2.13 | 2.21 | 180.5 | 1.09 |
| blur | 3 at once | 2.26 | 2.27 | 170.1 | 1.70 |
| blur | export, no cache | 1.95 | 1.98 | 196.8 | |
| motion | 1 at once | 6.96 | 7.03 | 55.1 | 2.01 |
| motion | 2 at once | 6.17 | 6.30 | 62.2 | 3.45 |
| motion | 3 at once | 6.41 | 6.50 | 59.9 | 4.95 |
| motion | export, no cache | 6.43 | 6.44 | 59.8 | |

**`EdgeTransitionsBenchmark`** (300 frames, 60 of them a cube):
`effect(at:)` 14.9 ns a frame, `transitionFrame(at:)` 110.3 ns a frame,
`TransitionFrame.key` 255.9 ns a key.

**`UIResponsivenessBenchmark`** (ms a step on the main thread, 85
steps; without `AMV_PROJECT`, since there are no review projects yet):

| Scenario | Median | p90 | Max |
| --- | --- | --- | --- |
| shape-size | 0.6 | 0.8 | 0.9 |
| color-exposure | 1.5 | 1.9 | 2.4 |
| transform-position | 1.4 | 1.7 | 2.2 |
| keyframed-scale | 3.1 | 3.4 | 3.7 |
| wave-height | 1.6 | 2.0 | 2.7 |
| kaleidoscope-angle | 1.6 | 2.1 | 2.5 |
| feedback-scale | 2.5 | 4.6 | 6.2 |
| volume | 0.2 | 0.3 | 0.9 |
| step-frame | 4.2 | 6.5 | 15.3 |
| step-ten-frames | 8.3 | 8.9 | 11.2 |
| step-frame-library | 8.3 | 8.8 | 9.9 |
| step-frame-no-panel | 4.6 | 6.6 | 8.0 |
| step-frame-inspector | 5.5 | 6.3 | 8.0 |
| nudge-clip | 46.7 | 51.5 | 57.3 |
| zoom | 15.9 | 17.1 | 19.4 |
| busy-zoom | 61.8 | 63.1 | 66.5 |
| busy-zoomed-in-zoom | 100.8 | 108.4 | 153.1 |
| busy-zoomed-in-step-frame | 5.4 | 10.6 | 72.0 |
| busy-zoomed-in-nudge-clip | 32.4 | 36.7 | 38.5 |
| busy-step-frame | 5.3 | 5.6 | 11.6 |
| busy-nudge-clip | 31.4 | 35.9 | 37.9 |
| long-zoom | 10.9 | 11.2 | 11.4 |
| long-zoomed-in-zoom | 9.1 | 11.7 | 12.5 |
| long-nudge-clip | 24.4 | 27.5 | 28.7 |

Value drags stay far inside a frame. Zooming a busy timeline (62 ms,
and 101 ms zoomed in) and nudging a clip (24 to 47 ms) take several
frames a step, and stepping a frame zoomed in on a busy timeline
stalled every twelfth step (37 to 72 ms against a 5.4 ms median). These
are phase 9's first suspects.

### Findings

1. **The loop region's end edge couldn't be taken. (Phase 1, `UI/`,
   severity 5; failing at the baseline; fixed in `4d9e6481`.)**
   `UI/Components/LoopBar.swift:177`. The edge handles straddle the
   chip's ends, but the region's content shape was the chip's own
   rectangle, and a content shape limits hits for everything inside it.
   The outer half of each handle was dead, and a press exactly on the
   end edge reached nothing: no select, no resize. Only a 3-point strip
   just inside the end could be grabbed. Seen as
   `LoopBarInteractionTests` failing `aClickSelectsAndADragMoves` (84)
   and `anEdgeDragResizesAndSnaps` (101) on every run with
   `UI_EVENTS=1`; the suite was added with that failure and its runs
   were hidden by finding 2. The content shape now reaches half a handle
   past each end, sideways only; the suite passes.

2. **Event runs ended early and reported success. (Phase 1, tests,
   severity 2 for the harness; failing at the baseline; fixed in
   `85a49bec`.)**
   `KeyframeDesignerInteractionTests.spaceLeavesFocusedButtonsAloneButPlaysFromTheGraph`
   presses Space on a focused `NSButton`. The button's click flash runs
   a nested event loop that leaves a `CFRunLoopStop` behind; when it
   landed on the main run loop, which Swift Testing's main actor runs
   on, `CFRunLoopRun` returned and the process called `exit(0)` without
   a summary. `UI_EVENTS=1 swift test`, and the event suites by filter,
   stopped right after that suite: tests still waiting for the event
   lock never ran, and failures already printed (finding 1) still left
   the exit status 0. Traced in `lldb` with breakpoints on
   `CFRunLoopStop` and `exit`. The button now has a cell that counts the
   click instead of flashing, which also checks that Space reached it.

3. **Convert to Path's refusal said "nil". (Phase 1, `UI/`, severity 5;
   at the baseline; fixed in `98a9a862`.)**
   `UI/Effects/EffectsPanelEffects.swift:329` interpolated
   `Effect.name`, which is nil until the effect is renamed: the notice
   read "“nil” has no size at the playhead", or
   "“Optional("Rect 2")”…" once renamed. It uses `displayName` now. No
   test: the text is built inside a menu button's action.

4. **The whole suite with `UI_EVENTS` can hang. (Phases 6 and 11,
   tests, severity 2; open; hidden at the baseline by finding 2.)**
   One of two full runs after the fixes stopped finishing tests about
   31 s in and was still stuck 15 minutes later. Five event tests, one
   from each of five suites, were waiting on the event lock (so one of
   them held it and never finished), and
   `WaveformTests.theSpectrogramShadesItsCellsAndIsEmptyInSilence`, a
   synchronous test off the main actor, never finished either. Two
   `RenderCacheTests` timed out waiting for a render alongside. The
   event suites by filter and the suite without `UI_EVENTS` never hung.
   AGENTS.md's "`UI_EVENTS=1 swift test` runs them all at once" is
   therefore not yet reliable; run the event suites by filter until this
   is found. A lead, not a diagnosis: the spectrogram reads sound through
   `WaveformAudio`, whose synchronous asset loads are deprecated (see
   the warnings above).

5. **Tests that fail when the Mac is busy. (Phases 6 and 11, tests,
   severity 5; open; at the baseline.)**
   `ScrubCacheTests.aFastDragOverKeptFramesShowsThemAndLandsExactly`
   (`currentTime < 1.6` at 49) paces its seeks with 10 ms
   `Task.sleep`s on the main actor and expects the scrub cache to take
   them for a fast drag; a busy main actor or Mac stretches the sleeps
   and the player seeks. It passed in the three runs above and five
   times alone, then failed in four of four full runs later in the day,
   with the load average near 6 from other work on the Mac. Two of
   those runs were on the baseline's sources, so the fixes aren't the
   cause; one of them also failed
   `ViewerFramingRedrawTests.thePictureFollowsAScrollAtOnce` (66). In
   one full run with `UI_EVENTS`,
   `ClipBlockInteractionTests.aClickSelectsWithTheArrowAndCutsWithTheBlade`
   (`calls.selects == 1` at 99 and 107) failed once too. The scrub
   cache's pace wants a clock the test controls (`ManualClock`), as the
   plan's testability item asks. *The scrub cache test is fixed:
   `PlaybackModel` paces scrubbing on a `PaceClock`, the continuous
   clock in the app and a `ManualClock` in the test, which then passed
   in a full run with the load average near 14, after failing the
   project's pre-commit hook twice at 6. The other two remain open,
   with the `PlaybackSkimTests` that pace on real time.*

6. **The binaries record SDK 15.0. (Phases 1 and 12, packaging,
   severity unknown; open.)** `otool -l` shows `LC_BUILD_VERSION` with
   `minos 15.0` and `sdk 15.0` for `.build/debug`, `.build/release` and
   the bundled app, though they are compiled against `MacOSX27.2.sdk`
   (Xcode's own binary records `sdk 27.2`). AppKit and SwiftUI choose
   some behavior by the SDK an app was linked against, so the app may
   get older behavior than the SDK it is written for; CI notes the
   viewer needs the macOS 26 SDK. Find where the SwiftPM build (Swift
   Build, `.build/out`) sets the linker's SDK version, then decide
   whether it matters. *Since the minimum became 26.0 the binaries
   record `minos 26.0` and `sdk 26.0`: the build writes the deployment
   target as the SDK version. Behavior chosen by "linked on or after
   macOS 26" is now had; behavior new in 27 still wouldn't be.*

7. **A build from a clean checkout has no Python. (Phase 3, packaging,
   decision; open.)** `scripts/build-app.sh` in this checkout warned
   "built without a Python of its own": `scripts/python-pin` is
   git-ignored and wasn't there, though the main checkout has one. This
   is the reproducibility question phase 3 already asks, now seen.

### Decided, and still open, in phase 1

- **macOS 26 (Tahoe) and later**, decided by the project's owner.
  `Package.swift` says `.macOS("26.0")` (the tools-6.0 manifest has no
  `.v26`) and `LSMinimumSystemVersion` is 26.0; the one availability
  check went. Raising the target brings eleven macOS 26 deprecation
  warnings: nine for `AVMutableVideoComposition` (in
  `ComposedTimeline`, `CompositionPlanning`, `PlayheadPrerenderer`),
  which wants moving to `AVVideoComposition.Configuration`, open; and
  `Text` joined with `+` and `wantsExtendedDynamicRangeContent`, both
  replaced. `BrowserPanel.swift:118` now drops the result of a Finder
  drop, as SwiftUI picks another `dropDestination` overload; dropped
  files still import.
- **Apple silicon only**, decided by the owner. `scripts/build-app.sh`
  builds with `--arch arm64` whatever Mac runs it and stops unless
  `lipo` shows arm64 alone. Every Apple silicon Mac has Metal, so the
  CPU fallback when `MetalDevice.shared` is nil
  (`LayeredCompositor.swift:160` and three more) is no longer a
  supported path; it is left in place, harmless, rather than made a
  crash for virtual machines without a GPU.
- **Review projects.** Still none: they need footage and music the
  project holds the rights to, at a fixed path outside the repository.
  Until then `UIResponsivenessBenchmark` runs without `AMV_PROJECT`.

## Phase 2: Architecture and maintainability

Baseline: the phase 1 branch at `ad3c3dc0`. Six read-only reviews ran
side by side, one per group of the plan's items: the edit's one source
of truth and shared state, preview against export, the mix, logic in
`UI/` and oversized files, errors and testability, and the docs. Every
finding fixed below was checked against the code before it was fixed,
and each fix has a regression test unless it says otherwise. Open
findings say **verified** where the code path was read again here, and
**reported** where only the review read it.

### Fixed

8. **A failed export lost the file it was replacing. (Phase 2,
   `Export/`, severity 1; fixed in `35d82288`.)** The movie and WAV Mix
   exports deleted the destination before they began
   (`CompositionExporter.swift:454`, `AudioExport.swift:97`), and stems
   deleted each old stem before writing it, so an export that failed
   or was stopped left nothing where the confirmed Replace had been.
   Each now writes to a hidden file beside the destination
   (`Export/ExportFile.swift`) and swaps it in only once it is whole.
   Tests stop a mix and a stems export halfway over earlier ones.

9. **A take that couldn't be copied into the project was deleted.
   (Phase 2, `Recording/`, severity 1; fixed in `f2de65a3`.)**
   `AudioRecorder.keep` removed the take in a `defer` whether or not
   the copy succeeded, so a full disk or an unwritable package lost the
   only copy of a recording. It is now kept in the Recordings folder an
   unsaved project uses, and the error names it.

10. **An outside edit was marked seen while the Motion Designer refused
    it. (Phase 2, `App/`, severity 1; fixed in `d95d143a`.)** A
    `project.json` changed outside the app that touched clips the
    Motion Designer locks was refused by `writeRestored`, yet the
    session took the file as saved and acknowledged it
    (`ProjectSession.swift:509–511`); the next save wrote over the
    edit. It now waits, unacknowledged, until the locks are gone.

11. **Stale background renders for effect inputs. (Phase 2, `Export/`
    and `Rendering/`, severity 3; fixed in `7452ceb5`.)** The render
    key never read `DrawClip.inputs`, so changing a Matte's or package
    look's input (its offset, its file, or a clip inside a nested
    timeline taken as one) reused the old render in the viewer and in
    ProRes 422 exports, while ProRes 4444 drew the new picture. The key
    now names the input's file, stamp and played stretches, or
    describes the nested timeline. The test fails all three ways
    without the fix.

12. **The Waveform and Audio Keys heard silenced clips. (Phase 2,
    `Model/`, severity 3; fixed in `b023f30b`.)** Both chose clips by
    `playsAudio` alone, hearing clips with their sound muted, retimed to
    Sound Mute, or reversed; Audio Keys also heard turned-off clips.
    One check, `EditingProject.soundIsHeard`, now states the mix's rule.

13. **Beat match played different sound from the timeline. (Phase 2,
    `UI/BeatMatch`, severity 3; fixed in `b8aa816e`, no test.)** The
    panel's player mixed every enabled sound track, while its waveform,
    the timeline and export use only the first; on a file with two
    languages, beats were confirmed against sound never played. It
    plays the first track now.

14. **Status lines behind the code. (Phase 2, docs; fixed in
    `14b20a60`.)** Viewer handles, the loop region, bar colors and
    Python scripting's later steps still said they had never been
    compiled; graphic layers, gradients and parameter rows listed built
    work as planned; the index left out Path Mask and Expression; the
    Waveform claimed to hear each clip "as heard".

### Open: data and edits (severity 1)

- **Beat match's Confirm writes over a beat map changed meanwhile.**
  Reported. `BeatMatchController.swift:85–93` writes the draft without
  comparing the song's current `beatMap` with the one the panel opened
  on; a script, a reload or another timeline window of the project can
  change it in between. Undo brings it back.
- **A viewer handle drag puts back the clip as it was at its start.**
  Reported, a narrow window. `ViewerHandlesOverlay.swift:839` commits
  the whole clip from drag start; a script finishing during the held
  drag (`ScriptRunner.swift:159` sees no `editCount` change while
  writes are held) has its change to that clip undone on release.
- **Volumes without `flock` open unlocked, and only `NSLog` says so.**
  Reported. `ProjectLock.swift:42`. Two Macs on a share can both save
  the same project; `trashPackage(checkingLock:)` can trash one open
  elsewhere.
- **Provenance rewritten from nothing after a failed read.** Reported.
  `ProjectStore+Provenance.swift:18–46`: `readProvenance` returns `[:]`
  on any failure and the next record writes only the new kind, which
  can drop `.originalScores` for good.
- **Backups ordered by name, not date.** Reported, rare. Names carry
  local time without an offset, so in the hour repeated when clocks go
  back `unsavedBackup` can offer an older autosave and pruning can
  delete newer ones (`ProjectStore+Backups.swift:27–43`,
  `ProjectBackups.swift:127–139`).

### Open: timing, sync and export (severity 3)

- **Volume and effect keyframes drift on speed-ramped clips.**
  Verified. `CompositionFlattening.swift:76–83` gives a clip's mix
  stage the speed at its in point, so on a ramp keyframes are heard
  late, in playback and export alike, while the volume line shows them
  in place. Fixing it means the mix following the clip's time map.
- **The Waveform builds its own mix.** Reported, partly verified.
  `WaveformAudio` sums volumes and runs EQs but leaves out pan, fades
  and crossfades, the Compressor, Limiter and Voice Isolation, and Keep
  Pitch, and indexes samples from the track's first rather than its
  start time, so a late-starting track draws early. Now said in
  [waveform-effect.md](waveform-effect.md).
- **A typed value edit while paused leaves rendered stretches stale.**
  Reported. `PlaybackModel.showValues` (`:304`) returns once the paused
  frame redraws, so other stretches keep playing renders with the old
  value until the next structural edit; export is right.
- **A mono clip's pan is dropped silently** when its stereo copy can't
  be made (`CompositionExporter.swift:150–156`,
  `StereoProxies.swift:126`). Reported.
- **A stale Matroska reference movie is used** when remaking it fails
  (`MatroskaMedia.swift:48`). Reported, suspected.
- **The Python console edits the wrong project** with a Timeline window
  in front: `ScriptConsole.swift:67–72` matches only project windows
  and falls back to the first session. Reported.
- **A render stretch may start between frames**
  (`SegmentRenderer.swift:26`), showing content a fraction of a frame
  early. Reported, suspected.
- **Open projects can share IDs** (Save As keeps them all), while
  `DetectedBeats`, `TimelinePreviews`, `EqualizerSpectrum` and
  `ExpressionRunner.running` key app-wide tables by them. Reported.

### Open: performance and usability (severity 4 to 5)

- `TimelinePreviews.shared` is one table for every project: an edit in
  one drops the other's previews (`TimelinePreview.swift:141–229`).
- Browser skim and effect thumbnails draw as export does, Optical Flow
  and full motion blur included (`TimelinePreview.swift:40`,
  `EffectThumbnails.swift:103`).
- Tape scrub restarts the sound effects every 2 s piece
  (`TapeScrub.swift:193–198`). Suspected.
- Beat-marker choices are per-project data kept in app-wide defaults
  (`TimelineView.swift:113`).
- Closing any editor window ends the bar color panel
  (`EditorView.swift:238`); a refusal shows in whichever window is key.
- Failures nobody hears: cut matching in `MediaReplacer.swift:127`, a
  failed waveform or spectrogram read cached as empty
  (`Waveform.swift:174`, `Spectrogram.swift:254`), folders skipped in
  Save As, presets marked installed when writing failed
  (`PresetStore.swift:89`), `BlankFrame.swift:33`, and
  `EffectFolderWatcher.swift:44` turning live reload off.

### Open: testability

- `PlaybackModel` paces scrubbing on `CACurrentMediaTime` and real
  sleeps (`:692`, `:699`, `:773`) though `ScrubPacing` takes `now`: the
  cause of finding 5. The same pattern is in three `PlaybackSkimTests`.
  It wants a clock, as `ViewerPipeline` takes.
- `ScrubCache.swift:150` and `RenderScheduler.swift:246–250` read Low
  Power Mode and thermal state directly, so their tests time out on a
  laptop in Low Power Mode.
- Gesture-driven views without an `EventHarness` suite: `TimelineRuler`,
  `BeatMatchWaveform`, `ToneGraph`, `EqualizerGraph`, the keyframe,
  section and volume lanes, the transition curve editor, the gradient
  editor, `NumericField` scrubbing, the tape scrubber and the scene
  splitter, among others; `ViewerHandlesOverlay` and `KeyframeGraphView`
  are covered only in part.

### Open: structure (severity 5 to 6)

- Logic in `UI/` that wants a home outside it: the export queue and its
  format dispatch (`UI/Export/ExportWindow.swift`, which `App/` relies
  on for quitting); change detection, folder matching and replacement in
  `MediaReplacementController` (a third "file changed" check beside
  `ProjectStore+Load.swift:41` and `AssetAnalysis.changedFiles`);
  media import in `MediaImportFlow`, untested and bypassed by
  recordings; `TimelineEditorSurface.handle(_:)`, untested.
- Files with more than one job: `Keyframing.swift` (editing, signal
  math, Strobe Keys), `AssetAnalysis.swift` (runner and results
  store), `EffectPackageStore.swift` (`EffectPackageStatus` apart),
  `ClipTransition.swift` (render-time evaluation apart),
  `BeatMatchSession.swift` (transport apart) and, mildly,
  `LayeredCompositor.swift` and `Effects.swift`. `ProjectFile`,
  `BeatFitting`, `ViewerHandlesOverlay`, `MotionDesignLanes` and
  `ClipBlockView` each have one.
- [loose-ends.md](loose-ends.md): every item is still true, but the
  Motion Designer's locks are now shown in the Timeline menu's Split,
  Nudge and Delete; the keys, lanes, browser and drops still only
  refuse.

## Phase 3: Security, privacy and dependencies

Baseline: `c23427a8`. Three read-only reviews (the Matroska parser and
binary reference data; project and effect packages; Python
confinement, code approval and recording permissions) and checks of
logging, network and dependencies made here. Each fix was checked
against the code first; most have a test that fails without the fix
(said where it was shown).

### Fixed

15. **Logged names were read as format strings. (Severity 2; fixed in
    `e1d78893`.)** Thirteen `NSLog` calls interpolated error text,
    package paths and package names into the format. A name with `%@`
    logged "(null)", and a project folder named with twelve crashed a
    probe with a bus error. Each now logs `"%@"` with the text as its
    argument.

16. **Matroska files that crash, hang or overrun the index. (Severity 2;
    fixed in `1fd07353`.)** EBML lacing sizes running past their block
    trapped (a crash from a few bytes); children were bounded by the
    file, not their parent, so a track's codec data could take in the
    rest of the file per track; fixed lacing over nothing made 256
    frames; a million tracks with a linear lookup hung past
    cancelling; a timestamp scale of 0 was taken; and a PCM block of
    part of a sample, or a bit depth like 0x7FFFFFF8, pointed samples
    past the file. Each is refused or not indexed, and a sweep cuts a
    small laced file at every length and sets every byte to 0x00, 0x01
    and 0xFF: it reads or refuses, never traps.

17. **`audio.bin`'s start overflowed. (Severity 2; fixed in
    `ca0cd751`.)** An edited start window of Int64.min trapped working
    out a replacement's offset. Starts beyond 2^40 windows are damage.

18. **An edited viewer-copy index could delete any folder. (Severity 1;
    fixed in `221d4457`.)** `Cache/ViewerCopies/index.json` names the
    copies to delete when unused; a record whose file was `../../..`
    deleted the folder holding the project, on opening, whether copies
    were on or off. Only plain names with times that fit are read; the
    test lost its sibling file without the check.

19. **A cache folder linked out of the package was emptied. (Severity 1;
    fixed in `2305c751`.)** A project arriving with `Cache/References`
    linked to Documents (zip and AirDrop keep links) had Documents
    emptied on load, and a linked `Cache/Renders` would lose `.mov`
    files oldest first. Both clear only a folder that resolves inside
    the package.

20. **An allowed script could import code no one allowed. (Severity 1;
    fixed in `d64fd738`.)** A project script runs with its folder first
    on the import path, but allowing it hashed only its text, so its
    `import util` ran an unseen `util.py`; and the helper kept that
    module for the next script, of any project. Allowing now covers
    the name and hash of every other file in the folder, and the helper
    forgets a script's own modules when it ends.

21. **Expressions could read terminals and the home folder. (Severity
    1; fixed in `ea881d27`.)** The sandbox allowed all of `/dev`, so a
    confined expression could open a Terminal's tty and read what was
    typed, passwords too (shown with a pseudo-terminal; the test fails
    with `/dev` back); and a `~/bin/python3` made the whole home folder
    readable and runnable. `/dev` is gone (the base profile allows what
    Python needs), an installation that is or holds the home folder is
    left out, and the confinement tests now try `os.fork`,
    `posix_spawn` and the interpreter in `subprocess`: all refused.

22. **Repeated IDs crashed the app. (Severity 2; fixed in
    `17eb57a1`.)** Two media files, timelines, layers or sections with
    one ID (read regardless of case) crashed the browser, the timeline
    or the first section edit. A file repeating one is refused, saying
    which; `view-state.json` keeps the first of two clashing keys.

23. **A negative keyframing component trapped (fixed in `1aaeaf0b`),
    and package repeats and delays trapped or hung (fixed in
    `4a8566c8`). (Severity 2.)** A component outside the control's
    range now writes nothing; a look's passes are finite and at most
    256, and a delay too far to keep draws the picture as it is.

### Open: project and package input (severity 2 to 3)

- **Numbers in range of JSON but not of the app** crash on open or on
  the first redraw: a trim of 2×10^17 s overflows in frame alignment
  (`Model/ClipPlacement.swift:25`), a frame width of 10^19 traps in
  `Int(frameSize.width)` (`Model/Timeline.swift:39` and the header),
  a frame rate of 10^19 or a time near 4×10^17 s in timecode
  formatting (`CMTime+Formatting.swift:18`), and a beat position of
  Int64.min (`BeatMap.swift:144`). Reported. Wants range checks after
  the shape check that refuse the file, as the repeated IDs now are.
- **Text runs past the end of their text** trap on the first typed
  letter (`TextRuns.swift:330`; `start` near Int.max overflows at
  `:279`). Reported.
- **A timeline holding clips of itself** loads; rendering refuses it,
  but the Waveform's walk (`WaveformEffect.swift:548`) has no visited
  set and makes N^8 calls. Reported. Cycles want refusing at load.
- **Names made into paths** without cleaning: Duplicate of a package
  whose manifest name is `../../Desktop/x`, Make Package, and backups
  named for the project (`EffectPackageStore.swift:386–425`,
  `ProjectBackups.swift:105–209`). Each only creates and never
  overwrites. Reported.
- **Clips whose source is missing are dropped silently** at load
  (`ProjectStore+Load.swift:85`), so the next save loses them; a
  negative clip length is kept. Reported.
- **A kernel that never ends** stalls the GPU until macOS's watchdog,
  every frame. Nothing limits it; a warning when installing a package
  from Finder may be wanted.
- `audio.bin` with billions of levels asks for memory in proportion
  (`crossCorrelation`); its count must equal its length, so it needs a
  file that large. Damaged reference files are analysed again without
  a message, by design.

### Open: Python (severity 2 to 3)

- **One expressions helper serves every project**, with real builtins,
  so approved code in one can patch the helper's caches or leave a
  thread answering the next run, and another project's different
  approved code then gives its values (`expressions.py:311,340`).
  Reported. Wants a helper per project, or a restart after a run that
  leaves threads.
- **Non-finite expression samples** are counted but not checked in the
  app (`PythonHelper.swift:167–176`); NaN keyframes would then fail
  saving. Reported.
- **Helper messages are buffered without limit** (`ScriptMessages`
  payload sizes up to 9×10^15, `HelperFrameReader.frames` while no run
  reads) and copied per frame. Reported.
- **A script's time as `[n, d]` has no bound** (`ProjectBridge.swift:
  506–515`), unlike one in seconds. Reported.
- **Recording another app with its permission refused** probably gives
  a silent take with no message (`AudioCapture.swift:79–116`).
  Suspected; wants trying with `tccutil reset`.
- Low: confined code can still stat any path (`file-read-metadata`),
  and whether `cfprefsd` refuses it a write is untested.

### Privacy and dependencies

- **Network:** none in the app's sources (no `URLSession`, sockets, web
  views or links); confined expressions are denied it.
- **Logs:** with finding 15 fixed, what is logged is error text and
  file and package names, in the system log. Kept.
- **Python download:** `fetch-python.sh` fetches over HTTPS and checks
  the archive against the pinned SHA-256; `--pin` takes that hash from
  the same release, so the first pin trusts what was offered then.
- **Licenses:** nothing copies the CPython build's license, or those
  of what it bundles (OpenSSL, SQLite, libffi, zlib and the rest),
  into the app. Needed before the app is given to anyone.

### Decisions for the owner

- **Commit `scripts/python-pin`?** It is git-ignored, so a build from
  a clean checkout has no Python (finding 7) and two Macs can bundle
  different ones. Recommended: commit it, for reproducible releases.
- **Pin CI's actions by commit?** `actions/checkout@v4` and
  `actions/upload-artifact@v4` follow their tags. Recommended: pin by
  SHA, since CI only runs by hand and the cost is a line each.
- **"Always Run This Project's Scripts"** trusts whatever arrives at
  the same project ID and path later: a `git pull`, a synced folder or
  a Finder Replace runs without asking (`CodeApproval.swift:114–122`).
  Hashing each script would ask again after every edit in an outside
  editor. Keep as designed, or ask again when a script changed outside
  the app?
- **App Sandbox:** not adopted. Adopting it needs security-scoped
  bookmarks for media referenced in place and on other drives, export
  destinations and the Python interpreter, and a new way to confine the
  helper, as `sandbox-exec` can't run inside the App Sandbox.
  Recommended: not before release; the confinement above covers the
  code the app runs, and the parsers were the open door.
