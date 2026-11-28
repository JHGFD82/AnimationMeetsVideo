# Code review plan

Status: **planned**. A plan for a full review of the app, not a record
of one. The first pass is under way: phases 1 to 3 have been reviewed
(phase 1 only in part, without representative projects) and phases 4
and 5 are being reviewed, with many of their findings still open; where each phase
and finding stands is in [code-review-notes.md](code-review-notes.md),
as "Recording findings" says. A phase being reviewed is not a phase whose
defects are resolved. This document changes only when the plan does.

The review runs in this order: establish a baseline that can be trusted,
review the design and the correctness problems that cost the most, then
measure performance, usability and readiness to release. For an editor of
anime music videos four things deserve the closest attention:

- **Frame accuracy.** A cut lands on the frame the person chose, in the
  viewer, after a save and reopen, and in the export.
- **Beat synchronization.** A cut placed on a beat is still on it after
  trims, retiming, moving the song and exporting. Sound keeps its timing
  to the sample; a cut, which can only fall on a frame, follows the
  documented rounding rule, and the error that leaves is measured.
- **Preview responsiveness.** Scrubbing, stepping and playing heavy
  effect stacks keep up on a laptop, and a parked playhead always shows
  the exact frame.
- **Export fidelity.** What is exported is what the viewer showed at Full
  quality, with the timing, color and sound the project asks for, and not
  merely what the export API reported as a success.

Two more follow from how the app is built:

