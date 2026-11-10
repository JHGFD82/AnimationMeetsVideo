# Export queue fixes

Status: **temporary, planned**. Fixes for the defects found in review of
commit bd7bdc6, "Queue exports started while one is running" (November
2026). Nothing here is implemented yet. Work through the items in
order, tick each one off as it lands, and delete this file once every
box is ticked. Anything left undone on purpose moves to
[audio.md](audio.md) or [loose-ends.md](loose-ends.md).

Each item was checked against the code at bd7bdc6, and its plan was
checked against the others. The steps are meant to be followed one item
at a time, without the review that produced them.

## How to work through this list

- **One item is one commit, in the order listed.** Later items assume
  the earlier ones have landed. If you skip one, read the later item's
  "Depends on" line first.
- **Line numbers are as of bd7bdc6.** They shift as items land, so find
  each edit by the function name or the quoted text, not by the number.
- **Items marked Decision need the user's answer.** Look in the
  Decisions table below. If its Chosen column is empty for that item,
  ask the user before starting it; don't choose for them.
- **Build with full Xcode.** `xcode-select -p` must not point at the
  Command Line Tools, which lack the SwiftUI macro plugins. Run
  `swift build`, the item's tests, then the whole `swift test` before
  committing.
- **Tests must never open a save panel, an alert or a window.** CI runs
  `swift test` with no one to answer them, so a real modal hangs it, and
  `NSApp` is nil there. Item 1 adds stand-ins for all of them.
- **Commit messages follow AGENTS.md.** Each item suggests a subject.
  Wrap the body at 72 columns: bd7bdc6's body has a 73-column line.
- **"In the app" checks need a person.** The app can't be driven from
  a session. List those checks for the user when you report, rather
  than claiming them.

## Decisions

| Item | Question | Recommended | Alternative | Chosen |
| --- | --- | --- | --- | --- |
| 2 | What happens when the place picked in the save panel is already used by an export under way or waiting? | Suggest a name that is never taken, and refuse a used place with an alert after the panel. | Validate inside the panel with a save panel delegate, which this repo has never used; or let the new export replace the waiting one, which silently drops it. | Recommended |
| 3 | Should an export that is already running when an effect package changes be fitted too? | No. Fix queued exports only, and say in effect-packages.md that a running one isn't handled yet. | Have each composition draw with the packages it was built with: a larger rendering change. | Recommended |
| 10 | A stopped WAV Stems export keeps its folder and stems, but the alert says they are deleted. | Delete what this export wrote, and the folder only if it made it and it is left empty. | Keep the stems and say so in the alert. | Recommended |
| 11 | Should the Export window offer a way to stop the whole queue? | A third button, Stop All, in the Stop Export… question, shown only while exports wait. | A fourth button in the window's footer; or only fix the question's wording. | Recommended |
| 14 | Should a stopped export leave a line in the window? | Yes: record a Stopped outcome. | Change the doc to say stopped exports leave no line. | Recommended |

## Checked and left alone

- **Progress redrawing the whole window.** The review suspected that
  every progress tick re-ran the whole Export window. It doesn't:
  `export.progress` is read inside `SheetSection`'s content closure, so
  a tick redraws only that small section. Nothing to do.
- **Moving the queue out of UI/.** The queue logic would fit AGENTS.md
  better in a non-UI type such as `Export/ExportQueue.swift`. That
  would rewrite every reference below, so it waits until these land.

## Items

### 1. Let tests run the export queue without modals

- [x] Done

**Why.** None of the queue logic has a test. `run()` opens a modal
NSSavePanel, `start(_:)` runs the real exporters, which take seconds
and write files, and `ended(_:_:)` calls `show()` and
`NSApp.requestUserAttention`, which crash when `NSApp` is nil. The only
test bd7bdc6 added is a UISnapshots case, which CI skips. This item
adds closures that tests replace, following the existing
`RenderScheduler.render` seam, and changes no behavior.

**Steps.**

1. Rendering/Cache/RenderScheduler.swift, about line 79: make
   `isExporting` readable, so tests can check that `setExporting(true)`
   and `setExporting(false)` pair up.

   ```swift
   /// Set while an export runs (`setExporting`), which rendering waits for.
   @ObservationIgnored private(set) var isExporting = false
   ```

2. UI/Export/ExportWindow.swift, directly after
   `@ObservationIgnored private var closeObserver: NSObjectProtocol?`
   (about line 47), add three seams:

   ```swift
   typealias Perform = @Sendable (Job, RenderCache?, @escaping @Sendable (Double) -> Void) async throws -> String?

   /// What runs one export, returning what mastering did as a sentence:
   /// the app's exporters (`write`). A test stands in for them, to end
   /// each export when it chooses (`StandInExports`).
   @ObservationIgnored var perform: Perform = { job, cache, progress in
       try await ExportWindow.write(job, cache: cache, progress: progress)
   }
   /// Where Export… saves, given the name to suggest and the format; nil
   /// for Cancel. The save panel (`askWhereToSave`), which a test answers.
   @ObservationIgnored var chooseDestination: @MainActor (_ suggestedName: String, _ format: ExportFormat) -> URL? = { name, format in
       ExportWindow.askWhereToSave(suggesting: name, format: format)
   }
   /// Tells the person the exports have ended: the window comes back if it
   /// was closed, and the Dock icon bounces, since a long export may finish
   /// with the app behind another. A test counts the calls instead.
   @ObservationIgnored var announceEnd: @MainActor (ExportWindow) -> Void = { export in
       export.show()
       NSApp.requestUserAttention(.informationalRequest)
   }
   ```

   If the compiler says `Job` isn't Sendable, declare it
   `struct Job: Identifiable, Sendable`. All its stored properties
   already are.

3. In `start(_:)` (about lines 226-265), keep the progress closure and
   the outcome handling, and call `perform`:

   ```swift
   task = Task {
       let progress: @Sendable (Double) -> Void = { fraction in
           Task { @MainActor in self.progress = fraction }
       }
       var outcome: Outcome?
       do {
           let report = try await perform(job, cache, progress)
           outcome = .finished(url: job.destination, report: report)
       } catch is CancellationError {
           // Stopped by the person; nothing to report.
       } catch {
           outcome = .failed(ErrorAdvice.sentence(for: error))
       }
       ended(job, outcome)
   }
   ```

   Move the `ReportBox` and the `switch job.format { … }` (about lines
   234-256) unchanged into a new function after `start(_:)`.
   `let url = job.destination` moves with them, so `start` now writes
   `job.destination`. Leave `ReportBox` itself where it is.

   ```swift
   /// Runs `job` with the app's exporters; what mastering did, as a sentence.
   nonisolated private static func write(
       _ job: Job, cache: RenderCache?, progress: @escaping @Sendable (Double) -> Void
   ) async throws -> String? {
       // Only shown once the export is done.
       let report = ReportBox()
       let url = job.destination
       switch job.format {
       // the three cases, exactly as they were in start(_:)
       }
       return report.value?.summary
   }
   ```

4. Split `run(project:timelineID:renderer:)` (about lines 189-224)
   into the panel and the start-or-queue decision. `run` keeps its
   signature, since EditorToolbar.swift calls it.

   ```swift
   func run(project: EditingProject, timelineID: UUID, renderer: RenderScheduler) {
       let format = format
       let timelineName = project.timeline(id: timelineID)?.name ?? timelineName
       // A second export of the project is told apart by its timeline.
       let baseName = isRunning && !timelineName.isEmpty ? "\(project.name) \(timelineName)" : project.name
       guard let url = chooseDestination(format == .wavStems ? "\(baseName) Stems" : baseName, format) else { return }

       // the `defaults` and `let job = Job(...)` lines, unchanged

       // Read after the panel: what runs now decides start or queue.
       add(job, clearingOutcomes: !isRunning, renderer: renderer)
   }

   /// Asks where to save an export in `format`, suggesting `name`: a file,
   /// or for stems a new folder. Nil when the person cancels.
   static func askWhereToSave(suggesting name: String, format: ExportFormat) -> URL? {
       let panel = NSSavePanel()
       // the `switch format { ... }` that sets the content types, unchanged
       panel.nameFieldStringValue = name
       return panel.runModal() == .OK ? panel.url : nil
   }

   /// Starts `job`, or queues it while another export runs; `renderer`
   /// pauses until the last has ended. `clearingOutcomes` first drops how
   /// the exports before it ended.
   func add(_ job: Job, clearingOutcomes: Bool, renderer: RenderScheduler) {
       self.renderer = renderer
       if clearingOutcomes { outcomes = [] }
       if isRunning {
           queue.append(job)
       } else {
           renderer.setExporting(true)
           start(job)
       }
   }
   ```

   This behaves exactly as before: `clearingOutcomes` is `!isRunning`
   read after the panel, as the old code read it. Item 5 fixes that.

5. In `ended(_:_:)`, replace the two comment lines, `show()` and
   `NSApp.requestUserAttention(...)` with `announceEnd(self)`. Keep
   `guard outcome != nil else { return }` and its comment.

