# Code review notes

Status: **review notes** for the first pass of
[code-review-plan.md](code-review-plan.md). Phase 1 (scope and build
baseline) is done, apart from the decisions and review projects listed
under "Still open in phase 1"; phases 2 to 12 haven't started. Each
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
   plan's testability item asks.

6. **The binaries record SDK 15.0. (Phases 1 and 12, packaging,
   severity unknown; open.)** `otool -l` shows `LC_BUILD_VERSION` with
   `minos 15.0` and `sdk 15.0` for `.build/debug`, `.build/release` and
   the bundled app, though they are compiled against `MacOSX27.2.sdk`
   (Xcode's own binary records `sdk 27.2`). AppKit and SwiftUI choose
   some behavior by the SDK an app was linked against, so the app may
   get older behavior than the SDK it is written for; CI notes the
   viewer needs the macOS 26 SDK. Find where the SwiftPM build (Swift
   Build, `.build/out`) sets the linker's SDK version, then decide
   whether it matters.

7. **A build from a clean checkout has no Python. (Phase 3, packaging,
   decision; open.)** `scripts/build-app.sh` in this checkout warned
   "built without a Python of its own": `scripts/python-pin` is
   git-ignored and wasn't there, though the main checkout has one. This
   is the reproducibility question phase 3 already asks, now seen.

### Still open in phase 1

These need the person who owns the project, not more running:

- **Is macOS 15 supported?** The minimum is 15.0 (and `minos 15.0` in
  the binary), but nothing here can run macOS 15 and CI runs only on
  macOS 27. The only availability check is `#available(macOS 26.0, *)`
  in `UI/Viewer/PlayerLayerView.swift:89` (the viewer's high dynamic
  range). Either test on macOS 15 in phase 12 or raise
  `.macOS(.v15)` and `LSMinimumSystemVersion` together.
- **Which hardware?** The bundle is arm64 only. Without a Metal device
  `MetalDevice.shared` is nil and four contexts fall back to the CPU
  (`LayeredCompositor.swift:160`, `ClipPictureCache.swift:128`,
  `StillImages.swift:62`, `FrameRedrawer.swift:94`); support that or
  refuse to run.
- **Review projects.** None assembled: they need footage and music the
  project holds the rights to, at a fixed path outside the repository.
  Until then `UIResponsivenessBenchmark` runs without `AMV_PROJECT`.