- **The person's work and footage are safe.** The project is a
  hand-editable package that is autosaved, live-reloaded and locked;
  media files are never modified ([README.md](README.md#shared-principles)).
- **Input from outside is untrusted.** Matroska files are parsed by the
  app's own code, effect packages carry Metal kernels, and Python runs as
  a helper process.

## The project at a glance

Record these at the start of a pass and correct them where they have
changed; phase 1 checks each one.

| Fact | Today | Where it is set |
| --- | --- | --- |
| Minimum macOS | 26.0 (Tahoe), decided in the first pass | `Package.swift` (`.macOS("26.0")`), `LSMinimumSystemVersion` in `Packaging/Info.plist` |
| Toolchain | Xcode 27.2; Swift tools 6.0, so the Swift 6 language mode and complete concurrency checking | `.github/workflows/build.yml` (`DEVELOPER_DIR`), `Package.swift` |
| Build | One SwiftPM executable target; `scripts/build-app.sh` wraps it into `AnimationMeetsVideo.app` | `Package.swift`, `scripts/build-app.sh` |
| Signing | Ad hoc (`codesign --sign -`); no entitlements file, no App Sandbox, no hardened runtime | `scripts/build-app.sh` |
| Architectures | Apple silicon (arm64) only, decided in the first pass | `scripts/build-app.sh` (`--arch arm64`, checked with `lipo`) |
| Network | None: no `URLSession` or `Network` use | `Sources/` |
| Third-party code | No SwiftPM dependencies; a bundled CPython from python-build-standalone, pinned by release and SHA-256 in the committed `scripts/python-pin` | `scripts/fetch-python.sh` |
| Export formats | ProRes 422 (reuses background renders), ProRes 4444 (composites from the sources), WAV Mix, WAV Stems | `Export/AudioExport.swift` (`ExportFormat`) |
| Project format | `.amv` package, `project.json` at `formatVersion` 2, strict loading; no migration of older projects, by design | [project-package.md](project-package.md), `Project/StrictJSON.swift` |
| Time in the model | `CMTime` throughout; frame snapping in integer frame counts (`ClipPlacement.FrameRounding`) | `Model/ClipPlacement.swift` |
| Size | 531 Swift source files, 295 test files, 77 effect packages that ship | `Sources/`, `Tests/`, `Resources/Effects/` |
| CI | Builds and tests only when started by hand; tests capped at eight at a time | `.github/workflows/build.yml` |

## Running the review

### Recording findings

- Give every finding, open or fixed, a stable ID (`F1`, `F2`, …) that
  never changes or is reused, and record:
  - the phase, the area (a source folder from the
    [coverage map](#coverage-map)) and a **category** (data safety,
    security, crash, timing, rendering, sound, export, performance,
    accessibility, usability, test harness, docs, structure);
  - a **severity** from the [triage order](#triage-order), judged by
    impact and kept apart from the category: an accessibility failure
    can block a core workflow, and a harness defect can invalidate the
    evidence a release rests on, so neither is low because of its kind;
  - **expected** and **observed** behavior, the **evidence** and how to
    reproduce it, and `file:line`;
  - **confidence**: *suspected* (a lead), *reported* (one reviewer read
    the code path), *code-verified* (read again and confirmed before
    acting), or *reproduced* (a test, probe or run shows it);
  - **resolution**: *open*, *fixed*, *accepted risk* (with the reason
    and who accepted it) or *decision* (waiting on the owner);
  - **fix verification**: the fix commit, the regression test and
    whether it was shown to fail without the fix, and the commit at
    which the suite passed;
  - **release gate**: *blocking* or *nonblocking*, and the **next
    action** with its owner;
  - whether it was already failing at the baseline.
- Keep each phase's **coverage** (*complete*, *partial* or *blocked*,
  and why) apart from its findings' resolution: a phase can be fully
  reviewed while its defects remain open.
- Keep the findings of a pass in one review-notes document beside this
  one, in the style of [scene-detection-review.md](scene-detection-review.md)
  (what was measured, the defects, the tests that now measure it), or as
  GitHub issues referenced from it. Gaps that are known and accepted go
  in [loose-ends.md](loose-ends.md).
- Fix each defect in its own commit, following AGENTS.md, with a
  regression test where one is practical (phase 11).
- When a fix changes behavior a design document describes, update that
  document and its status line in [README.md](README.md) in the same
  commit.

### What is not a defect

- **Old projects that no longer open.** The project and effect package
  formats change freely and there is no migration code, on purpose. What
  is a defect: a refused project that is written over, a refusal without
  a clear message, or a format change that wasn't noted in its commit.
- **Footage decoded from its own file.** The app never re-encodes media to
  make it editable; viewer copies are disposable caches that export never
  reads ([README.md](README.md#shared-principles)).
- **Scripts that aren't confined.** Only expressions run in the sandbox;
  scripts are allowed to read and write files once the person approves
  their code ([python-scripting.md](python-scripting.md)).

Previously accepted findings, such as the items in loose-ends.md, are
not excluded: they remain tracked, and each pass verifies their scope,
the reason they were accepted, and whether that still holds for the
release.

### Tools

| Tool | Command | Use |
| --- | --- | --- |
| Tests as CI runs them | `swift test --experimental-maximum-parallelization-width 8` | Baseline, every phase |
| UI snapshots | `SNAPSHOT_DIR=<folder> swift test --filter UISnapshots` (or the `snapshot` skill) | Phase 10 |
| Real events | `UI_EVENTS=1 swift test --filter <suite>` | Phases 5, 10 |
| Python | `AMV_PYTHON=<python3> swift test --filter "PythonHelper\|Confinement"`; `python3 -B -m unittest discover -s Tests/AnimationMeetsVideoTests/Scripting/Python` | Phases 3, 6 |
| Benchmarks | `RENDER_BENCHMARK=1`, `UI_BENCHMARK=1` (with `AMV_PROJECT=<project>` for a saved project), `TRANSITION_BENCHMARK=1` | Phases 1, 9 |
| Goldens | `LookReferenceTests` (25 references); `BEAT_GOLDEN_RECORD` and `RECORD_LOOK_REFERENCES` re-record them | Phases 5, 7, 11 |
| Sanitizers | `swift test --sanitize=thread`, `--sanitize=address` on a filtered set | Phases 3, 6 |
| Accessibility | The `accessibility-reviewer` agent over changed views | Phase 10 |
| Instruments | Time Profiler, Hangs, Allocations, Leaks, Metal System Trace, Energy Log, File Activity, on a release build | Phase 9 |
| Media inspection | `afinfo`, `mdls`, AVFoundation in a test, and an independent prober such as `ffprobe` or MediaInfo installed only as a checking tool | Phase 8 |

## 1. Scope and build baseline

- [ ] Record the reviewing Mac (model, chip, memory, macOS version),
      `xcodebuild -version` and `swift --version`, and compare them with
      CI's pinned Xcode 27.2. The workflow notes that Xcode 26's Swift
      rejected code Xcode 27 builds and that the viewer needs the macOS 26
      SDK or later.
- [ ] Decide whether macOS 15 is really supported. The minimum is 15.0,
      but CI runs only on a macOS 27 image and the code has a single
      `#available(macOS 26.0` check. Either test on macOS 15 (phase 12)
      or raise `.macOS(.v15)` and `LSMinimumSystemVersion` together.
- [ ] Decide the supported hardware. Apple silicon is assumed; the
      build is for the building Mac's architecture only. `MetalDevice.shared`
      falls back to a CPU `CIContext` when there is no Metal device;
      decide whether that path is supported or should refuse to run.
- [ ] Build a clean checkout: `swift build`, `swift build -c release`,
      then `scripts/build-app.sh` (and with `CONFIGURATION=debug`).
      Record build time.
- [ ] Count the compiler warnings in a clean debug and release build and
      list each kind. Note deprecated APIs: `sandbox-exec` is deprecated
      and documented as such in `Scripting/HelperConfinement.swift`; any
      others are findings.
- [ ] Run the tests as CI does, three times, and record each failure and
      whether it repeats. loose-ends.md names three that fail only under
      load (`ScrubAudioTests`, `DetachAudioTests`,
      `LoudnessMasteringTests`); record whether they fail here.
- [ ] Run the gated suites once each: `UI_EVENTS=1`, `SNAPSHOT_DIR`,
      `AMV_PYTHON` and the helper's Python tests. Record which can't run
      on the reviewing Mac and why.
- [ ] Run the benchmarks in release and keep the numbers as the baseline
      for phase 9.
- [ ] Lint `Packaging/Info.plist` and check its three type identifiers
      against `ProjectStore.packageTypeIdentifier`,
      `EffectPackageStore.packageTypeIdentifier` and
      `ProjectBackups.typeIdentifier`.
- [ ] Assemble the review projects below at a fixed path outside the
      repository, and set `AMV_PROJECT` to the largest. Never commit
      footage or music you don't hold the rights to. Decided (D7): the
      generated fixtures (checkpoint D) serve until the real footage and
      music, with suitable permissions, arrive before phase 7's visual
      check and phase 8's listening check; record each item's provenance
      and permitted uses, since permission to test with it isn't
      permission to use it in fixtures, screenshots or sample projects.

**Review projects**

| Project | What it exercises |
| --- | --- |
| A 24-minute episode as H.264 in MKV, and the same as HEVC 10-bit in MKV | The Matroska reference movies, long-GOP decoding, AAC priming, scene detection over a full episode |
| SD anime from DVD (720×480, non-square pixels, BT.601, interlaced or telecined) | Pixel aspect, the 601 matrix, field order |
| 23.976, 24, 29.97 and 30 fps sources on 24, 30 and 60 fps timelines | The frame grid, NTSC rounding, frame fitting |
| A variable-frame-rate screen recording | Which frame is shown at each timeline frame |
| A 3–4 minute song as WAV, AAC and FLAC, with a tempo change, at 44.1 and 48 kHz; a mono voice file | Beat detection and fitting, sample-rate conversion, stereo proxies |
| A dense edit: 300+ clips, many under 6 frames, cut to beats with the Motion Designer | Timeline UI load, undo cost, save time, export instruction tiling |
| Heavy looks: deep effect stacks, adjustment layers, nested timelines, Feedback, Slit-Scan, Flow Smear, optical flow transitions | Rendering cost, moments read from other frames, caches |
| Graphics: text with OpenType features, shapes, gradients, pen paths, a Waveform effect | Vector drawing, fonts, audio-driven pictures |
| HDR sources (PQ and HLG) and a 4K source | Color conversion, memory |
| A project whose media is on an external drive, one with a missing file, and one with a replaced file of a different length | Relinking, replacement, alignment |
| A project with Python expressions and a script | The helper, confinement, code approval |

**Goal:** tell failures that already existed apart from problems the
review uncovers, and have numbers to compare against.

## 2. Architecture and maintainability

The app is one target grouped by folder: `App` (sessions and windows),
`Model` (the value model of the edit), `Project` (the package on disk,
history, effect package and preset stores), `Analysis`, `Playback`,
`Rendering`, `Export`, `Recording`, `Replacement`, `Scripting` and `UI`.

- [ ] **One source of truth for the edit.** Confirm that `EditingProject`
      held by `ProjectState` is the only authority, and that views keep
      only transient state (a drag held by `ProjectState.hold` and written
      once). Check the long-lived editing sessions that keep their own
      copies: `BeatMatchSession`, `MotionDesignSession`, `SceneSplitter`,
      `MediaReplacementController`, `ClipsTabModel`. Each must write back
      through one path and cope with the project changing beneath it
      (an undo, a script, a live reload).
- [ ] **Preview and export share one renderer.** `LayeredCompositor` is
      used by export (`CompositionPlanning`, `ComposedTimeline`) and by
      the viewer. Trace both paths from timeline to pixels and list every
      place they diverge: preview quality, the caches, viewer copies,
      `PlayheadPrerenderer`, `TimelinePreview`. Each divergence must be
      deliberate and documented in [rendering.md](rendering.md).
- [ ] **Sound is one mix.** Compare how playback, scrub audio
      (`ScrubAudio`, `TapeScrub`), the level meter (`AudioLevelTap`,
      `MixLevelMeter`), the Waveform effect (`WaveformAudio`) and export
      (`AudioExport`, `LoudnessMastering`) build the mix. Volume and pan
      keyframes, sound effects and fades must be computed by shared code,
      not reimplemented.
- [ ] **Non-UI logic out of `UI/`** (AGENTS.md). Known: the export queue
      in `UI/Export/ExportWindow.swift`. Look for more in the largest UI
      files: `BeatMatchSession` (1,105 lines), `MotionDesignSession`,
      `TimelineEditorSurface`, `SceneSplitter`, `ClipsTabModel`,
      `MediaReplacementController`.
- [ ] **Oversized files.** For each file over about 1,000 lines
      (`ProjectFile`, `Keyframing`, `KeyframeGraphView`, `AssetAnalysis`,
      `BeatFitting`, `LayeredCompositor`, `EffectPackageStore`,
      `ViewerHandlesOverlay`, `BeatMatchSession`, `ClipTransition`,
      `MotionDesignLanes`, `Effects`, `ClipBlockView`), say whether it has
      one responsibility. Size alone is not a finding.
- [ ] **Shared and global state.** List every `static` that holds state
      (`MetalDevice.shared`, the static `CIContext`s in `FloatBitmap` and
      `EffectThumbnails`, the effect package registry, the code approval
      store, `Preferences`). Check what happens with two projects open
      at once: nothing per-project may live in app-wide state.
- [ ] **Errors.** There are 279 `try?` in the sources. Sample them in
      `Project/`, `Export/` and `Analysis/`: each discarded error must be
      one the person truly doesn't need to know about. Check that failures
      reach the person through `RefusalNotice`, `AnalysisFailure` or the
      error advice that `ErrorAdviceTests` covers, not only `NSLog`.
- [ ] **Testability.** Timing-dependent code takes a clock
      (`ManualClock` in the tests) rather than sleeping; rendering is
      reachable through `CompositorHarness`; new event-driven views have
      an `EventHarness` suite.
- [ ] **Docs agree with the code.** For each design document, check its
      status line against the code, and each item in loose-ends.md
      against whether it is still true.

**Goal:** catch structural problems before reviewing implementations in
detail.

## 3. Security, privacy and dependencies

The app makes no network connections, so the trust boundaries are the
files it opens and the code it runs.

**Matroska** ([matroska.md](matroska.md)). `MatroskaIndex` and
`MatroskaBytes` parse EBML from any MKV the person imports, and
`MatroskaReferenceMovie` writes a movie whose samples point into it.

- [ ] Review every size, offset and count read from the file for
      overflow (`offset + size`, element sizes near `Int64.max`,
      unknown-size elements, timestamps scaled by `timestampScale`).
- [ ] Bound recursion depth, element counts and memory used by the index.
- [ ] Check that a reference movie can never point outside its MKV.
- [ ] Fuzz the parser with truncated files, files cut inside a cluster,
      bad lacing and nonsense sizes, under the address sanitizer. A
      corrupt file must fail with a message, never crash or hang.

**Project packages** ([project-package.md](project-package.md)).
`project.json` is meant to be edited by hand and is reloaded live, so it
is untrusted input even from the person's own disk; so are
`view-state.json`, the binary files in `Reference/` and `.amvbackup`
files opened from Finder.

- [ ] Check `StrictJSON` and `ProjectFile` reject, with a message:
      a zero or negative `CMTime` timescale, negative durations, NaN and
      infinite values, duplicate IDs, references to missing items, cycles
      of nested timelines, and enormous arrays.
- [ ] Check asset paths can't reach outside where they should: a
      relative path with `..` that escapes the package, or a `Media/`
      path that is a symbolic link elsewhere.
- [ ] Check the readers of `audio.bin`, `signature.bin`, `beats.bin` and
      the thumbnails check lengths before reading.

**Effect packages** ([effect-packages.md](effect-packages.md)).
`.amveffect` folders hold JSON and a Metal kernel that Core Image compiles
at run time; people install them by opening them or making their own.

- [ ] Check that installing, copying and making a package derives file
      names safely (no path separators or `..` from a package's name or
      ID) and never writes outside the library folder.
- [ ] Check that a kernel that fails to compile, or a package that
      declares absurd sizes, pass counts or controls, is reported in the
      effects library and doesn't stop the app from launching.
- [ ] Note the risk that a kernel can stall the GPU. Decided (D8): an
      external package is executable GPU code, approved by the person for
      its exact executable content before its first compilation or run,
      wherever it comes from (installed, embedded in a project, live
      reloaded or found in the library folder), listed but not compiled
      until then, with a recovery launch that turns external effects
      off. Check each of those paths. Don't assume a time limit can be
      had: cancelling a Swift task doesn't
      stop GPU work already submitted, and only the system's watchdog
      ends a runaway command buffer; any limit proposed must say what
      stops the work.

**Python** ([python-scripting.md](python-scripting.md)).

- [ ] Review the `sandbox-exec` profile in `HelperConfinement`: no
      network, no file writes, no starting processes, reads limited to the
      system, the interpreter's installation and the helper's code. Run
      `ConfinementTests` with `AMV_PYTHON` set, and try to break out by
      hand (symbolic links in the interpreter's path, `/dev`, `/private/etc`).
- [ ] Check what happens when `sandbox-exec` is missing:
      `HelperConfinement.isAvailable` is false; expressions must then not
      run unconfined.
- [ ] Check `CodeApproval`: code runs only after approval on this Mac,
      approval covers the code actually executed, and opening a project
      that carries `Scripts/` or expressions never runs them before
      approval. "The code actually executed" includes: what changes
      between approval and the run; links and imports reaching outside
      the approved folder; modules the helper keeps from earlier runs;
      the interpreter's own start-up (`site`, `.pth` files, environment,
      import paths); and threads or processes that outlive a run, which
      can taint later runs in the same project even with a helper per
      project. Decided (D5): remembered approval ("Remember approval for
      these scripts") covers an exact snapshot of the executable content,
      never a project's ID and path, and is asked again when the content
      changes; the approved snapshot is what runs; opening a project
      never runs an unrestricted script; and the prompt says unrestricted
      scripts reach files and the network with the person's permissions.
      Check each, including links and imports outside the snapshot.
- [ ] Treat every message from the helper (`ScriptMessages`) as
      untrusted: malformed or huge messages, edits through `ProjectBridge`
      that would be refused from the UI, a helper that hangs or never
      answers. Each must be validated like any edit and time out.
- [ ] Check that `Process` is started with an argument array, never a
      shell string, and that the interpreter chosen in Settings is used
      only as an executable path.

**Recording and permissions.**

- [ ] The microphone and other apps' sound (`NSMicrophoneUsageDescription`,
      `NSAudioCaptureUsageDescription`) are used only while a take is
      recording, and a refused permission produces a message, not a
      silent take.

**Privacy.**

- [ ] Review the 22 `NSLog` and 14 `print` calls. Errors from
      AVFoundation and the file system carry full paths; keep them out of
      release logs or decide they are acceptable. `print` should not be
      in release code paths.
- [ ] Confirm the app still makes no network connections, including
      the Python helper when confined.

**Dependencies and the app's own scripts.**

- [x] `scripts/python-pin` is committed and release packaging fails
      without the pin or the bundled Python (decision D3).
- [ ] Record the CPython build's license and those of the libraries it
      bundles (OpenSSL, SQLite, libffi, zlib and the rest), and ship their
      notices with the app.
- [ ] The workflow uses actions by tag (`actions/checkout@v4`,
      `actions/upload-artifact@v4`); decide whether to pin them by commit.
- [ ] No FFmpeg or other codec library is used. If one is ever added,
      review the license obligations of that specific build.

**Sandboxing.**

- [ ] Decide whether the app should adopt the App Sandbox. It doesn't
      today, so security-scoped bookmarks aren't used; adopting it would
      need bookmarks for media referenced in place and on external drives,
      for export destinations and for the Python interpreter, and a new
      way to confine the helper. Record the decision either way. Confining
      expressions protects one boundary, not the app: the app also hands
      untrusted media to system frameworks, compiles packages' kernels,
      moves and deletes files, and runs approved scripts unconfined on
      purpose. Decided (D6): deferred for the first release, as a
      separate security project, with the residual risks recorded and the
      release gates under phase 12's "Signing" standing in; they don't
      give the same protection. Revisit before a Mac App Store release or
      a significant growth in plugins or executable content.

**Goal:** settle the trust boundaries before exercising complex media
workflows.

## Stabilization checkpoint

Between the trust-boundary work and the broad correctness, performance
and interface phases, close what makes the rest of the review unsafe or
its evidence untrustworthy. Phase 4 runs alongside, since its findings
are of the same kind; phases 5 onward wait for A to C.

- [ ] **A. Data-loss paths.** Verify, then fix or accept with a reason,
      every open finding that can lose the person's work or files:
      clips dropped at load and then saved away; paths made from project,
      package or effect names; writing with no lock where `flock` isn't
      available; drafts committed over newer state (Beat Match's
      Confirm, a viewer handle drag); provenance rewritten after a read
      failed; backups' order across a clock change; and phase 4's.
      "Undo brings it back" doesn't make an overwrite safe: autosaves,
      closing the project and outside edits all outlast the undo stack.
- [ ] **B. Untrusted input.** Close the open validation gaps: numeric
      bounds, overflow, non-finite values and invalid times; text runs;
      cycles of nested timelines; the helper's frame lengths, buffered
      bytes and queued messages; times a script gives as a rational.
      Validate where the input arrives, keep defensive checks at the
      operations that would trap or write, and state explicit budgets
      (sizes, counts, durations) rather than taking whatever fits an
      integer.
- [ ] **C. Trust in the test harness.** A runner that doesn't take the
      test process's exit status on its word: it requires a valid
      completion summary, refuses an unexpectedly small run or one
      missing a required suite, times out a hang and captures its
      threads' stacks first, and keeps the logs. The `UI_EVENTS` hang is
      captured that way before any change to the code suspected of it;
      running event tests in a process of their own may follow, but not
      in place of finding whether the hang is an app defect.
- [ ] **D. Representative fixtures, made rather than licensed.**
      Generated media and projects for the correctness and baseline work:
      numbered frames with clicks at known samples, held drawings,
      flashes, fades, gradients and sharp outlines, mixed and variable
      frame rates, long-GOP files, dense timelines and deep effect
      stacks. Real anime footage stays for a later qualitative check.

**Goal:** no known open path to lost work, and test results that can be
trusted, before measuring the rest.

## 4. Project model and persistence

- [ ] **Identity.** IDs are stable across save and reload. Copy and
      paste (`ClipPasting`, `PasteSources`), duplication, nested
      timelines and scripts give new items new IDs and keep references
      between them (linked audio, groups, music attachment, transitions
      joining clips, adjustment layer reach) consistent.
- [ ] **Round trip.** For generated projects covering every item kind,
      loading what was saved gives an equal `EditingProject`, `CMTime`
      values come back exactly (value and timescale), and saving twice
      gives identical bytes (deterministic output).
- [ ] **Format.** `formatVersion` is checked first; a project from
      another version, or one `StrictJSON` refuses, is never written over,
      autosaved or backed up in place, and the message says which file
      and why.
- [ ] **Atomic saves.** Read `ProjectStore+Save`: `project.json` is
      written to a temporary file and replaced. Check the order in which
      `project.json`, `Reference/` and `Media/` are written so that a
      crash at any point leaves a package that opens.
- [ ] **Autosave and backups.** `ProjectSession` autosaves into
      `Backups/` and makes `.amvbackup` files (`ProjectBackups`). Failures
      today are logged with `NSLog`; check the person is told
      (`AutosaveStatusTests`). Kill the app mid-edit and confirm the
      newest unsaved autosave is offered on opening.
- [ ] **The lock.** `ProjectLock` holds an `flock` on `.lock` and skips
      it on volumes without `flock`. Check a second window or a second
      Mac can't write the same project, and that the person is warned
      when locking was skipped.
- [ ] **Live reload.** `ProjectFileMonitor` reloads `project.json` when
      it changes on disk. Check: the app's own saves aren't taken for
      outside edits; a file read halfway through another program writing
      it is retried, not refused; an outside edit while there are unsaved
      changes asks rather than discards.
- [ ] **Undo and redo.** `ProjectHistory` finds edits by comparing the
      project with a baseline, merges quick repeats of the same edit
      within 0.5 s, and replays media moves onto older snapshots. Check
      undo across a save that moved media, a script run as one step,
      driven keyframes that refuse edits, and the Motion Designer's
      locked clips (loose-ends.md: a refused undo clears the redo stack).
      Measure the cost of the comparison on the dense review project.
- [ ] **Missing and moved media.** Disconnect the external drive while
      the project is open, playing and exporting; rename a media folder;
      move the package. Check how file stamps (`FileStamp`) detect the
      change (`MediaChangeDetectionTests`), `MediaProblemsBar` and
      relinking. A missing file shows a placeholder and is reported;
      it never ends up removed from the project.
- [ ] **Replacement** ([media-replacement.md](media-replacement.md)).
      Replace a file with a longer, shorter and differently timed
      version. Check `MediaReplacer`, `MediaAlignment` and the stored
      alignment offset keep cuts on the same picture, and that what can't
      be adjusted safely is blocked with a reason.
- [ ] **Originals are never modified.** Follow every `removeItem`,
      `moveItem`, `replaceItemAt` and atomic write in the sources (about
      twenty files, among them `MediaImportFlow`, `AudioRecorder`,
      `ViewerCopies`, `RenderCache`, `StereoProxies`, `MatroskaMedia`,
      `CompositionExporter`) and show that each target is inside the
      package, a cache, the person's chosen export destination, or a copy.
      Importing into `Media/` copies; it never moves. Cache clean-up stays
      inside `Cache/`. `Reference/` is never deleted automatically.
- [ ] **Other stored state.** A corrupt `view-state.json`
      (`ViewStateFile`), preset store (`PresetStore`) or approval store
      (`CodeApproval`) is reported and replaced, never a reason the
      project won't open.

**Goal:** no lost edits, corrupted projects or touched footage.

## 5. Timeline, timing and music sync

### Time and the frame grid

- [ ] Search `Model/`, `Export/` and `Playback/` for arithmetic on
      `.seconds` or `Double` times and check each use is for display or a
      tolerance, never stored or summed. Model properties are `CMTime`;
      a few fields such as `frameSeconds` and `markerSeconds` are
      `Double` and need the same check.
- [ ] Check that every snap, trim and placement goes through
      `ClipPlacement`'s integer frame rounding (`FrameRounding`), so a
      time already on a frame stays on it at NTSC rates.
- [ ] Check `CMTime` arithmetic for overflow and invalid results when
      mixing timescales (48 kHz audio, 24000/1001 video, Matroska's
      timestamp scale): results that are invalid, indefinite or rounded
      must not propagate into the model.
- [ ] Check `FrameFitting` for sources whose rate differs from the
      timeline's: which source frame shows at each timeline frame, with no
      frame shown twice or skipped at speed 1 when the rates match.
- [ ] Variable frame rate: the frame shown at a timeline time is the one
      presented at that time in the source, not the nth sample.
- [ ] Matroska timing ([matroska.md](matroska.md)): reordered B-frames,
      laced frames sharing a time, a non-default timestamp scale and AAC
      priming all keep picture and sound in sync.

### Edits

- [ ] Moving, trimming, snapping (`Snapping`), lasso selection, groups,
      sections, disabled clips, hidden layers and the loop region at
      timeline start, end and frame boundaries.
- [ ] Linked and detached audio (`LinkedAudio`) stays in sync through
      every edit, and detaching keeps the levels (`DetachAudioTests`).
- [ ] Scene following ([scene-cuts.md](scene-cuts.md)): splitting and
      merging scenes in the scene splitter splits, joins or embeds the
      timeline clips that use them, without moving any cut by a frame.
- [ ] Overlaps on one layer are impossible or handled the same way in
      model, viewer and export.

### Transitions

- [ ] `ClipTransition` (1,084 lines): transitions need media beyond a
      clip's ends; check clips without enough, at the start and end of the
      timeline, beside disabled clips and joined transitions.
- [ ] Sound fades under picture transitions (`AudioCrossfade`) start and
      end on the same frames as the picture.

### Retiming and the Motion Designer

- [ ] `ClipTiming` and `ClipTimeMap`: the map from timeline to source time
      is monotonic where it should be, holds hold, reverse runs backwards,
      and the inverse map agrees with it on the parts that are invertible
      (a source frame found from a timeline frame maps back to that
      timeline frame). Holds, freezes and slowed footage repeat source
      frames, so no inverse is unique there: check the map's documented
      rule for which timeline frame such a source frame returns (the
      first, say), and write one down if there isn't one.
- [ ] Speed keyframes and easing (`TimeMapKeyframes`, `MotionRun`), Time
      and Shutter, and Optical Flow land on the frames the Motion
      Designer shows ([motion-designer.md](motion-designer.md)).
- [ ] Scene-bounded trims never show a frame from the next scene.
- [ ] Retimed sound: pitch behavior at each speed, reversed sound, and
      silence over holds, the same in playback and export.

### Keyframes and expressions

- [ ] Keyframes (`AnimatedValue`, `KeyframeEase`) sit on frames, and stay
      with the content they were set on after a trim, a move and a retime.
- [ ] Keyframing effects ([keyframing-effects.md](keyframing-effects.md),
      `Keyframing`, 1,552 lines) write the same keyframes every time from
      the same input, and driven controls refuse hand edits until baked.
- [ ] Expressions give the same value for a frame in the viewer and the
      export, including between frames under motion blur
      ([python-scripting.md](python-scripting.md)); a failing or slow
      expression is reported, not shown as zero.

### Scene detection

- [ ] Re-run the tests from [scene-detection-review.md](scene-detection-review.md)
      and check its fixed defects stay fixed.
- [ ] Cuts are reported on the exact first frame of a scene.
- [ ] Anime-specific cases: white and black flashes, impact frames,
      fades, held frames on twos and threes, credits over moving
      backgrounds. Record false and missed cuts on the episode projects.

### Beats

- [ ] Detection (`BeatDetection`, `BeatTracker`, `OnsetAnalyzer`) and
      fitting (`BeatFitting`, 1,211 lines): run `BeatFittingGoldenTests`
      and look at the goldens' changes before re-recording any.
- [ ] Beat maps ([beat-matching.md](beat-matching.md), `BeatMap`,
      `BeatMapEditing`): anchors, sections of one tempo, ramps and
      measures give beat times that drift by less than a sample over a
      whole song.
- [ ] Beats are in the song's time. Check `MusicAttachment` and
      `BeatTimelineMarkers` convert them to timeline time correctly when
      the song clip is trimmed, moved, retimed or nested, and that clips
      attached to music move with it.
- [ ] Beat markers snap to frames by one rounding rule, the same one used
      for cuts.
- [ ] The beat tick (`BeatClickPlayer`) and MIDI taps (`MIDITaps`) are
      heard and recorded at the beat, allowing for output latency.

### End-to-end sync

- [ ] Build a fixture with a white frame and a click at the same moment,
      place it at several offsets on 24, 29.97 and 60 fps timelines, and
      check the exported click lies within half a frame of the white
      frame. Repeat at the end of a 10-minute timeline to show there is no
      drift.

### Seeking

- [ ] Rough-then-exact seeks ([rendering.md](rendering.md)): a parked
      playhead always ends on the exact frame; the filmstrip stand-in and
      scrub cache picture are never left on screen.
- [ ] Frame stepping with the arrow keys is always exact, including on
      long-GOP footage drawn from ProRes viewer copies.
- [ ] Viewer copies time their frames exactly as the original does.

**Goal:** every cut lands on the intended frame and beat.

## 6. Concurrency and resource lifecycle

The package uses the Swift 6 language mode, so the compiler already
checks data races. The review is of the places that opt out of the
checks, and of work that is correct but in the wrong place.

- [ ] List each opt-out and the reason it is safe (a lock, immutability,
      a single owning queue), and fix those without one:
      43 `@unchecked Sendable` (15 files in `Rendering/`, 17 in `UI/`),
      26 `nonisolated(unsafe)`, 15 `Task.detached`, 2
      `DispatchQueue.global`. List them with
      `grep -rn '@unchecked Sendable\|nonisolated(unsafe)\|Task.detached\|DispatchQueue.global' Sources`.
- [ ] Nothing slow on the main actor: decoding, analysis
      (`AssetAnalysis`), filmstrips and thumbnails (`TimelineFilmstrips`,
      `FrameThumbnails`, `EffectThumbnails`), waveforms (`ClipWaveform`,
      `Spectrogram`), encoding `project.json` for a large project, and
      `ProjectHistory`'s comparison. Use the Hangs instrument on the dense
      project.
- [ ] The custom video compositor (`AVVideoCompositing`) is called on
      AVFoundation's queues: check `LayeredCompositor`'s shared state and
      that cancelled requests are finished.
- [ ] Cancellation: fast scrubbing (`ViewerPipeline`, `ScrubCache`,
      `PlayheadPrerenderer`), edits during background renders
      (`RenderScheduler`), closing a project during analysis, viewer copy
      builds, an export, a Python run or a recording, and stopping and
      restarting an export.
- [ ] Stale results: every asynchronous result checks it still matches
      the project (`EditStamp` or a generation) before it is shown or
      cached. `AssetAnalysis` has race tests; check the other producers
      have the same guard.
- [ ] Real-time audio: `AudioEffectUnit`, `EqualizerFilter` and the taps
      in `AudioLevelTap` don't allocate, lock or call into Swift
      concurrency on the render thread.
- [ ] Lifetimes: `NSEvent` monitors (`KeyPressMonitor`,
      `ScrollWheelMonitor`), file monitors, player and audio engine
      observers, `AudioDevices` notifications and external display windows
      are removed. Open and close the dense project twenty times and
      check with the memory graph and Leaks that each `ProjectSession` is
      freed.
- [ ] Run `swift test --sanitize=thread` on the playback, rendering,
      analysis and export suites.
- [ ] Settle the load-sensitive audio failures in loose-ends.md: find
      out whether `AVAssetReaderAudioMixOutput` with taps can hand over an
      extra or silent 4096-frame slice in a real export on a busy Mac.

**Goal:** no races, hangs, leaks or stale pictures.

## 7. Rendering and effects

- [ ] **Compositing order.** `LayeredCompositor`, `DrawTree` and
      `StackFolding` apply effects in the documented order (Transform,
      Blending, Color and Matte; [effects.md](effects.md)), about each
      clip's anchor point, through nested timelines and adjustment layers
      with their reach, skipping hidden layers and disabled clips.
- [ ] **Color.** Every `CIContext` is made with color management off
      (`workingColorSpace` and `outputColorSpace` set to `NSNull`), so the
      app converts color itself (`ColorGrading`, `ToneResponse`). Check
      each source's matrix (BT.601 for SD anime, 709, 2020), transfer
      function (SDR, PQ, HLG) and full or video range is read from the
      track and converted exactly once, and that the color tags written
      on ProRes match the pixels. A wrong range or matrix shows up on
      anime as crushed outlines and shifted skin and sky colors.
- [ ] **Viewer against export.** In SDR, the viewer at Full quality
      renders the same picture as the export at the same frame. Say what
      is compared before comparing: the compositor's output buffers (not
      what the display shows after its own color management), in a
      stated color space and transfer function, with alpha straight or
      premultiplied, and a tolerance that allows for the export codec
      (ProRes 422 is lossy; 4444 nearly lossless) rather than a single
      "small" one. Check HDR on an EDR display against the documented
      intent separately.
- [ ] **Precision.** Find the working pixel format through the
      compositor and the effect kernels; flat anime gradients must not
      band. Unintended loss of precision on the path to the exported or
      Full-quality picture is a finding; 8-bit is acceptable where it is
      deliberate and only displayed, as in thumbnails, filmstrips and
      display-only caches, and the SDR viewer's documented 8-bit decode
      is checked against its stated limits.
- [ ] **Preview quality.** At Half and Quarter (`PreviewQuality`),
      effects measured in pixels (blur radius, pixelate size, halftone
      dots, glow) scale so the picture matches Full in appearance.
- [ ] **Geometry.** Non-square pixels, rotation in the track's transform,
      odd sizes, letterboxing and crop; `ViewerMapping` maps handles to
      the same pixels the compositor draws.
- [ ] **Line art.** Look for ringing from resampling and halos from
      Sharpen and Unsharp Mask on dark outlines over flat color.
- [ ] **Effect packages.** All 77 that ship load; each category's
      document matches its controls. `LookReferenceTests` covers 25;
      list those without a reference picture (phase 11).
- [ ] **Effects that read other moments.** Feedback, Slit-Scan, Flow
      Smear and the optical flow transitions (`OpticalFlow`,
      `FlowFieldCache`, `BlockMatchFlow`, `MorphFlow`) give the same frame
      after a seek, at a clip's first frame, in a background render and in
      the export as in continuous playback.
- [ ] **Transitions** ([transitions.md](transitions.md)): all 25 picture
      kinds at clip boundaries and at the timeline's ends
      (`TransitionRenderer`, `TransitionMasks`).
- [ ] **Graphics.** Text (`TextLayout`, `TextOutline`), shapes
      (`ShapeGeometry`), gradients, pen paths and the Waveform effect
      (`WaveformDrawing`, `WaveformAudio`) stay sharp at every scale and
      look the same in export; a missing font is reported (`MissingFonts`).
- [ ] **Caches.** For `RenderCache`, `ClipPictureCache`, `PictureCache`,
      `ScrubCache` and `FlowFieldCache`, list what the key contains and
      show it covers everything that changes pixels: every effect
      parameter and keyframe, expression results, the source file's stamp
      after replacement, the effect package's version after a reload,
      preview quality and color settings. Then show each is invalidated
      by an edit, an undo, a live reload and a replacement.
- [ ] **Background renders in export.** ProRes 422 export reuses
      segments from `Cache/Renders/`. Show a stale, partial or
      reduced-quality segment can never be exported, and that viewer
      copies are never read by export.

- [ ] **Real footage, by eye** (D7). On the licensed review projects,
      look at line art, held drawings, flashes, gradients and subtitles
      in the viewer and the export against their sources; the generated
      fixtures stay the oracle for exact checks.

**Goal:** the exported image matches what the person built.

## 8. Audio and export

### Sound

- [ ] Volume and pan keyframes, layer and clip levels, sound effects (EQ
      in `EqualizerFilter`, Compressor, Limiter, Voice Isolation through
      `AudioEffectUnit`), fades (`AudioFades`) and transition crossfades
      sound the same in playback and export ([audio.md](audio.md)).
- [ ] Sample rates (44.1, 48, 96 kHz) are converted once; channel
      layouts other than stereo (a 5.1 MKV) are mixed down by a stated
      rule; mono files go through stereo proxies (`StereoProxies`) and pan
      correctly.
- [ ] Loudness: `Loudness` measures as ITU-R BS.1770 does, and
      `LoudnessMastering` reaches the target with peaks held under the
      stated ceiling. Say which peak: the ceiling is −1 dBFS of sample
      peak for WAV Mix, which doesn't hold the true peak (inter-sample,
      in dBTP, measured oversampled) under −1; check what the documents
      promise against what the limiter measures, and measure true peak
      too. Stems are not mastered: together they reproduce the mix
      before mastering, within the limits routing and shared effects set
      (a layer's sound through a nested timeline's effects, a compressor
      reacting to the whole mix), not the mastered mix, which no simple
      sum of stems can equal.
- [ ] Recording (`AudioRecorder`, `AudioCapture`, `TakeWriter`,
      `AudioApps`): a take lands where the playhead was when recording
      started, allowing for input latency; changing devices, refusing
      permission or filling the disk while recording keep what was
      recorded and say what happened. `Recording/` has one test file.
- [ ] Output devices (`AudioDevices`): changing the device while playing,
      unplugging headphones, and Bluetooth latency.

### Export

- [ ] The composition: `CompositionPlanning`, `CompositionFlattening`,
      `CompositionPlacement` and instruction tiling leave no gaps or
      overlaps that AVFoundation rejects or fills with black; blank
      stretches (`BlankFrame`), empty layers, hidden layers, disabled
      clips, alignment offsets and nested timelines come out right.
- [ ] Each output, reopened: the frame count equals the timeline's, the
      frame rate, size and color tags are right, sound and picture start
      together and end within one audio sample of each other, and ProRes
      4444 alpha is straight or premultiplied as documented. Check with
      AVFoundation and with an independent prober.
- [ ] The export of a frame matches the viewer's Full-quality render of
      it (phase 7).
- [ ] Stopping an export, a full disk, a destination without permission,
      a destination drive removed mid-export: each leaves no partial file
      that looks complete and gives a message that says what to do.
- [ ] Destinations (`ExportDestinations`): an export can't write over a
      source media file, the project package, or another export in the
      queue. loose-ends.md lists the stems folder and case-sensitivity
      gaps.
- [ ] Editing while an export runs: the export uses the project as it was
      when it started, or the person is told.
- [ ] Missing media and fonts are found before export starts, not halfway.

- [ ] **Real music, by ear** (D7). On the licensed review projects,
      listen to the mix and an export against the source song: beat
      sync, clicks, level jumps and resampling.

**Goal:** export is reliable, not merely successful according to the
export API.

## 9. Performance and energy

Measure release builds only, on the slowest supported Mac as well as a
fast one, plugged in and on battery.

- [ ] Re-run the benchmarks from phase 1 and record the differences:
      `RenderThroughputBenchmark`, `UIResponsivenessBenchmark` (with
      `AMV_PROJECT` on the dense project, and with
      `UI_BENCHMARK_UNHELD` for comparison) and `EdgeTransitionsBenchmark`.
- [ ] Measure: time from opening a project to its first frame; the time
      to load and save the dense project; the cost of one undo step;
      scrub latency to the exact frame; dropped frames playing heavy
      stacks at Auto quality; export speed as a multiple of real time for
      ProRes 422 with and without background renders and for 4444;
      analysis time for a 24-minute episode; peak memory.
- [ ] Profile with Time Profiler, Hangs, Allocations, Metal System Trace,
      Energy Log and File Activity. Look for picture copies between GPU
      and CPU, re-decoding, and work repeated every frame.
- [ ] Check the caches are bounded in memory and on disk:
      `Cache/Renders/` and `Cache/ViewerCopies/` growth over a long
      session, and what happens under memory pressure.
- [ ] Background work (`RenderScheduler`, viewer copies, analysis) yields
      to playback and editing, and backs off when the Mac is hot or on
      battery.
- [ ] Measure the suspect from loose-ends.md:
      `TimelineMenuStatePublisher` checking the playing time once a frame.
- [ ] Timeline interface at scale: the number of `ClipBlockView`s
      updated per edit and per frame of playback on the dense project,
      filmstrips, waveforms and the keyframe graph.

**Goal:** confirm performance with measurements rather than intuition.

## 10. macOS experience and accessibility

- [ ] Run the `accessibility-reviewer` agent over `UI/` and check the
      rules in [accessibility.md](accessibility.md) by hand on the drawn
      and gesture-driven views: `ClipBlockView`, `KeyframeGraphView`,
      `BeatMatchWaveform`, `MotionDesignLanes`, `ToneGraph`,
      `EqualizerGraph`, `ViewerHandlesOverlay`, `PenOverlay`, `LoopBar`,
      `FilmstripRow`, `TimelineRuler`. Each needs an accessibility element
      with actions, and everything a drag does needs a keyboard path.
- [ ] Keyboard: the list in `KeyboardShortcutsView` matches what
      `TimelineKeyboard` and the menus do; timeline keys don't fire while
      a text or numeric field (`NumericField`) has focus; no shortcut
      clashes with the system's.
- [ ] Menus (`ProjectCommands`, `TimelineCommands`, `EditCommands`,
      `ScriptCommands`) enable only what can be done, and undo items are
      named by `ProjectChange`.
- [ ] Nothing is told by color alone: bar colors, beat section tones,
      missing media, locked clips, refused edits.
- [ ] Reduced motion (`Design/Motion.swift`) and the Design text tones'
      contrast in light and dark appearance.
- [ ] Long work (analysis, viewer copies, background renders, export,
      Python runs) shows progress, can be stopped, and doesn't block
      editing.
- [ ] Refusals (`RefusalNotice`) and errors say what to do next. Edits
      the Motion Designer's lock refuses are shown as unavailable, not
      only refused (loose-ends.md).
- [ ] Drag and drop: Finder to the browser (`MediaImportFlow`), browser
      to timeline, effects onto a stack (`EffectStackDrop`), packages into
      the library; Escape cancels each (`DragEscape`).
- [ ] Windows: several projects open, the timeline window, beat match,
      Motion Designer, tape scrubber and the external display
      (`ExternalDisplay`); resizing to the smallest size, disconnecting
      the display, sleep and wake during playback, export and recording.
- [ ] **The screen pass.** Many documents say their feature is built but
      not yet tried on screen. Try each in the running app and update
      its status line: beat detection's picker, markers and ticks; beat
      matching; the Motion Designer on a real project; the pen tool;
      the equalizer graph; recording, the controls and the meter; bar
      colors; browser stages 2 to 6; stills, shapes and strokes; the
      Waveform effect; the untried parts of Python scripting.
- [ ] Add a `UISnapshots` case for each view changed by a fix, and an
      `EventHarness` suite (`.serialized`, `.eventsOneAtATime`) for each
      interaction fixed.

## 11. Test coverage and regression

Tests mirror the source folders. Source and test files per area today:

| Area | Source files | Test files |
| --- | --- | --- |
| App | 10 | 2 |
| Model | 90 | 71 |
| Project | 32 | 28 |
| Analysis | 26 | 24 |
| Playback | 17 | 18 |
| Rendering | 47 | 33 |
| Export | 16 | 10 |
| Recording | 4 | 1 |
| Replacement | 2 | 3 |
| Scripting | 10 | 9 |
| UI | 277 | 80 |

- [ ] Look first where the ratio is lowest and the risk highest:
      `App` (session lifecycle and autosave), `Export` (the composition
      and the export queue), `Recording`, and the drawn UI.
- [ ] Unit and property tests for timing math: frame rounding at NTSC
      rates, `ClipTimeMap` and its inverse, beat map tempo ramps,
      `CMTime` conversions between timescales.
- [ ] Round-trip and rejection tests for `ProjectFile` and `StrictJSON`
      over generated projects and hand-broken files.
- [ ] Fuzz tests for `MatroskaIndex` and the `Reference/` readers.
- [ ] One end-to-end test: import an MKV, a MOV and a WAV; detect scenes
      and beats; place clips on beats; add effects, a transition and text;
      save, close and reopen; export ProRes 422 and 4444 and WAV Mix;
      check frame count, sync (the white-frame-and-click fixture),
      color tags, and a pixel comparison with the viewer's render.
- [ ] A look reference for every effect package that ships, not 25 of 77.
- [ ] Malformed input, offline media, mixed formats and the dense project
      as fixtures, made in the tests (`SceneFixtures`,
      `MatroskaFixtures`) rather than committed footage where possible.
- [ ] Flakiness: replace sleeps with `ManualClock` or `Waiting`, and fix
      or explain the load-sensitive audio tests.
- [ ] Decide which gated suites CI should run (`UI_EVENTS`, `AMV_PYTHON`,
      the Python unit tests, snapshots as a comparison) and whether CI
      should run on pull requests rather than only by hand.
- [ ] Turn every confirmed defect from this review into a regression
      test where practical.

Inspect and run tests from phase 1 onward; this phase audits coverage
across the whole workflow.

## 12. Release readiness

- [ ] **Signing.** Replace ad-hoc signing with a Developer ID signature
      and the hardened runtime, sign every executable and library in the
      bundled Python (`Contents/Resources/Python`), and add the
      entitlements the hardened runtime needs for the microphone and for
      recording other apps' sound. Check the confined helper still starts
      under `sandbox-exec` once signed. These, with notarization, are
      release gates for public distribution while the App Sandbox is
      deferred (D6), together with: confined expressions fail closed
      where confinement is unavailable; the release-blocking parser,
      file-system, approval and helper-protocol findings are closed; and
      the documentation says approved unrestricted scripts run with the
      person's permissions.
- [ ] **Notarization.** Submit with `notarytool`, staple the ticket, and
      check Gatekeeper accepts the downloaded app.
- [ ] **Packaging.** `CFBundleShortVersionString` (0.1 today) and the
      build number are set by the release; the three document types open
      from Finder (`.amv`, `.amveffect`, `.amvbackup`); the resource
      bundle holds the 77 effect packages and the helper's code.
- [ ] **Clean machines.** Install on a fresh user account on macOS 15
      (or the minimum decided in phase 1) and on the newest release: first
      launch, permission prompts and their text, opening each document
      type, scripting with and without the bundled Python, and a full
      import-to-export run.
- [ ] **Architectures.** Ship what phase 1 decided (arm64 only or
      universal) and say so on the download page.
- [ ] **Crashes.** The app sends nothing over the network, so crash
      reports stay in `~/Library/Logs/DiagnosticReports`. Document how a
      person finds and sends one, or decide to add reporting with consent.
- [ ] **Recovery.** Write for the person how to restore from `Backups/`
      and `.amvbackup` files; [project-package.md](project-package.md)
      says an older autosave has to be copied over `project.json` by hand.
- [ ] **Errors.** Every error a person can meet in the end-to-end run
      says what happened and what to do.
- [ ] **Rights.** The app ships no anime footage, music or fonts; keep it
      that way. Check the licenses of the CPython build and its libraries
      (phase 3), and that sample projects, screenshots and test fixtures
      use media the project may distribute. Don't assume an AMV, or a clip
      in one, is fair use.
- [ ] **Docs.** Every status line in [README.md](README.md) is true, and
      loose-ends.md is empty or each item is accepted for the release.
- [ ] **CI.** Run the workflow on the release commit and keep its app
      bundle.

## Triage order

1. Security and data loss: footage modified, projects lost or corrupted,
   code run without approval, parsers that crash on a file.
2. Crashes and hangs.
3. Timing, sync and export correctness: a wrong frame, a beat off,
   sound out of sync, an export that differs from the viewer.
4. Performance: scrubbing, playback, saving, export speed.
5. Usability and accessibility.
6. Cosmetic issues.

The order ranks impact, and a finding takes the rank of what it does,
not of its category: an accessibility failure that blocks a core
workflow (no keyboard path to trim a clip) ranks with the workflow it
blocks, and a test-harness defect that lets failures pass (a run that
ends early and reports success) ranks with the defects it could hide.
Category is recorded apart (see "Recording findings").

## Coverage map

Every source folder, the phases that review it, and where it is
described.

| Folder | Phases | Documents |
| --- | --- | --- |
| `App/` (sessions, windows, commands, preferences) | 2, 4, 6, 10 | [project-package.md](project-package.md) |
| `Model/` (edit model, placement, timing, sections, snapping, paste) | 2, 4, 5 | [timeline.md](timeline.md), [loop-region.md](loop-region.md), [bar-colors.md](bar-colors.md) |
| `Model/Beats/` | 5 | [beat-matching.md](beat-matching.md) |
| `Model/Effects/` (effects, keyframing, expressions, text, paths, gradients, EQ) | 3, 5, 7 | [effects.md](effects.md), [keyframing-effects.md](keyframing-effects.md), [graphic-layers.md](graphic-layers.md), [gradients.md](gradients.md), [equalizer.md](equalizer.md), [waveform-effect.md](waveform-effect.md) |
| `Model/MotionDesigner/` | 5 | [motion-designer.md](motion-designer.md) |
| `Model/Transitions/` | 5, 7 | [transitions.md](transitions.md) |
| `Model/ViewerHandles/` (handles, pen) | 7, 10 | [viewer-handles.md](viewer-handles.md), [pen-tool.md](pen-tool.md) |
| `Project/` (files, saving, history, lock, monitor, stores) | 3, 4, 6 | [project-package.md](project-package.md), [effect-packages.md](effect-packages.md) |
| `Project/Matroska/` | 3, 5 | [matroska.md](matroska.md) |
| `Analysis/` (analysis, waveforms, loudness, provenance) | 5, 6, 9 | [scene-cuts.md](scene-cuts.md) |
| `Analysis/Beats/` | 5 | [beat-detection.md](beat-detection.md), [beat-matching.md](beat-matching.md) |
| `Analysis/Reference/` | 4 | [media-replacement.md](media-replacement.md) |
| `Analysis/Scenes/` | 5 | [scene-cuts.md](scene-cuts.md), [scene-detection-review.md](scene-detection-review.md) |
| `Playback/` (viewer pipeline, scrubbing, skimming, devices, meters) | 5, 6, 8, 9 | [rendering.md](rendering.md), [audio.md](audio.md) |
| `Rendering/` and `Rendering/Cache/` | 6, 7, 9 | [rendering.md](rendering.md) |
| `Rendering/Compositor/` | 7 | [effects.md](effects.md), the effects category documents |
| `Rendering/Transitions/` | 7 | [transitions.md](transitions.md) |
| `Export/` | 2, 6, 8 | [audio.md](audio.md), [rendering.md](rendering.md) |
| `Recording/` | 3, 8 | [audio.md](audio.md) |
| `Replacement/` | 4 | [media-replacement.md](media-replacement.md) |
| `Scripting/` | 3, 5, 6 | [python-scripting.md](python-scripting.md) |
| `Resources/Effects/` (77 packages) | 3, 7, 11 | [effect-packages.md](effect-packages.md) and the category documents |
| `Resources/Python/amv_host/` | 3 | [python-scripting.md](python-scripting.md) |
| `UI/` (all subfolders) | 2, 10 | [accessibility.md](accessibility.md), [browser.md](browser.md), [parameter-rows.md](parameter-rows.md) |
| `Packaging/`, `scripts/`, `.github/workflows/` | 1, 3, 12 | AGENTS.md |