6. Create Tests/AnimationMeetsVideoTests/Support/ExportQueueSupport.swift:

   ```swift
   import Foundation
   import Testing
   @testable import AnimationMeetsVideo

   /// A job exporting `project`'s root timeline, as `ExportWindow.run`
   /// builds one once the save panel answers `file`.
   @MainActor
   func exportJob(_ timeline: String = "Main", as format: ExportFormat = .proRes422, to file: String,
                  project: EditingProject = .empty) -> ExportWindow.Job {
       ExportWindow.Job(
           project: project, timelineID: project.rootTimelineID, timelineName: timeline, format: format,
           loudness: .asMixed, audioTracks: .mix, destination: URL(filePath: "/tmp/amv-export-tests/\(file)")
       )
   }

   /// Stands in for the exporters behind `ExportWindow.perform`: each
   /// export runs until the test finishes, fails or stops it, and writes
   /// nothing, so a queue can be stepped through one export at a time.
   @MainActor
   final class StandInExports {
       private enum Ending { case finish(String?), fail(String) }
       private struct Failure: LocalizedError { let errorDescription: String? }

       /// The jobs started, in order, as `perform` was given them.
       private(set) var started: [ExportWindow.Job] = []
       private var endings: [ExportWindow.Job.ID: Ending] = [:]
       private var progress: [ExportWindow.Job.ID: @Sendable (Double) -> Void] = [:]

       func hasStarted(_ id: ExportWindow.Job.ID) -> Bool { started.contains { $0.id == id } }
       func finish(_ id: ExportWindow.Job.ID, report: String? = nil) { endings[id] = .finish(report) }
       func fail(_ id: ExportWindow.Job.ID, _ message: String) { endings[id] = .fail(message) }
       /// Reports `fraction` as export `id` does, even after it has ended,
       /// as a last progress hop can.
       func report(_ fraction: Double, from id: ExportWindow.Job.ID) { progress[id]?(fraction) }

       func run(_ job: ExportWindow.Job, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
           started.append(job)
           self.progress[job.id] = progress
           while true {
               switch endings[job.id] {
               case .finish(let report): return report
               case .fail(let message): throw Failure(errorDescription: message)
               // Throws CancellationError once the export is stopped.
               case nil: try await Task.sleep(for: .milliseconds(2))
               }
           }
       }
   }

   /// An Export window whose exporters, save panel and end announcement
   /// are stood in for, so its queue runs in a test with no window, panel,
   /// alert or file.
   @MainActor
   final class ExportQueueHarness {
       let export = ExportWindow()
       /// Held here, since the window keeps the editor's renderer weakly.
       let renderer = RenderScheduler()
       let exports = StandInExports()
       /// How often the window was brought back as the exports ended.
       private(set) var announced = 0
       /// The names the save panel was offered, in order.
       private(set) var suggestedNames: [String] = []
       /// What the save panel answers, given the name it suggests; nil is Cancel.
       var answerSavePanel: (String) -> URL? = { _ in
           Issue.record("A save panel was not expected")
           return nil
       }

       init() {
           // Its own, so `ExportWindow.running(packageURL:)` finds only it.
           export.packageURL = URL(filePath: "/tmp/amv-export-tests-\(UUID().uuidString).amv")
           export.perform = { [exports] job, _, progress in try await exports.run(job, progress: progress) }
           export.announceEnd = { [weak self] _ in self?.announced += 1 }
           export.chooseDestination = { [weak self] name, _ in
               guard let self else { return nil }
               suggestedNames.append(name)
               return answerSavePanel(name)
           }
       }

       /// Adds `job` as Export… does once its save panel answers.
       func add(_ job: ExportWindow.Job) {
           export.add(job, clearingOutcomes: !export.isRunning, renderer: renderer)
       }

       /// Clicks Export… for `project`'s root timeline.
       func run(_ project: EditingProject = .empty) {
           export.run(project: project, timelineID: project.rootTimelineID, renderer: renderer)
       }

       /// Waits for `condition`, as the queue moves on between main-actor turns.
       func settle(_ condition: () -> Bool) async throws {
           for _ in 0..<2000 {
               if condition() { return }
               try await Task.sleep(for: .milliseconds(2))
           }
           Issue.record("condition never held")
       }

       /// Stops whatever runs and waits for it to end. Every test ends with
       /// this, so no stand-in export keeps polling.
       func stopAll() async throws {
           export.cancel()
           try await settle { !export.isRunning }
       }
   }
   ```

   `settle` copies the helper in Analysis/AssetAnalysisTests.swift.

7. Create Tests/AnimationMeetsVideoTests/UI/Export/ExportWindowTests.swift.
   The folder is new and mirrors Sources/AnimationMeetsVideo/UI/Export.
   Start it with `import Foundation`, `import Testing`,
   `@testable import AnimationMeetsVideo` and
   `@MainActor @Suite(.serialized) struct ExportWindowTests`. Every test
   begins with `let h = ExportQueueHarness()`. Put these rules in a
   comment at the top of the file:

   - `add` returns before the export's task has run. Wait with
     `try await h.settle { h.exports.hasStarted(a.id) }` before checking
     `started` or calling `report`.
   - End every test with `try await h.stopAll()`, or with the last
     export finished and `!h.export.isRunning` settled.
   - Never call `confirmAndCancel()`, `show()`, `askWhereToSave` or
     `askToStop`, and never call `h.run()` without setting
     `answerSavePanel`. Each opens a real modal.
   - Give each job its own file name. Item 2 refuses a place already
     used.
   - Never count `ExportWindow.runningAnywhere` or `takenDestinations`
     exactly. They are app-wide, and other suites leave windows in them.
     Use `contains`, or `running(packageURL: h.export.packageURL)`.

   Then add these tests. Jobs come from `exportJob`, for example
   `let a = exportJob("Main", to: "A.mov")`.

   - `exportsRunOneAtATimeInTheOrderAsked`: add a, b (Teaser, B.mov)
     and c (Main as `.wavMix`, C.wav). After a starts, `current` is a
     and `queue` is [b, c]. Finish a, settle on `current` being b,
     finish b with report "Raised 5 dB.", settle on c, check
     `announced == 0`, finish c, settle on `!isRunning`. Expect
     `started` in order a, b, c, timeline names Main, Teaser, Main, the
     three `.finished` outcomes with b's report, and `announced == 1`.
   - `aRemovedExportNeverStarts`: add a, b, c; `remove(b.id)`, then
     `remove(a.id)`, which does nothing since a runs. Expect `current`
     a and `queue` [c]. Finish both; expect `started` [a, c] and two
     outcomes.
   - `cancellingStopsTheExportAndEmptiesTheQueue`: add a and b, wait
     for a to start, `h.export.cancel()`. `queue` is empty at once.
     Settle on `!isRunning`. Expect `started` [a], no outcomes,
     `announced == 0` and `!h.renderer.isExporting`.
   - `aFailedExportIsNotedAndTheNextStarts`: add a, b;
     `fail(a.id, "The disk is full.")`; settle on b. Expect
     `outcomes.map(\.outcome) == [.failed("The disk is full.")]`.
     Finish b; expect two outcomes and `announced == 1`.
   - `renderingWaitsFromTheFirstExportToTheLast`: `isExporting` is
     false; add a, true; add b; finish a, still true once b runs;
     finish b, false once idle. Add c, true; `stopAll`, false.
   - `outcomesClearOnlyWhenAnExportStartsWithNoneRunning`: add a,
     finish, settle; one outcome. Add b: outcomes empty. Add c behind
     it, finish b, settle on c: outcomes are b's only. `stopAll`: still
     one.
   - `eachExportStartsAtNoProgress`: add a, b; once a starts,
     `report(0.5, from: a.id)` and settle on `progress == 0.5`. Finish
     a, settle on b: `progress == 0`. `stopAll`.
   - `aSecondExportIsToldApartByItsTimeline`: `answerSavePanel` returns
     nil. `h.run()`; set `format = .wavStems` and `h.run()`; set
     `format = .proRes422`, add `exportJob(to: "A.mov")`, `h.run()`.
     Expect `suggestedNames` to be "Untitled Project", "Untitled
     Project Stems" and "Untitled Project Main" (`EditingProject.empty`
     is named "Untitled Project", its timeline "Main"). The queue stays
     empty, since Cancel adds nothing. `stopAll`.
   - `anExportSavedWhileOneRunsIsQueuedAsPicked`: add a; answer the
     panel with /tmp/amv-export-tests/B.wav; set `format = .wavMix`;
     `h.run()`. `queue.first` has that destination, `.wavMix` and
     timeline Main, and a still runs. `stopAll`.

**Verify.**

```sh
swift build
for i in 1 2 3 4 5; do swift test --filter ExportWindowTests || break; done
swift test --filter "RenderPlanTests|RenderCacheTests|RenderSchedulerTests"
swift test
grep -n "NSSavePanel\|runModal\|requestUserAttention" Sources/AnimationMeetsVideo/UI/Export/ExportWindow.swift
```

The grep should list only `askToStop`, `askWhereToSave` and the
`announceEnd` default. A hang in `swift test` means a test reached a
real modal.

**In the app.** Export a WAV Mix with a loudness target and queue a
ProRes export behind it. Both finish, the window comes back once with
both lines, and the Dock bounces once. Cancel in the save panel adds
nothing, and Stop Export… still asks.

**Commit.** `Let tests run the export queue without modals`. In the
body, say what stays untested: the alert and panel themselves, the
quit and close flows in App/, and the exporters, which have their own
suites. Don't try to run a modal's nested run loop in a test.

### 2. Keep queued exports from saving over each other

- [x] Done. **Decision**: see the table.

**Why.** This is the most serious defect: silent loss of a finished
file. Nothing checks the place picked in the save panel against the
exports under way or waiting. Every exporter deletes what is at its
destination before writing: `CompositionExporter.export` (about line
432), `AudioExport.exportMix` (about line 86) and each stem (about line
127). The default name repeats: queuing Main twice suggests "Trailer
Main" both times. The file doesn't exist yet, so the panel doesn't ask
to replace it, and the later job deletes the earlier one's finished
file. Both report success. Each editor has its own ExportWindow, so
the check has to cover every window in the app.

**Depends on** item 1, for the `chooseDestination` seam and the
harness.

**Steps, for the recommended choice.**

1. Export/AudioExport.swift: give `ExportFormat` an extension, right
   after `var movie`:

   ```swift
   /// The extension the save panel gives the file; nil for stems, which
   /// are saved in a folder.
   var fileExtension: String? {
       switch self {
       case .proRes422, .proRes4444: "mov"
       case .wavMix: "wav"
       case .wavStems: nil
       }
   }
   ```

2. Create Export/ExportDestinations.swift. It is non-UI logic, so it
   goes in Export/, not UI/:

   ```swift
   import Foundation

   /// Where exports save, kept apart. Each exporter deletes what is at its
   /// destination before writing (`CompositionExporter.export`,
   /// `AudioExport.exportMix`, each stem in `AudioExport.exportStems`), so
   /// an export to a place one under way or queued saves to would delete
   /// that one's file. A WAV Stems export's destination is its folder.
   enum ExportDestinations {
       /// The destination in `taken` that is the same place as `url`, or nil.
       /// Paths are compared without case, as the Mac's volumes are by
       /// default. Symlinks aren't resolved: `resolvingSymlinksInPath` treats
       /// a file that exists differently from one not written yet.
       static func conflict(for url: URL, among taken: [URL]) -> URL? {
           let wanted = key(url)
           return taken.first { key($0) == wanted }
       }

       /// `base`, or "`base` 2", "`base` 3" and on: the first that, with
       /// `fileExtension` (nil for a folder), is no name in `taken`. The
       /// save panel's folder isn't known before it opens, so a name taken
       /// in any folder is skipped.
       static func freeName(_ base: String, fileExtension: String?, avoiding taken: [URL]) -> String {
           let names = Set(taken.map { $0.lastPathComponent.lowercased() })
           func file(_ name: String) -> String {
               (fileExtension.map { "\(name).\($0)" } ?? name).lowercased()
           }
           var candidate = base
           var number = 2
           while names.contains(file(candidate)) {
               candidate = "\(base) \(number)"
               number += 1
           }
           return candidate
       }

       private static func key(_ url: URL) -> String {
           url.standardizedFileURL.path.lowercased()
       }
   }
   ```

3. UI/Export/ExportWindow.swift, after `runningAnywhere`:

   ```swift
   /// Where every export in the app under way or waiting saves, which a
   /// new one mustn't (`ExportDestinations`).
   static var takenDestinations: [URL] {
       all.allObjects.flatMap { [$0.current].compactMap { $0 } + $0.queue }.map(\.destination)
   }
   ```

   Read `all.allObjects`, not `runningAnywhere`. After item 9,
   `runningAnywhere` skips exports that are stopping, and a stopping
   export still deletes its partial file at that path.

4. Add a seam for the refusal next to `chooseDestination`, so the test
   doesn't hit a real alert:

   ```swift
   /// Tells the person why Export… did nothing: an alert, which a test reads.
   @ObservationIgnored var tell: @MainActor (_ title: String, _ message: String) -> Void = {
       ProjectSession.showAlert(title: $0, message: $1)
   }
   ```

   In `ExportQueueHarness`, add `private(set) var told: [String] = []`
   and, in `init`, `export.tell = { [weak self] _, message in self?.told.append(message) }`.

5. In `run()`, pass the suggested name through `freeName`, and check
   the answer before the job is built:

   ```swift
   let suggested = format == .wavStems ? "\(baseName) Stems" : baseName
   // Never the name of one under way or waiting, which this one would
   // delete (`ExportDestinations`).
   let name = ExportDestinations.freeName(suggested, fileExtension: format.fileExtension, avoiding: Self.takenDestinations)
   guard let url = chooseDestination(name, format) else { return }
   // Read after the panel: exports may have ended while it was open.
   if ExportDestinations.conflict(for: url, among: Self.takenDestinations) != nil {
       tell(
           "Couldn't Export",
           "An export under way or waiting already saves to \u{201C}\(url.lastPathComponent)\u{201D}, and this one would replace it. Choose another name or place, or take that export out of the queue first."
       )
       return
   }
   ```

6. Update the exporter comments. In CompositionExporter.swift, the two
   lines starting "The save panel already confirmed replacing" become:

   ```swift
   // The save panel confirmed replacing a file already there, and the
   // Export window refuses a place another export under way or queued
   // saves to (`ExportDestinations`); AVAssetExportSession refuses to
   // write over a file, so what is there goes.
   ```

   Above the `removeItem` in `AudioExport.exportMix`, add
   `// Replacing it was confirmed, and no other export saves here (see CompositionExporter.export).`

7. docs/audio.md, in the paragraph about queuing (about lines
   303-310): after the sentence ending "from when it was asked for."
   (about line 307), add: "The name it suggests skips those of the
   exports under way or waiting, and a place one of them already saves
   to is refused, since each export clears its destination before
   writing (`ExportDestinations`)." Don't put it after "asking where to
   save it as usual", where it would split a colon clause.

8. Tests. Create Tests/AnimationMeetsVideoTests/Export/ExportDestinationsTests.swift
   (`@Suite struct ExportDestinationsTests`, Swift Testing as in
   AudioExportTests). The logic is pure, so no files are needed. Use a
   folder such as `URL(filePath: "/Volumes/Work/Exports", directoryHint: .isDirectory)`.
   - `conflict` finds "Trailer Main.mov" given "trailer main.mov", and
     given `folder.appending(path: "./Trailer Main.mov")`.
   - `conflict` is nil for "Trailer Main.wav" against "Trailer
     Main.mov", and for the same name in another folder.
   - A stems folder "Trailer Main Stems" conflicts with the same URL.
   - `freeName("Trailer Main", fileExtension: "mov", …)` with "Trailer
     Main.mov" and "Trailer Main 2.mov" taken is "Trailer Main 3"; with
     `fileExtension: "wav"` it is "Trailer Main".
   - `freeName("Trailer Main Stems", fileExtension: nil, …)` with that
     folder taken is "Trailer Main Stems 2".
   - `freeName("Trailer", fileExtension: "mov", avoiding: [])` is
     "Trailer".

   In ExportWindowTests:
   - `takenDestinationsListEveryExportUnderWayOrWaiting`: add two jobs
     with UUID file names; `takenDestinations` contains both. After
     `stopAll`, it contains neither.
   - `theSuggestedNameSkipsOnesUnderWayOrWaiting`: a project named
     "Trailer <UUID>"; add jobs to "<name>.mov" and "<name> Main.mov";
     the panel answers nil; `h.run(project)`. The last suggested name
     is "<name> Main 2".
   - `aPlaceInUseIsRefused`: add a; the panel answers `a.destination`;
     `h.run()`. The queue stays empty and `told.count == 1`.

**Verify.**

```sh
swift test --filter ExportDestinationsTests
swift test --filter AudioExportTests
swift test --filter ExportWindowTests
swift test
```

**In the app.** With a long ProRes 4444 export running: Export… again
suggests "<Project> Main"; save it. Export… again suggests "<Project>
Main 2"; cancel. Typing "<Project> Main" by hand gets the "Couldn't
Export" alert, and the queue keeps one entry. Picking the running file
asks to replace it, then gets the alert. Once all have ended, every
file shown as saved exists in Finder.

**Commit.** `Keep queued exports from saving over each other`. In the
body, say that the exporters clear their destination before writing,
so a shared destination deleted an earlier export's file.

### 3. Refit a queued export's package effects on start

- [x] Done. **Decision**: see the table.

**Why.** A release build can crash. Each queued `Job` holds a copy of
the project. When an effect package changes on disk,
`EffectPackageStore.reloadNow` fits only the open sessions, not the
queued copies. The renderer reads the package from the live registry
when it draws (`step.kind.definition.package`, LookKernels.swift about
line 172), so old-shaped values meet a new-shaped package. In debug
that trips the assert in `PackageLookRenderer.Values.value`
(PackageLooks.swift about line 316). In release `center()` reads
`offset[1]` past the end (about line 328) and the app traps. Other
shape changes make the kernel reject its arguments, and the export
lacks the effect. Example: queue "Trailer" behind a long export, then
change one of its package's controls from a number to a two-component
vector.

**Depends on** item 1, which moved the exporter calls into `write`.

**Steps.**

1. In `struct Job`, after `let destination: URL`:

   ```swift
   /// The project to export: as it was asked for, its package effects
   /// fitted to their packages as they are now
   /// (`EditingProject.fitPackageEffects`). A package changed while the
   /// job waited fitted the open project (`ProjectSession.fitPackageEffects`)
   /// but not this copy, and the renderer reads the package as it is.
   var projectToExport: EditingProject {
       var project = project
       project.fitPackageEffects()
       return project
   }
   ```

   Pass no `newSince:`. Fitting is idempotent, so a project that is
   already fitted doesn't change. Undo fits restored snapshots the same
   way (ProjectHistory.swift about line 156).

2. Make `let project = job.projectToExport` the first line of
   `write(_:cache:progress:)`. In `write`, replace all four uses of
   `job.project` with `project`, including `named: job.project.name`
   in the stems call. This runs off the main actor, which is safe:
   `fitPackageEffects` reads `EffectRegistry.current` under its lock
   (Model/Effects/EffectRegistry.swift about line 84). Leave
   `Job.project` itself unchanged; the window lists the job from it.

3. Don't call `ProjectSession.fitPackageEffects`, which changes the
   live session and its undo history. Don't make EffectPackageStore
   (Project/) call into ExportWindow (UI/).

4. docs/effect-packages.md (about lines 429-431): change "Undo fits each
   step it restores the same way, as does pasting an effect copied
   before the change, so an old value never reaches the renderer." to
   "Undo fits each step it restores the same way, as do pasting an
   effect copied before the change and starting an export queued
   before it (`ExportWindow.Job.projectToExport`), so an old value
   never reaches the renderer." With the recommended choice, add a
   sentence after it: an export already running when a package changes
   isn't fitted, which isn't handled yet. Rewrap.

5. docs/audio.md (about lines 305-306): after "and the project as it
   was, from when it was asked for", add ", its package effects fitted
   when it starts to any effect package changed meanwhile". Rewrap.

6. Test. In Tests/AnimationMeetsVideoTests/Project/ReloadingEffectPackagesTests.swift,
   add this after `aNumberThatBecomesTwoIsResetInOpenProjects`, whose
   private helpers `write`, `read`, `kernel` and `folder` it reuses.
   Don't draw the unfitted effect: in a debug build the assert would
   crash the test run.

   ```swift
   @Test @MainActor func aQueuedExportIsFittedWhenItStarts() throws {
       defer { try? FileManager.default.removeItem(at: folder) }
       let url = try write()
       let installed = try EffectPackageStore.read(url)
       let running = EffectRegistry.withBuiltIns([installed])
       let strength = ControlKind(package: "com.example.tint", control: "strength")
       var project = EditingProject.empty
       let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
       let shape = try #require(created)
       EffectRegistry.$override.withValue(running) {
           project.editClip(shape.clipID, in: project.rootTimelineID) { $0.effects.append(Effect(kind: installed.kind)) }
       }
       let job = ExportWindow.Job(
           project: project, timelineID: project.rootTimelineID, timelineName: "Main", format: .proRes422,
           loudness: .asMixed, audioTracks: .mix, destination: URL(filePath: "/tmp/queued.mov")
       )
       // While it waits, Strength becomes two numbers.
       let pair: [[String: Any]] = [["id": "strength", "name": "Strength", "type": "vector", "components": ["A", "B"], "default": [1, 2]]]
       try write(controls: pair, kernel: kernel().replacingOccurrences(of: "float strength", with: "float2 strength"))
       let (reloaded, _) = running.reloading(url, as: read(url))
       try EffectRegistry.$override.withValue(reloaded) {
           let exported = job.projectToExport
           let effect = try #require(exported.clipAndLayer(shape.clipID, in: exported.rootTimelineID)?.clip.effects.last)
           #expect(effect.control(strength)?.values(at: .zero) == [1, 2])
           let step = try #require(LookStep(effect, at: .zero))
           #expect(step.numbers[strength] == [1, 2])
           let frame = CGRect(x: 0, y: 0, width: 4, height: 4)
           _ = LookRenderer.apply(step, to: CIImage(color: .red).cropped(to: frame), over: frame, canvas: frame, frame: frame, scale: 1, space: .rec709)
           // The queued copy itself is left as it was asked for.
           let queued = try #require(job.project.clipAndLayer(shape.clipID, in: job.project.rootTimelineID)?.clip.effects.last)
           #expect(queued.control(strength)?.values(at: .zero).count == 1)
       }
   }
   ```

   If a helper's signature differs from what this assumes, follow
   `aNumberThatBecomesTwoIsResetInOpenProjects`, which sets up the same
   change.

**Verify.**

```sh
swift test --filter ReloadingEffectPackagesTests
swift test --filter PackageLookTests
swift test
```

**In the app.** Start a long export, then queue a timeline that uses an
effect package from your Effects folder. Change one of that package's
controls in its manifest from a number to a two-component vector. The
queued export starts and finishes without a crash.

**Commit.** `Refit a queued export's package effects on start`. In the
body, say that reloads fit only open sessions, and that the renderer
reads the live package.

### 4. Keep each composition's matte wipe maps its own

- [x] Done

**Why.** `MatteMaps.shared` is one table for the whole app, holding one
frame per asset ID. Every composition build reloads it from the project
it is given, and `TransitionRenderer.matteMap` reads it when it draws.
So the last build wins. Example: Replace Media on a matte wipe's map
video while an export waits. When the queued export starts, it loads
the old frame back. The viewer then shows the stale map, and the
viewer's next rebuild loads the new one, which switches the export's
map partway through the file. Cached renders are not reused wrongly,
because rendering stays paused while exports run. Part of this is
older than the queue: a single running export already switched maps
when the viewer rebuilt.

Keying the shared table by asset ID plus file stamp doesn't fix this
alone: at draw time `TransitionRenderer` knows only the asset ID. So
each build keeps the frames it loaded, carried on its instructions, and
`MatteMaps.shared` becomes only a decode cache. Expect about 50 changed
lines in 5 source files, about 70 lines of tests, and one doc paragraph.

**Steps.**

1. Rendering/Compositor/MatteMaps.swift: add above `final class MatteMaps`:

   ```swift
   /// The matte wipe maps one composition was built with, by asset ID: its
   /// instructions draw with these, whatever a later build loads.
   /// CIImage is immutable, so it is shared across the compositor's queues.
   struct MatteMapSet: @unchecked Sendable {
       var images: [UUID: CIImage] = [:]
       /// What each was loaded from, for the render key.
       var stamps: [UUID: String] = [:]
   }
   ```

   Delete `image(for:)`, `stamp(for:)` and `store(_:for:)`. Make
   `load(for:)` return `MatteMapSet`. Keep its scan of wanted maps and
   its stamp string exactly as they are, so render keys don't change.
   Create `var loaded = MatteMapSet()`, and replace the cache check
   with:

   ```swift
   if let kept = entries.withLockUnchecked({ $0[id] }), kept.stamp == stamp {
       loaded.images[id] = kept.image
       loaded.stamps[id] = stamp
       continue
   }
   ```

   After a decode, keep the cache write and also set
   `loaded.images[id]` and `loaded.stamps[id]`. End with
   `return loaded`. A map that can't be read stays out of the set, so
   it draws noise and keys as "noise", as now. Rewrite the type comment:
   the class is a cache of the latest version read of each map, and
   each build keeps its own `MatteMapSet`.

2. Export/CompositionExporter.swift, in `buildComposedTimeline`: make
   it `let mattes = await MatteMaps.shared.load(for: project)`, and pass
   `mattes: mattes` as the last argument of `planRanges(...)` and of
   both `Self.buildVideoComposition(...)` calls.

3. Export/CompositionPlanning.swift:
   - `planRanges(`: add a last parameter
     `mattes: MatteMapSet = MatteMapSet()`, and pass `mattes: mattes`
     to its `renderKey(` call.
   - `renderKey(`: add `mattes: MatteMapSet = MatteMapSet()` after
     `reusingStillFrames:`. The line that appends the matte stamp
     (about line 229) becomes `text += " \(mattes.stamps[id] ?? "noise")"`.
   - `buildVideoComposition(`: add `mattes: MatteMapSet = MatteMapSet()`
     after `background:`, and pass `mattes: mattes` to its
     `LayeredInstruction(` call.

4. Rendering/Compositor/LayeredCompositor.swift:
   - `LayeredInstruction`: add `let mattes: MatteMapSet` with the doc
     comment "The matte wipe maps of the build it is part of
     (`MatteMaps.load`).", an init parameter
     `mattes: MatteMapSet = MatteMapSet()` after `decodedOnly:`, and
     `self.mattes = mattes`. Pass `mattes: mattes` at the end of the
     init call in `func drawing(`. Every copy of an instruction goes
     through `drawing(...)`, so all keep the set.
   - `struct Drawing`: add `var mattes = MatteMapSet()` after
     `var keeping`, with the doc comment "The maps matte wipes draw
     with." In `compose`, pass `mattes: instruction.mattes,` between
     `keeping:` and `source:`, since the memberwise init follows the
     declaration order.
   - Pass `mattes: mattes` after `in: bounds` in the
     `TransitionRenderer.draw(` call.

5. Rendering/Transitions/TransitionRenderer.swift: give `draw(` a last
   parameter `mattes: MatteMapSet = MatteMapSet()` and pass it to
   `matteMap(options.matte, in: bounds, mattes: mattes)`. Make
   `matteMap` take `mattes: MatteMapSet` and read `mattes.images[id]`
   in place of `MatteMaps.shared.image(for: id)`. Update its doc
   comment to "a video's frame from `mattes`".

6. Tests/AnimationMeetsVideoTests/Rendering/TransitionRendererTests.swift:
   give `RenderProbe.draw(` a last parameter
   `mattes: MatteMapSet = MatteMapSet()` and pass it on. Rewrite
   `aMatteWipeRevealsTheBrightPartsOfItsMapFirst` without
   `MatteMaps.shared.store`:

   ```swift
   let id = UUID()
   var options = TransitionKind.matteWipe.defaultOptions
   options.matte = .clip(id)
   let early = probe.draw(.matteWipe, 0.3, from: probe.solid(1, 0, 0), to: probe.solid(0, 0, 1), options: options,
                          mattes: MatteMapSet(images: [id: probe.halves]))
   ```

   Keep its two `#expect` lines.

7. New Tests/AnimationMeetsVideoTests/Rendering/MatteMapsTests.swift
   (`@Suite struct MatteMapsTests`). Use `writeMovie(to:segments:)`
   from Analysis/Scenes/FrameScorerTests.swift and
   `RenderProbe().pixel(_:x:y:)`. In a temporary folder, write
   dark.mov with `[(luma: 40, frames: 24)]` and light.mov with
   `[(luma: 220, frames: 24)]`. Helper:

   ```swift
   private func project(mapping map: URL) throws -> (project: EditingProject, mapID: UUID) {
       var project = EditingProject.empty
       let media = MediaClip(name: "map", kind: .video, url: map, duration: CMTime(value: 24, timescale: 24),
                             frameRate: 24, colorSpace: .rec709, codecName: "H.264")
       let placed = project.importClip(media, intoTimeline: project.rootTimelineID)
       let ids = try #require(placed)
       var options = TransitionKind.matteWipe.defaultOptions
       options.matte = .clip(media.id)
       project.editClip(ids.clipID, in: project.rootTimelineID) {
           $0.transitionIn = ClipTransition(kind: .matteWipe, duration: CMTime(value: 1, timescale: 2), options: options)
       }
       return (project, media.id)
   }
   ```

   - `aNewerVersionOfAMapLeavesTheOneLoadedBeforeAsItWas`: `old`
     points at dark.mov; `new` is a copy with that clip's `url` set to
     light.mov, as Replace Media does. With a private `MatteMaps()`,
     load `old`, then `new`. The stamps differ, the old set's centre
     pixel has green below 80, and the new set's above 180.
   - `aCompositionKeepsTheMapsItWasBuiltWith`: build `old` with
     `CompositionExporter.buildComposedTimeline`, then build `new` with
     `forPreview: true`. The first composition's first
     `LayeredInstruction` still has the dark map: green below 80.

8. docs/transitions.md, the Matte Wipe bullet (about lines 124-128):
   replace the sentences after "or a video's first frame." with "Video
   frames are loaded while the composition is built (`MatteMaps`),
   since the compositor draws synchronously, and each composition keeps
   those it was built with (`MatteMapSet`, on its instructions): a
   later build reading another version of the file, as the viewer's
   does after Replace Media while an export runs or waits, doesn't
   change it. The latest version read of each is kept for the next
   build. That file's stamp is part of the render key. A map that can't
   be read falls back to noise."

**Verify.**

```sh
swift build
grep -rn "MatteMaps.shared.image\|MatteMaps.shared.stamp\|MatteMaps.shared.store" Sources Tests
swift test --filter MatteMapsTests
swift test --filter TransitionRendererTests
swift test --filter TransitionCompositionTests
swift test --filter "TransitionFrameKeyTests|EdgeTransitions"
swift test --filter "RenderPlanTests|RenderCacheTests|RenderSchedulerTests"
swift test --filter LiveRedrawTests
swift test --filter PlayheadPrerendererTests
swift test
```

The grep must print nothing.

**In the app.** In a project with a Matte Wipe whose map is a video,
start a long export, then Replace Media on the map video. The viewer
shows the new map at once, and the exported file shows the old map from
start to end.

**Commit.** `Keep each composition's matte wipe maps its own`. In the
body, say that the shared table let the last build win for the viewer
and every export, that keying by stamp alone can't work because drawing
knows only the asset ID, and that a decode is repeated after another
version loads.

### 5. Keep outcomes that end behind the save panel

- [x] Done

**Why.** `run()` reads `isRunning` again after the save panel returns,
to decide whether the new export clears the old outcomes. The panel is
modal but keeps the main actor running. If the queue ends while it is
up, `ended()` shows how the last export ended and brings the window
back. Then the new export counts as a fresh start, and
`outcomes = []` wipes that line before anyone reads it. Deciding start
or queue from the state after the panel is right; only the clearing is
wrong.

**Depends on** item 1, for `add`.

**Steps.**

1. In `run()`, add `let wasRunning = isRunning` before `baseName` is
   built, and use `wasRunning` in the `baseName` line.
2. Change the last line to
   `add(job, clearingOutcomes: !wasRunning, renderer: renderer)`. Keep
   item 2's conflict check between the panel and this line.
3. Update the doc comment on `outcomes`: "How the exports since the
   window was last idle ended, oldest first, cleared once an export
   saved while none ran starts; those that end while its save panel is
   up stay." Update the doc comment on `add` to match.
4. Tests in ExportWindowTests:
   - `outcomesClearWhenTheWindowWasIdleAsExportWasClicked`: add a,
     finish it, settle on `!isRunning`; there is one outcome. Set
     `h.answerSavePanel = { [weak h] _ in guard let h else { return nil }; h.export.add(b, clearingOutcomes: false, renderer: h.renderer); return URL(filePath: "/tmp/amv-export-tests/C.mov") }`,
     which starts b while the panel is up without clearing, and call
     `h.run()`. Expect no outcomes, because the window was idle when
     Export… was clicked, and one queued job. Before the fix the outcome
     is kept. `stopAll`.
   - `anExportSavedWhileOneRunsKeepsHowTheLastEnded`: with one
     outcome shown, `h.export.add(x, clearingOutcomes: false, renderer: h.renderer)`
     keeps it.

   A test can't end an export inside the stand-in panel, since the
   stand-in needs the main actor the panel holds. The in-app check
   covers that case.

**Verify.** `swift test --filter ExportWindowTests`, then `swift test`.

**In the app.** Start an export about 20 seconds long, click Export…
again, and leave the save panel up until the first ends. Click Save.
The first's line stays above the new progress.

**Commit.** `Keep outcomes that end behind the save panel`. In the body,
say that the modal panel lets the queue end, and why the default name
is left alone.

### 6. Stop only the export the question was about

- [x] Done

**Why.** `confirmAndCancel()` words its alert from `current`, then
cancels whatever `task` holds once the alert closes. The modal alert
keeps the main actor running, so the export asked about can finish
while it is up, and `ended()` starts the next queued one. Clicking Stop
Export then stops that next export, which the person never agreed to,
and deletes its partial file.

**Depends on** item 1, for the harness tests.

**Steps.**

1. In ExportWindow.swift, after `confirmAndCancel()`:

   ```swift
   /// Stops the export `id` if it is still the one under way; the next one
   /// waiting starts. False when it has already ended.
   @discardableResult func stop(_ id: Job.ID) -> Bool {
       guard current?.id == id else { return false }
       task?.cancel()
       return true
   }
   ```

2. Replace the body of `confirmAndCancel()` with:

   ```swift
   guard let asked = current, Self.askToStop([asked], because: "Stopping") else { return }
   // The question keeps the main actor running, so `asked` may have ended
   // while it was up and the next one started, which goes on.
   stop(asked.id)
   ```

   Its doc comment becomes "Stops the export under way once the person
   agrees to, unless it ended while they were asked; the next one
   waiting starts." Keep the name `confirmAndCancel`: ExportView calls
   it and item 8's doc names it. If the export asked about has already
   ended, do nothing more. Its line is already in the window.

3. Tests in ExportWindowTests:
   - `stoppingTheExportUnderWayStartsTheNext`: add a, b; once a
     starts, `h.export.stop(a.id)` is true. Settle on b. Expect
     `started` [a, b], no outcomes, `renderer.isExporting` and
     `announced == 0`. Finish b, settle: `announced == 1`.
   - `stoppingAnExportThatHasEndedLeavesTheNextGoing`: add a, b; finish
     a; settle on b. `h.export.stop(a.id)` is false. Sleep 30 ms; b
     still runs and `started.count == 2`. `stopAll`.

**Verify.** `swift test --filter ExportWindowTests`, then `swift test`.

**In the app.** Start an export about 20 seconds long with a second
queued. Click Stop Export… and leave the alert up until the first would
have finished, then click Stop Export. The second keeps exporting, and
the first's line shows.

**Commit.** `Stop only the export the question was about`. In the body,
say that the alert's modal loop lets the export end and the next start.

### 7. Drop progress from an export that has ended

- [x] Done

**Why.** The progress callback hops to the main actor with an unkeyed
`Task { @MainActor in self.progress = fraction }`. Hops queued just
before an export ends can run after `start(next)` set `progress = 0`.
The window's bar and the toolbar's then show the new export near 100%
until its own first update arrives.

**Steps.**

1. In ExportWindow.swift, next to `remove(_:)`:

   ```swift
   /// Shows `fraction` as the progress of the export `id`, if that is still
   /// the one under way: progress hops to the main actor, so the last hops
   /// of one export can land after the next has started at 0.
   func setProgress(_ fraction: Double, of id: Job.ID) {
       guard current?.id == id else { return }
       progress = fraction
   }
   ```

2. In `start(_:)`, add `let id = job.id` before `task = Task {`, and
   make the progress closure:

   ```swift
   let progress: @Sendable (Double) -> Void = { fraction in
       Task { @MainActor in self.setProgress(fraction, of: id) }
   }
   ```

   Keep `progress = 0` and `current = job` where they are. `current` is
   set before any hop of the new job can run.

3. Tests in ExportWindowTests:
   - `progressFromAnEndedExportIsDropped`: with
     `showQueueWithoutRunning(current: next, progress: 0, queue: [])`,
     `setProgress(0.97, of: ended.id)` leaves 0, and
     `setProgress(0.3, of: next.id)` gives 0.3.
   - `lateProgressFromAnEndedExportIsDropped`: add a, b; finish a;
     once b starts, `report(0.25, from: b.id)` and settle on 0.25. Then
     `report(0.97, from: a.id)` and sleep 30 ms: still 0.25. `stopAll`.

**Verify.** `swift test --filter ExportWindowTests`. The race is too
short to see in the app, so there is no check there.

**Commit.** `Drop progress from an export that has ended`.

### 8. Name what asks before Stop Export in the docs

- [x] Done

**Why.** docs/audio.md (about lines 312-316) and the ExportWindow type
comment (about lines 12-15) say `confirmStopping` confirms Stop
Export…. Since bd7bdc6 the button goes through `confirmAndCancel`,
which asks through `askToStop` and keeps the queue. `confirmStopping`
serves only closing a window or project and quitting, and it empties
the queue. Someone following the doc to change the button would edit
the wrong function.

**Steps.**

1. docs/audio.md: replace that paragraph with the following, wrapped
   at about 72 columns, keeping the real ellipsis character:

   "Stopping an export, or closing its project's window or quitting
   while it runs, asks first, since what was exported so far is
   deleted. Stop Export… asks about the one under way and stops it, and
   the next waiting starts (`ExportWindow.confirmAndCancel`); closing
   the project or quitting asks once about all of them and stops the
   queue too (`ExportWindow.confirmStopping`)."

2. ExportWindow.swift: the type comment's last sentence ("Stopping an
   export, or closing the project or quitting while one runs, asks
   first (`confirmStopping`).") becomes:

   ```swift
   /// Export… while one runs queues the timeline the editor shows then, in
   /// the format and sound picked then, to start once those before it end;
   /// the queue is listed in the window. Stop Export… asks first and stops
   /// the one under way, and the next starts (`confirmAndCancel`); closing
   /// the project or quitting while one runs asks once and stops the queue
   /// too (`confirmStopping`).
   ```

3. Leave the comment in EditorView.swift (about line 201) alone: it is
   about a project's window closing, which does go through
   `confirmStopping`.

**Verify.** `grep -rn "confirmStopping\|confirmAndCancel" docs Sources`:
Stop Export… must point to `confirmAndCancel`, and close or quit to
`confirmStopping`. Then `swift build`.

**Commit.** `Name what asks before Stop Export`. In the body, say that
bd7bdc6 moved the button to `confirmAndCancel` and the doc still named
`confirmStopping`.

### 9. Stop exports only once a close or quit goes ahead

- [x] Done

**Why.** `confirmStopping` asks, then at once cancels every export and
empties every queue. Quitting and closing a project ask more questions
after it, and those can still be cancelled. Example: export Main with
two timelines queued and a Beat Match draft open. Press Cmd-Q, answer
Stop Export, then Keep Editing. The app stays open, the running export
is gone with its partial file, and the queued ones are gone with no
notice. Closing a project with unsaved changes, then cancelling the
save question, does the same.

The fix keeps the export question first, as one alert that counts every
job. Only the moment the exports stop moves, to the point where the
close or quit can no longer be called off. Asking about exports last
was rejected: a draft panel discards its draft before the later
questions run.

**Depends on** items 1 and 8.

**Steps.**

1. ExportWindow.swift, next to `task`:

   ```swift
   /// Set once the export under way and those queued behind it are told to
   /// stop (`cancel`), until it has ended, so one winding down isn't asked
   /// about again, as when closing the last window quits the app.
   @ObservationIgnored private var isStopping = false
   ```

   `isRunning` stays true until the cancelled task's `ended()` runs.
   Without the flag, closing the last project window would ask about
   the same export a second time when the app then quits.

2. Leave stopping exports out of both finders. In
   `running(in:packageURL:)`, the filter starts
   `export.isRunning && !export.isStopping && (…)`. `runningAnywhere`
   becomes `all.allObjects.filter { $0.isRunning && !$0.isStopping }`.
   Leave `takenDestinations` from item 2 on `all.allObjects`.

3. Replace `confirmStopping` with a version that only asks, and add the
   stopping helpers. Drop `private` from `askToStop`, so the default
   argument can refer to it.

   ```swift
   /// The jobs `exports` have under way and queued, in the order they
   /// run, as the question about stopping them counts them.
   static func jobs(of exports: [ExportWindow]) -> [Job] {
       exports.flatMap { export in [export.current].compactMap { $0 } + export.queue }
   }

   /// Asks whether to stop `exports`, which `reason` ("Closing the
   /// project") would, counting each one's export under way and those
   /// queued behind it. Stops nothing: the caller stops them
   /// (`stopExports`) once no later question can keep the window or app
   /// open. True when there are none or the person agrees; false to keep
   /// them going.
   static func confirmStopping(
       _ exports: [ExportWindow], because reason: String,
       ask: ([Job], String) -> Bool = { ExportWindow.askToStop($0, because: $1) }
   ) -> Bool {
       let jobs = jobs(of: exports)
       guard !jobs.isEmpty else { return true }
       return ask(jobs, reason)
   }

   /// Stops `exports` and drops those queued behind them, once closing
   /// can no longer be called off.
   static func stopExports(_ exports: [ExportWindow]) {
       for export in exports { export.cancel() }
   }

   /// Stops every export in the app, those already stopping too, and
   /// returns once each has ended and deleted its partial file, for
   /// quitting to wait on.
   static func stopEverythingAndWait() async {
       let tasks = all.allObjects.compactMap(\.task)
       for export in all.allObjects { export.cancel() }
       for task in tasks { await task.value }
   }

   /// Whether any export in the app has yet to end, stopping or not.
   static var anyUnderWay: Bool { all.allObjects.contains { $0.task != nil } }
   ```

   `stopExports` is named apart from item 6's `stop(_:)`, which stops
   one export and lets the next start.

4. `cancel()`:

   ```swift
   /// Stops the export under way and drops those waiting.
   func cancel() {
       guard isRunning else { return }
       isStopping = true
       queue.removeAll()
       task?.cancel()
   }
   ```

   Leave `confirmAndCancel` and `stop(_:)` alone. They must not set
   `isStopping`, because the next queued export starts.

5. In `ended(_:_:)`, add `isStopping = false` right after
   `task = nil`, at the top. Don't reset it only where `current = nil`:
   an export can be queued while another is stopping, and it must start
   findable.

6. App/ProjectWindows.swift, `shouldTerminate`: keep the export
   question (about line 144) where it is. Stop exports only at the two
   points of no return, and wait for them, so their partial files are
   deleted before the app exits.
   - Replace `guard !unsaved.isEmpty else { return .terminateNow }`
     with:

     ```swift
     guard !unsaved.isEmpty else {
         guard ExportWindow.anyUnderWay else { return .terminateNow }
         Task {
             await ExportWindow.stopEverythingAndWait()
             NSApp.reply(toApplicationShouldTerminate: true)
         }
         return .terminateLater
     }
     ```

   - In the save Task, add `await ExportWindow.stopEverythingAndWait()`
     on the line before `NSApp.reply(toApplicationShouldTerminate: true)`.
     Don't stop anything in the branch that replies false.
   - Update the doc comment: running exports are asked about first, but
     they stop only once the draft panels and save questions have let
     the app quit, so Keep Editing or Cancel keeps them and their queue
     running.

7. App/ProjectWindow.swift, `shouldClose`:

   ```swift
   private func shouldClose(_ window: NSWindow) -> Bool {
       let exports = ExportWindow.running(in: window, packageURL: session.projectURL)
       guard ExportWindow.confirmStopping(exports, because: "Closing the project") else { return false }
       guard session.hasUnsavedChanges, session.projectURL != nil, !session.closeConfirmed else {
           ExportWindow.stopExports(exports)
           return true
       }
       Task {
           let question = "Save changes to \u{201C}\(session.project.name)\u{201D} before closing?"
           guard await session.settleUnsavedChanges(asking: question) else { return }
           // Those running now, which may have moved on since the question.
           ExportWindow.stopExports(ExportWindow.running(in: window, packageURL: session.projectURL))
           session.closeConfirmed = true
           window.close()
       }
       return false
   }
   ```

   Update its doc comment to match.

8. App/TimelineWindow.swift asks nothing after the export question, but
   make the stop explicit there too:

   ```swift
   .background(WindowCloseGuard { window in
       let exports = ExportWindow.running(in: window)
       guard ExportWindow.confirmStopping(exports, because: "Closing the window") else { return false }
       ExportWindow.stopExports(exports)
       return true
   })
   ```

9. Leave EditorView.swift (about lines 200-202) alone. Its
   `exportWindow.cancel()` is still the backstop when an editor goes
   away, and does nothing when idle.

10. docs/audio.md: in item 8's paragraph, replace "closing the project
    or quitting asks once about all of them and stops the queue too
    (`ExportWindow.confirmStopping`)." with "closing the project or
    quitting asks once about all of them (`ExportWindow.confirmStopping`),
    and stops them and the queue only once every other question it asks
    (a draft panel's, saving changes) has let the window or app go
    (`ExportWindow.stopExports`); a Cancel or Keep Editing there leaves
    them running."

11. Tests in ExportWindowTests. Pass `ask:` so no alert opens.
    - `agreeingToStopStopsNothingYet`: current a, queue [b, c] (by
      `showQueueWithoutRunning`). `confirmStopping([export], because: "Quitting") { jobs, _ in asked = jobs; return true }`
      is true, `asked` is a, b, c, and the queue still has two.
    - `keepingExportsAnswersNo`: `ask` returns false; the result is
      false and the queue is intact.
    - `noExportsAsksNothing`: `confirmStopping([], …)` with an `ask`
      that records an issue returns true.
    - `stoppingDropsTheQueueAndIsNotAskedAboutAgain`:
      `running(packageURL:)` finds the window; after
      `stopExports([export])` the queue is empty and it finds nothing.
    - `cancellingAnIdleWindowLeavesItFindable`: `cancel()` on a fresh
      window, then `showQueueWithoutRunning(...)`: it is found.
    - `agreeingToQuitStopsNothingUntilItGoesAhead`, with the harness:
      add a, b; once a starts, `confirmStopping` with `ask` returning
      true is true; after 30 ms a still runs and b waits. Then
      `stopExports([h.export])`: `running(packageURL:)` is empty at
      once. Settle on `!isRunning`. Add c: it is found again. `stopAll`.

**Verify.**

```sh
swift test --filter ExportWindowTests
swift test --filter ProjectDialogsTests
swift test --filter ProjectSessionAutosaveTests
swift test
grep -n "cancel()" Sources/AnimationMeetsVideo/UI/Export/ExportWindow.swift
```

`confirmStopping` must contain no cancel.

**In the app.** Start a long ProRes export and queue a second, then:

- Open Beat Match, change something, press Cmd-Q, answer Stop Export,
  then Keep Editing. The export still runs and the queue is listed.
- Turn off saving after every change, edit, close the project window,
  answer Stop Export, then Cancel. The export and queue go on.
- The same with Don't Save: the window closes and the partial file is
  deleted.
- With one project window, nothing unsaved and an export running, close
  the window and answer Stop Export. The app quits after one alert, not
  two.
- With unsaved changes, press Cmd-Q, answer Stop Export, then Save. The
  app quits, and no partial file is left at the export's destination.

**Commit.** `Stop exports only once a close or quit goes ahead`. In the
body, say that a later Keep Editing or Cancel used to leave the app open
with the queue gone, that the question stays first and the stop moves
to the point of no return, and why `isStopping` exists.

### 10. Delete what a stopped stems export wrote

- [x] Done. **Decision**: see the table.

**Why.** Every stop question says "what is exported so far is deleted"
(`askToStop`). That holds for movies and WAV mixes, which delete their
partial file. It doesn't hold for WAV Stems. `AudioExport.exportStems`
(about lines 105-136) creates the folder and writes one stem after
another. Nothing catches an error, and `LoudnessMastering.render`
doesn't remove its file. So a stopped or failed stems export leaves the
folder, the stems already written and a partial one.

**Steps, for the recommended choice.**

1. In `exportStems`, before `createDirectory`, note whether the folder
   is new: `let madeFolder = !FileManager.default.fileExists(atPath: folder.path)`.
2. Wrap the loop in `do { … } catch { … }`. Keep
   `var writing: URL?`, set to each stem's `url` just before its
   `LoudnessMastering.render` call. In the catch, remove each URL in
   `files` and `writing`. If `madeFolder` and the folder is now empty,
   remove the folder. Then rethrow. Delete only what this export wrote:
   the person may have picked an existing folder with other files in
   it.
3. Update the function's doc comment: on an error or a stop, the stems
   it wrote are deleted, and the folder if it made it.
4. Tests in Tests/AnimationMeetsVideoTests/Export/AudioExportTests.swift,
   set up like `eachStemHasOnlyItsLayer`, with two sound layers:
   - `aStoppedStemsExportLeavesNothing`: hold the task in a small
     `final class TaskBox: @unchecked Sendable { var task: Task<[URL], Error>? }`.
     Start `box.task = Task { try await AudioExport.exportStems(…, progress: { if $0 >= 0.5 { box.task?.cancel() } }) }`.
     Expect it to throw `CancellationError`, and the folder not to
     exist. If the export finishes before the stop lands, make the
     tones longer.
   - `aStoppedStemsExportKeepsWhatWasInTheFolder`: create the folder
     with a notes.txt in it first. After the stop, notes.txt is still
     there and no "Cut - " file is.

With the alternative, leave the code. In `askToStop`, say instead that
stems already saved are kept when any job asked about is WAV Stems.

**Verify.** `swift test --filter AudioExportTests`, then `swift test`.

**In the app.** Start a WAV Stems export of a timeline with several
sound layers, and stop it after the first stem. Its folder is gone.

**Commit.** `Delete what a stopped stems export wrote`. In the body,
say that the stop questions promised the deletion, and that a folder
that was already there is kept.

### 11. Name what starts next and offer Stop All

- [x] Done. **Decision**: see the table.

**Why.** Stop Export… says only "Stopping stops the export, and what is
exported so far is deleted." It never says that the next queued export
starts at once. And nothing in the window stops the whole queue, short
of removing each waiting row and then stopping.

**Depends on** items 6, 9 and 10.

**Steps, for the recommended choice.**

1. In ExportWindow.swift, leave `askToStop` as it is for closing and
   quitting, and add a question for Stop Export…:

   ```swift
   /// What the person chose in the Stop Export… question.
   enum StopChoice { case keepExporting, stopCurrent, stopAll }

   /// Asks whether to stop `current`, saying which of `queue` starts next;
   /// with exports waiting it offers to stop them all too.
   private static func askToStopCurrent(_ current: Job, before queue: [Job]) -> StopChoice {
       let text = stopText(for: current, queue: queue)
       let alert = NSAlert()
       alert.messageText = text.message
       alert.informativeText = text.information
       // Return keeps the export going; stopping it takes a click or Tab.
       alert.addButton(withTitle: "Keep Exporting")
       alert.addButton(withTitle: "Stop Export").hasDestructiveAction = true
       if !queue.isEmpty { alert.addButton(withTitle: "Stop All").hasDestructiveAction = true }
       switch alert.runModal() {
       case .alertSecondButtonReturn: return .stopCurrent
       case .alertThirdButtonReturn: return .stopAll
       default: return .keepExporting
       }
   }

   /// The Stop Export… question, and what it says happens next.
   static func stopText(for current: Job, queue: [Job]) -> (message: String, information: String) {
       let message = "Stop exporting \u{201C}\(current.destination.lastPathComponent)\u{201D}?"
       guard let next = queue.first else {
           return (message, "Stopping stops the export, and what is exported so far is deleted.")
       }
       let file = "\u{201C}\(next.destination.lastPathComponent)\u{201D}"
       let information = queue.count == 1
           ? "What is exported so far is deleted, and \(file), waiting in the queue, starts at once. Stop All takes it out of the queue too."
           : "What is exported so far is deleted, and \(file), next of the \(queue.count) waiting, starts at once. Stop All takes them all out of the queue too."
       return (message, information)
   }
   ```

   With nothing queued, the question is exactly today's.

2. `confirmAndCancel()` becomes:

   ```swift
   func confirmAndCancel() {
       guard let asked = current else { return }
       switch Self.askToStopCurrent(asked, before: queue) {
       case .keepExporting: break
       // The question keeps the main actor running: `asked` may have ended
       // meanwhile and the next started, which goes on (`stop`).
       case .stopCurrent: stop(asked.id)
       // Whatever runs now, and all that waits, as the person asked.
       case .stopAll: cancel()
       }
   }
   ```

   Its doc comment: "Stops the export under way once the person agrees
   to, and the next one waiting starts; or, with Stop All, the queue
   too." Stop All calls `cancel()`, which sets item 9's `isStopping`.
   That is intended.

3. docs/audio.md: in item 8's paragraph, replace "Stop Export… asks
   about the one under way and stops it, and the next waiting starts
   (`ExportWindow.confirmAndCancel`)" with "Stop Export… asks about the
   one under way, naming the waiting export that would start next, and
   stops it, and that one starts (`ExportWindow.confirmAndCancel`);
   while exports wait, the question also offers Stop All, which stops
   the queue too".

4. ExportWindow's type comment: replace "Stop Export… asks first and
   stops the one under way, and the next starts (`confirmAndCancel`)"
   with "Stop Export… asks first, naming the export that starts next,
   and stops the one under way or, with Stop All, the queue too
   (`confirmAndCancel`)".

5. ExportView needs no change. The alert's buttons are standard, so
   docs/accessibility.md asks for nothing more.

6. Tests in ExportWindowTests:
   - `stopTextWithNoQueueIsUnchanged`: the message is
     `Stop exporting “Trailer.mov”?` and the information is
     `Stopping stops the export, and what is exported so far is deleted.`
   - `stopTextNamesTheNextWaiting`: with one waiting, the information
     is exactly `What is exported so far is deleted, and “Trailer Teaser.mov”, waiting in the queue, starts at once. Stop All takes it out of the queue too.`
     With three, it contains `next of the 3 waiting` and
     `Stop All takes them all out of the queue too.`

**Verify.** `swift test --filter ExportWindowTests`, then `swift test`.

**In the app.** With two exports queued behind a running one, click
Stop Export…. The question names the first waiting file and shows Keep
Exporting, Stop Export and Stop All. Return keeps exporting, Stop
Export starts the next, and Stop All leaves no progress or queue in the
window or toolbar. With nothing queued, the question has today's two
buttons.

**Commit.** `Name what starts next and offer Stop All`. In the body,
say why a third button in the question was chosen over another button
in the window.

### 12. Let the Export window's content scroll

- [x] Done

**Why.** ExportView builds its `SheetFrame` without
`scrollsContent: true`. The window sizes itself to its content and
can't be resized, and each queued export and each ended one adds a
row, with no limit. Queue about 20 exports, or let a dozen end with
mastering reports, and the window outgrows the screen. Its footer, with
Stop Export…, Close and Export…, ends up out of reach.

**Steps.**

1. UI/Export/ExportView.swift: add the argument after `subtitle:`,
   which is where SheetFrame's init takes it:

   ```swift
   SheetFrame(
       title: "Export",
       subtitle: export.timelineName.isEmpty ? nil : "The timeline \u{201C}\(export.timelineName)\u{201D}, as it plays.",
       scrollsContent: true
   ) {
   ```

   The content then scrolls once it reaches the screen's height, and
   the footer stays below it. Leave `ExportWindow.show`'s sizing
   options as they are.

2. ExportWindow.swift, the comment above the sizing options in
   `show()`: "The window follows the content's height, which grows by a
   finished export's report, a blocking note or the queue, up to what
   the screen leaves; past that the content scrolls
   (`SheetFrame.scrollsContent`). Preferred size alone left it at its
   first height with the rest cut off."

3. Create Tests/AnimationMeetsVideoTests/UI/Export/ExportViewTests.swift.
   It measures the view the way `NumberWidthTests` in
   UI/ValueDragTests.swift does, in a window that is never shown, so it
   runs in CI:

   ```swift
   import AppKit
   import SwiftUI
   import Testing
   @testable import AnimationMeetsVideo

   /// The Export window's content: how tall it lets the window get, and
   /// what its rows say.
   @MainActor
   struct ExportViewTests {
       /// The height `ExportWindow.show` gives the window with `waiting`
       /// exports queued behind one under way.
       private func windowHeight(waiting: Int) -> CGFloat {
           // SheetFrame reads NSApp.keyWindow once its content scrolls.
           _ = NSApplication.shared
           let export = ExportWindow()
           export.timelineName = "Main"
           export.showQueueWithoutRunning(
               current: exportJob(to: "Trailer.mov"), progress: 0.5,
               queue: (0..<waiting).map { exportJob(as: .wavMix, to: "Trailer \($0).wav") }
           )
           let host = NSHostingView(rootView: ExportView(export: export))
           host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
           let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Design.SheetWidth.standard, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
           window.contentView = host
           return withExtendedLifetime(window) {
               for _ in 0..<4 {
                   RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                   host.layoutSubtreeIfNeeded()
               }
               return host.fittingSize.height
           }
       }

       @Test func windowGrowsWithTheQueueUntilTheScreenIsFull() {
           #expect(windowHeight(waiting: 2) > windowHeight(waiting: 0))
           #expect(windowHeight(waiting: 80) == windowHeight(waiting: 40))
       }
   }
   ```

   The second expectation fails before step 1 and passes after it. If
   the first fails after step 1, the window no longer follows short
   content. That is a real regression: investigate it rather than
   deleting the expectation.

4. Tests/AnimationMeetsVideoTests/UI/UISnapshots.swift, in
   `exportWindow()` after the queue case, add a long queue, and mention
   it in the test's doc comment:

   ```swift
   // A queue longer than the window: the content scrolls, the actions stay.
   let long = ExportWindow()
   long.timelineName = "Main"
   long.showQueueWithoutRunning(
       current: job("Main", .proRes422, "Trailer.mov"), progress: 0.42,
       queue: (1...12).map { job("Main", .wavMix, "Trailer \($0).wav") }
   )
   try SnapshotSupport.render(ExportView(export: long), "export-window-long-queue", size: CGSize(width: 460, height: 560))
   ```

   `job` is that test's own local helper.

**Verify.**

```sh
swift test --filter ExportViewTests
SNAPSHOT_DIR=<scratch>/snaps swift test --filter UISnapshots
swift test
```

In export-window-long-queue.png, the title is at the top, the footer at
the bottom, and the queue is cut off between them. The other
export-window pictures look as before. The snapshot skill covers
rendering and viewing these.

**Commit.** `Let the Export window's content scroll`. In the body, say
that the window sizes itself to its content and can't be resized, so a
long queue pushed the actions off screen.

### 13. Name the timeline on finished rows too

- [x] Done

**Why.** `outcomeRow(_:showsTimeline:)` builds a prefix naming the
timeline when several exports ended, but only the failed case uses it.
Export Main and Teaser back to back, and the window shows two "… was
saved." lines with nothing to say which timeline each was.

**Steps.**

1. UI/Export/ExportView.swift, next to `finishedMessage`:

   ```swift
   /// What one ended export's row says; `showsTimeline` starts it with its
   /// timeline's name, when several ended.
   static func message(for ended: ExportWindow.Ended, showsTimeline: Bool) -> String {
       let prefix = showsTimeline ? "\u{201C}\(ended.timelineName)\u{201D}: " : ""
       switch ended.outcome {
       case .finished(let url, let report): return prefix + finishedMessage(url: url, report: report)
       case .failed(let message): return "\(prefix)Export failed. \(message)"
       }
   }
   ```

2. In `outcomeRow`, delete `let prefix = …`, and make both cases'
   `Text` read `Text(Self.message(for: ended, showsTimeline: showsTimeline))`.
   Keep each case's icon and modifiers. The finished case becomes
   `case .finished(let url, _):`, keeping `url` for Show in Finder, and
   the failed case `case .failed:`.

3. ExportWindow.swift, after `showOutcomeWithoutRunning`:

   ```swift
   /// Shows `ended` as if those exports had ended, oldest first, for a
   /// picture of the view (`UISnapshots`).
   func showOutcomesWithoutRunning(_ ended: [Ended]) {
       outcomes = ended
   }
   ```

4. UISnapshots.swift `exportWindow()`: add an
   `export-window-outcomes` case with Main finished as /tmp/Trailer.mov
   and Teaser failed with "The disk is full.", rendered at 460 by 460.

5. ExportViewTests, `severalOutcomesEachNameTheirTimeline`: with
   `showsTimeline: true`, the saved line is
   `“Main”: “Trailer.mov” was saved.` and the failed line
   `“Teaser”: Export failed. The disk is full.`; with
   `showsTimeline: false`, the saved line is `“Trailer.mov” was saved.`

**Verify.** `swift test --filter ExportViewTests`, then the snapshots:
export-window-outcomes.png names both timelines, and
export-window-finished.png, with one outcome, has no prefix.

**Commit.** `Name the timeline on finished rows too`.

### 14. Show a line for each stopped export

- [x] Done. **Decision**: see the table.

**Why.** docs/audio.md says that when the last export has ended, "the
window comes back with how each ended". But a stop records no outcome,
so a stopped export leaves no line. Stop the second of three, and the
window ends with lines for the first and third only.

**Depends on** items 1 and 13.

**Steps, for the recommended choice.**

1. ExportWindow.swift, `Outcome`: add
   `case stopped(url: URL)`, with the doc comment "Stopped by the
   person, or by its project closing or the app quitting."

2. In `start(_:)`, make `var outcome: Outcome?` a `let outcome: Outcome`,
   and make the cancellation catch
   `catch is CancellationError { outcome = .stopped(url: job.destination) }`.
   `url` is no longer in scope there since item 1 moved it into
   `write`.

3. `ended(_:_:)` takes `_ outcome: Outcome`, appends it always, and
   replaces `guard outcome != nil else { return }` with
   `if case .stopped = outcome { return }`, keeping its comment. A last
   export that was stopped still doesn't bring the window back.

4. ExportView: add to `message(for:showsTimeline:)`
   `case .stopped(let url): return "\(prefix)Stopped exporting \u{201C}\(url.lastPathComponent)\u{201D}."`,
   and a row case styled like the failed one:

   ```swift
   case .stopped:
       HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
           Image(systemName: "stop.circle.fill")
               .foregroundStyle(Design.textSecondary)
               .accessibilityHidden(true)
           Text(Self.message(for: ended, showsTimeline: showsTimeline))
               .font(Design.Typeface.body)
               .foregroundStyle(Design.textPrimary)
               .fixedSize(horizontal: false, vertical: true)
               .textSelection(.enabled)
       }
   ```

   The line doesn't claim the file was deleted. That depends on the
   format and on item 10's choice.

5. docs/audio.md: replace "When the last has ended the window comes
   back with how each ended." with "Each export that ends adds a line
   saying how: saved (with Show in Finder), failed, or stopped. When
   the last has ended the window comes back with them, unless that last
   one was stopped, from the window or by closing the project; one taken
   out of the queue never started and leaves no line." Rewrap.

6. UISnapshots.swift: add a third row,
   `ExportWindow.Ended(timelineName: "Main", outcome: .stopped(url: URL(filePath: "/tmp/Trailer.wav")))`,
   to `export-window-outcomes`. Raise its height to about 520 if rows
   are cut off.

7. Tests.
   - ExportViewTests, `aStoppedExportSaysSo`: the line for Teaser,
     stopped at "Trailer Teaser.mov", with `showsTimeline: true` is
     `“Teaser”: Stopped exporting “Trailer Teaser.mov”.`
   - ExportWindowTests, `aStoppedExportLeavesALineAndTheNextStarts`:
     add a, b; once a starts, `stop(a.id)`; settle on b. Outcomes are
     `[.stopped(url: a.destination)]`. `stopAll`.
   - Update earlier tests that expect no line after a stop:
     `cancellingStopsTheExportAndEmptiesTheQueue` now expects
     `[.stopped(url: a.destination)]`, `stoppingTheExportUnderWayStartsTheNext`
     expects the same, and `outcomesClearOnlyWhenAnExportStartsWithNoneRunning`
     ends with two outcomes, b finished and c stopped.

**Verify.** `swift build` flags any `switch` on `Outcome` that misses
the new case. Then `swift test --filter "ExportViewTests|ExportWindowTests"`,
the snapshots (three rows, the stopped one with a grey stop icon) and
`swift test`.

**In the app.** Stop a long export: the window shows the Stopped line
and doesn't jump forward or bounce the Dock. Queue two and stop the
first: the window ends with a Stopped line and a saved line, each
naming its timeline.

**Commit.** `Show a line for each stopped export`. In the body, say
that the doc and bd7bdc6's message promised how each ended, and that
the list left stopped ones out.

### 15. Tell queue remove buttons apart

- [ ] Done

**Why.** Each queued row's remove button is labelled
"Remove “Main” from the queue" for VoiceOver. The same timeline is
often queued twice, in another format or to another file, so two
buttons read the same, and someone using the rotor can't tell which
export a button removes. docs/accessibility.md asks icon-only buttons
to say what they act on.

**Steps.**

1. UI/Export/ExportView.swift, next to `finishedMessage`:

   ```swift
   /// The remove button's name for VoiceOver: the row as it reads, since
   /// the same timeline can wait more than once, in another format or file.
   static func removeLabel(for job: ExportWindow.Job) -> String {
       "Remove \u{201C}\(job.timelineName)\u{201D} as \(job.format.name), \u{201C}\(job.destination.lastPathComponent)\u{201D}, from the queue"
   }
   ```

2. Use `.accessibilityLabel(Self.removeLabel(for: job))` on the
   button. Keep `.help("Remove from the queue")`.

3. ExportViewTests, `removeButtonsOfTheSameTimelineReadApart`: Main as
   ProRes 422 to Trailer.mov and Main as WAV Mix to Trailer.wav get
   different labels, and the second is exactly
   `Remove “Main” as WAV Mix, “Trailer.wav”, from the queue`.

**Verify.** `swift test --filter ExportViewTests`. The snapshots don't
change, since the label is invisible.

**In the app.** Queue the same timeline twice in two formats. In
Accessibility Inspector, the two remove buttons have different labels.

**Commit.** `Tell queue remove buttons apart`. In the body, cite
docs/accessibility.md, and note what still reads the same: one
timeline and format saved under one name in two folders.

### 16. Drop a redundant queue check and switch

- [ ] Done

**Why.** No behavior changes. ExportView's body wraps `queue` in
`if export.isRunning`, but `queue` already checks `export.current`
itself, and its queue section can only be non-empty while an export
runs. EditorToolbar's `waiting` text is a two-case `switch` where a
ternary does the same.

**Steps.**

1. UI/Export/ExportView.swift: replace `if export.isRunning { queue }`
   with a bare `queue`.
2. UI/Editor/EditorToolbar.swift, in `ExportProgress`: make the help
   `.help(export.queue.isEmpty ? "Exporting" : "Exporting, \(export.queue.count) more waiting")`,
   and delete the `waiting` property and its doc comment.

**Verify.** Render the snapshots before and after with
`SNAPSHOT_DIR=<dir> swift test --filter UISnapshots`; the export-window
pictures match. Then `swift test`.

**In the app.** Hover the toolbar's export progress while one export
runs, then with two queued. The help reads "Exporting", then
"Exporting, 2 more waiting".

**Commit.** `Drop a redundant queue check and switch`.
