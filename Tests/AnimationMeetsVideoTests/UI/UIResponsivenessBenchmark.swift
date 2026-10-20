import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Times what the editor does on the main thread for each step of an
/// interaction, hosting the whole editor in a window: dragging effect
/// values of several kinds (each step the edit a drag on the field makes),
/// a layer's volume, and the timeline's keys for stepping the playhead,
/// nudging a clip and zooming (real key events, through the timeline's own
/// handling). Each step is timed through the run loop pass, layout and
/// drawing that follow it. Prints a table; nothing is asserted, since
/// timings vary too much from machine to machine for CI.
///
/// Runs only with `UI_BENCHMARK` set: `all`, or scenario names separated
/// by commas (see `scenarios`). `UI_BENCHMARK_SECONDS` keeps each one
/// going that long, which leaves time to attach `sample`; without it each
/// takes 90 steps. A drag's steps are held to one side of the project, as
/// a dragged field holds them (`ProjectState.hold`); `UI_BENCHMARK_UNHELD`
/// writes each to the project instead, as drags did before, for
/// comparison. `AMV_PROJECT` adds scenarios on a saved project, which
/// is read and never written. With `SNAPSHOT_DIR` set, each scenario
/// leaves a picture of the editor. Release timings are the ones that
/// matter:
///
///     swift build -c release -Xswiftc -enable-testing --build-tests
///     UI_BENCHMARK=all swift test -c release -Xswiftc -enable-testing \
///         --skip-build --filter UIResponsivenessBenchmark
///
/// Pointer drags can't be driven here: SwiftUI's gestures don't see mouse
/// events made up in a test. A clip being dragged or trimmed only moves
/// its preview until it is let go, so `nudge` times the move it commits.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["UI_BENCHMARK"] != nil))
struct UIResponsivenessBenchmark {
    /// The editor as the app's scene holds it: the same history, analysis
    /// and replacement for the window's life, and `.equatable()`, since
    /// this runs again at every edit. Made anew here at each edit, they
    /// rebuilt the whole editor every step, and the ones let go of piled up.
    struct Host: View {
        @Bindable var state: ProjectState
        let history: ProjectHistory
        let analysis: AssetAnalysis
        let replacement: MediaReplacementController
        let selection: TimelineSelection?
        var body: some View {
            EditorView(
                project: $state.value, history: history, analysis: analysis,
                replacement: replacement, packageURL: nil, selection: selection
            )
            .equatable()
            .environment(state)
        }
    }

    /// The project a scenario starts from.
    enum Base: String {
        /// Six shape layers, the top one selected.
        case shapes
        /// Footage on two video layers (one cut in pieces), a shape layer,
        /// an adjustment layer of grain over them all, and a song on a
        /// Music layer. The top footage clip is selected.
        case media
        /// Thirty shape layers, each cut into ten clips, so what a step costs
        /// as the project grows shows apart from what footage costs. The top
        /// layer's first clip is selected.
        case busy
        /// Three shape layers, each cut into a hundred clips: as many clips
        /// as `busy` on a tenth of the layers.
        case long
        /// The project at `AMV_PROJECT`, its first video clip selected.
        case saved
    }

    /// What each step does.
    enum Action {
        /// Nudges every component of a control of the selected clip's
        /// first effect of this kind, which is added when the clip has
        /// none, up and down by `delta`, as dragging its field does.
        /// `keyframed` animates the control first, so each step moves the
        /// keyframe under the playhead.
        case drag(EffectKind, ControlKind, delta: Double, keyframed: Bool = false)
        /// Nudges the selected clip's layer's volume, in decibels.
        case volume
        /// Drags the selected clip's speed.
        case speed
        /// Presses a key, alternating with `back` when given, or with
        /// `sweep` pressing it 60 times and `back` 60 times, so stepping
        /// the playhead never runs into the end.
        case key(Key, back: Key, sweep: Bool = false)
    }

    struct Key {
        var code: UInt16
        var characters: String
        var flags: NSEvent.ModifierFlags = []
        static let right = Key(code: 124, characters: "\u{F703}")
        static let left = Key(code: 123, characters: "\u{F702}")
        static let shiftRight = Key(code: 124, characters: "\u{F703}", flags: .shift)
        static let shiftLeft = Key(code: 123, characters: "\u{F702}", flags: .shift)
        static let nudgeLater = Key(code: 47, characters: ".")
        static let nudgeEarlier = Key(code: 43, characters: ",")
        static let zoomIn = Key(code: 24, characters: "=")
        static let zoomOut = Key(code: 27, characters: "-")
    }

    struct Scenario {
        var name: String
        var base: Base
        var panel: SidePanelTab = .effects
        var showsPanel = true
        var showsLibrary = false
        /// Key presses before the timed steps, such as zooming in first.
        var prelude: (key: Key, count: Int)?
        var action: Action
    }

    static let scenarios: [Scenario] = {
        var list: [Scenario] = [
            Scenario(name: "shape-size", base: .shapes, action: .drag(.ellipse, .shapeSize, delta: 1)),
            Scenario(name: "color-exposure", base: .media, action: .drag(.color, .exposure, delta: 0.01)),
            Scenario(name: "transform-position", base: .media, action: .drag(.transform, .position, delta: 1)),
            Scenario(name: "keyframed-scale", base: .media, action: .drag(.transform, .scale, delta: 0.5, keyframed: true)),
            Scenario(name: "wave-height", base: .media, action: .drag(.wave, .waveHeight, delta: 0.5)),
            Scenario(name: "kaleidoscope-angle", base: .media, action: .drag(.kaleidoscope, .distortAngle, delta: 1)),
            Scenario(name: "feedback-scale", base: .media, action: .drag(.feedback, .copyScale, delta: 0.5)),
            Scenario(name: "volume", base: .media, panel: .inspector, action: .volume),
            Scenario(name: "speed-drag", base: .media, action: .speed),
            Scenario(name: "step-frame", base: .media, action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "step-ten-frames", base: .media, action: .key(.shiftRight, back: .shiftLeft)),
            Scenario(name: "step-frame-library", base: .media, showsLibrary: true, action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "step-frame-no-panel", base: .media, showsPanel: false, action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "step-frame-inspector", base: .media, panel: .inspector, action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "nudge-clip", base: .media, action: .key(.nudgeLater, back: .nudgeEarlier)),
            Scenario(name: "busy-zoom", base: .busy, action: .key(.zoomIn, back: .zoomOut)),
            Scenario(name: "busy-zoomed-in-zoom", base: .busy, prelude: (.zoomIn, 6), action: .key(.zoomIn, back: .zoomOut)),
            Scenario(name: "busy-zoomed-in-step-frame", base: .busy, prelude: (.zoomIn, 6), action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "busy-zoomed-in-nudge-clip", base: .busy, prelude: (.zoomIn, 6), action: .key(.nudgeLater, back: .nudgeEarlier)),
            Scenario(name: "long-zoom", base: .long, action: .key(.zoomIn, back: .zoomOut)),
            Scenario(name: "long-zoomed-in-zoom", base: .long, prelude: (.zoomIn, 6), action: .key(.zoomIn, back: .zoomOut)),
            Scenario(name: "long-nudge-clip", base: .long, action: .key(.nudgeLater, back: .nudgeEarlier)),
            Scenario(name: "busy-step-frame", base: .busy, action: .key(.right, back: .left, sweep: true)),
            Scenario(name: "busy-nudge-clip", base: .busy, action: .key(.nudgeLater, back: .nudgeEarlier)),
            Scenario(name: "zoom", base: .media, action: .key(.zoomIn, back: .zoomOut)),
        ]
        if ProcessInfo.processInfo.environment["AMV_PROJECT"] != nil {
            list += [
                Scenario(name: "saved-color-exposure", base: .saved, action: .drag(.color, .exposure, delta: 0.01)),
                Scenario(name: "saved-transform-position", base: .saved, action: .drag(.transform, .position, delta: 1)),
                Scenario(name: "saved-step-frame", base: .saved, action: .key(.right, back: .left, sweep: true)),
                Scenario(name: "saved-nudge-clip", base: .saved, action: .key(.nudgeLater, back: .nudgeEarlier)),
            ]
        }
        return list
    }()

    @Test func run() async throws {
        let wanted = ProcessInfo.processInfo.environment["UI_BENCHMARK"] ?? "all"
        let names = Set(wanted.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        let chosen = Self.scenarios.filter { names.contains("all") || names.contains($0.name) }
        try #require(!chosen.isEmpty, "No scenario named \(wanted)")
        var bases: [Base: (EditingProject, TimelineSelection)] = [:]
        var rows: [String] = []
        for scenario in chosen {
            if bases[scenario.base] == nil { bases[scenario.base] = try await Self.make(scenario.base) }
            let (project, selection) = try #require(bases[scenario.base])
            rows.append(try await measure(scenario, project: project, selection: selection))
        }
        print("UIResponsivenessBenchmark (ms per step, main thread)")
        print("scenario                     steps   mean  median    p90     max   first   last")
        for row in rows { print(row) }
    }

    // MARK: Measuring

    private func measure(_ scenario: Scenario, project start: EditingProject, selection: TimelineSelection) async throws -> String {
        var project = start
        let t = selection.timelineID
        var edit: ((inout EditingProject, Int) -> Void)?
        switch scenario.action {
        case let .drag(kind, control, delta, keyframed):
            let effectID = try Self.effect(kind, on: selection, in: &project)
            if keyframed {
                project.editEffect(effectID, ofClip: selection.timelineClipID, in: t) { effect in
                    guard let index = effect.controls.firstIndex(where: { $0.kind == control }) else { return }
                    let value = effect.controls[index].number.value
                    effect.controls[index].number = AnimatedValue(value, keyframes: [
                        Keyframe(time: .zero, value: value),
                        Keyframe(time: CMTime(value: 2, timescale: 1), value: ComponentValue(values: value.values.map { $0 * 1.5 + 10 })),
                    ])
                }
            }
            let source = project.clipAndLayer(selection.timelineClipID, in: t)?.clip.trimStart ?? .zero
            edit = { project, step in
                project.editEffect(effectID, ofClip: selection.timelineClipID, in: t) { effect in
                    guard let index = effect.controls.firstIndex(where: { $0.kind == control }) else { return }
                    var value = effect.controls[index].number.value(at: source)
                    value.values = value.values.map { $0 + (step.isMultiple(of: 2) ? delta : -delta) }
                    effect.controls[index].number.set(value, at: source)
                }
            }
        case .volume:
            edit = { project, step in
                project.editVolume(of: selection.layerID, in: t) { volume in
                    volume.set(volume.value + (step.isMultiple(of: 2) ? 0.5 : -0.5), at: .zero)
                }
            }
        case .speed:
            edit = { project, step in
                project.editTime(ofClip: selection.timelineClipID, in: t, layer: selection.layerID) { time in
                    time.speed.set(100 + Double(step % 60), at: .zero)
                }
            }
        case .key:
            break
        }

        let defaults = UserDefaults.standard
        let preferences: [String: Any] = [
            Preferences.showsSidePanel: scenario.showsPanel, Preferences.sidePanelTab: scenario.panel.rawValue,
            Preferences.showsEffectsLibrary: scenario.showsLibrary,
            Preferences.timelineHeight: 420.0,
        ]
        let remembered = preferences.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in remembered { defaults.set(value, forKey: key) } }
        for (key, value) in preferences { defaults.set(value, forKey: key) }

        let state = ProjectState(project)
        let holds = ProcessInfo.processInfo.environment["UI_BENCHMARK_UNHELD"] == nil
        let history = ProjectHistory(project: project)
        let bounds = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let host = NSHostingView(
            rootView: Host(
                state: state, history: history, analysis: AssetAnalysis(), replacement: MediaReplacementController(),
                selection: selection
            )
            .frame(width: bounds.width, height: bounds.height)
        )
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // Each pass in a pool of its own, as the app's event loop drains one
        // after every event: run from a test, nothing drained until the
        // test returned, and what AppKit and SwiftUI leave to be released
        // piled up and made every step slower than the last.
        func pass() {
            autoreleasepool {
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        // Yielding lets the main actor's other work run, as it does between
        // the app's events: the player's builds and the viewer's frames.
        // Without it the test held the main actor throughout, and the
        // editor never built its player.
        func settle(_ seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                try? await Task.sleep(for: .milliseconds(10))
                pass()
            } while Date() < end
        }
        // Lets the panels' rows, analysis and the first build land.
        await settle(3)
        if let prelude = scenario.prelude {
            for _ in 0..<prelude.count {
                press(prelude.key, in: window)
                await settle(0.2)
            }
            await settle(1)
        }

        var times: [Double] = []
        let seconds = Double(ProcessInfo.processInfo.environment["UI_BENCHMARK_SECONDS"] ?? "") ?? 0
        let deadline = Date().addingTimeInterval(max(seconds, 0))
        if edit != nil {
            history.beginGesture()
            if holds { state.beginHold() }
        }
        var step = 0
        repeat {
            for _ in 0..<90 {
                step += 1
                let start = ContinuousClock.now
                autoreleasepool {
                    if let edit {
                        state.hold { edit(&state.value, step) }
                    } else if case let .key(key, back, sweep) = scenario.action {
                        let forward = sweep ? (step - 1) % 120 < 60 : !step.isMultiple(of: 2)
                        press(forward ? key : back, in: window)
                    }
                }
                // What the run loop does between two events.
                await Task.yield()
                pass()
                let elapsed = ContinuousClock.now - start
                times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
        } while Date() < deadline
        if edit != nil {
            // As a field does when let go: the last step, to the project.
            if holds { print("UIResponsivenessBenchmark: \(scenario.name) still held: \(state.isHolding)") }
            state.endHold()
            edit?(&state.value, step)
            history.endGesture()
        }
        await settle(0.3)

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("benchmark-\(scenario.name).png"))
        }
        // The first steps warm up caches.
        let sorted = times.dropFirst(5).sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        // The median of the first and of the last 90 steps: a step that
        // gets slower the longer an interaction goes on is something
        // building up with each edit.
        func median(_ steps: ArraySlice<Double>) -> Double { steps.sorted()[steps.count / 2] }
        let first = median(times.dropFirst(5).prefix(90)), last = median(times.suffix(90))
        if ProcessInfo.processInfo.environment["UI_BENCHMARK_SERIES"] != nil {
            let chunks = stride(from: 0, to: times.count, by: 90).map { median(times[$0..<min($0 + 90, times.count)]) }
            print("UIResponsivenessBenchmark: \(scenario.name) by 90 steps: " + chunks.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        // A step far above the median is a stall; where it falls says what
        // caused it.
        let typical = sorted[sorted.count / 2]
        for (index, time) in times.enumerated() where index >= 5 && time > max(30, typical * 2.5) {
            print(String(format: "UIResponsivenessBenchmark: %@ stalled at step %d: %.0f ms (median %.1f)", scenario.name, index + 1, time, typical))
        }
        let padded = scenario.name.padding(toLength: 27, withPad: " ", startingAt: 0)
        let row = String(
            format: "%@ %6d %6.1f  %6.1f %6.1f  %6.1f  %6.1f %6.1f", padded, sorted.count, mean, percentile(0.5), percentile(0.9),
            sorted.last ?? 0, first, last
        )
        print("UIResponsivenessBenchmark: \(row)")
        return row
    }

    /// Sends a key down to the app, as typing does, so the editor's key
    /// monitors see it.
    private func press(_ key: Key, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        ) else { return }
        // Sent, not posted: a posted event left in the queue ends the main
        // run loop the test's async steps run on, and the process exits.
        NSApp.sendEvent(event)
    }

    // MARK: Projects

    /// The selected clip's first effect of `kind`, added at the end of its
    /// stack when it has none.
    private static func effect(_ kind: EffectKind, on selection: TimelineSelection, in project: inout EditingProject) throws -> UUID {
        let clip = try #require(project.clipAndLayer(selection.timelineClipID, in: selection.timelineID)?.clip)
        if let existing = clip.effects.first(where: { $0.kind == kind }) { return existing.id }
        let added = project.addEffect(kind, toClip: clip.id, in: selection.timelineID)
        return try #require(added, "Couldn't add \(kind)")
    }

    private static func make(_ base: Base) async throws -> (EditingProject, TimelineSelection) {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let ten = CMTime(value: 10, timescale: 1)
        switch base {
        case .shapes:
            var target: (layerID: UUID, clipID: UUID)?
            for kind in [EffectKind.rectangle, .ellipse, .star, .polygon, .rectangle, .ellipse] {
                target = project.addShapeLayer(kind, to: t, duration: ten)
            }
            let top = try #require(target)
            for kind in [EffectKind.color, .wave, .grain] {
                _ = project.addEffect(kind, toClip: top.clipID, in: t)
            }
            return (project, TimelineSelection(timelineID: t, layerID: top.layerID, timelineClipID: top.clipID))
        case .media:
            let song = try SnapshotSupport.clickSong(named: "benchmark-song", seconds: 20)
            project.addMedia(song)
            project.putOnMusicLayer([song.id])
            let footage = try await MediaImporter.importClip(at: try await Self.footage())
            project.addMedia(footage)
            let placedLower = project.placeAsset(footage.id, intoTimeline: t)
            let lower = try #require(placedLower)
            for second in [2, 4, 6] {
                project.split(lower.clipID, in: t, layer: lower.layerID, atTimelineTime: CMTime(value: Int64(second), timescale: 1))
            }
            let placedTop = project.placeAsset(footage.id, intoTimeline: t)
            let top = try #require(placedTop)
            for kind in [EffectKind.transform, .color] where project.clipAndLayer(top.clipID, in: t)?.clip.effects.contains(where: { $0.kind == kind }) != true {
                _ = project.addEffect(kind, toClip: top.clipID, in: t)
            }
            project.addShapeLayer(.star, to: t, duration: ten)
            if let adjustment = project.addAdjustmentLayer(to: t, duration: ten) {
                _ = project.addEffect(.grain, toClip: adjustment.clipID, in: t)
            }
            return (project, TimelineSelection(timelineID: t, layerID: top.layerID, timelineClipID: top.clipID))
        case .busy:
            var target: (layerID: UUID, clipID: UUID)?
            let kinds: [EffectKind] = [.rectangle, .ellipse, .star, .polygon]
            for index in 0..<30 {
                target = project.addShapeLayer(kinds[index % kinds.count], to: t, duration: ten)
                if let target {
                    for second in 1..<10 {
                        project.split(target.clipID, in: t, layer: target.layerID, atTimelineTime: CMTime(value: Int64(second), timescale: 1))
                    }
                }
            }
            let top = try #require(target)
            let first = try #require(project.timeline(id: t)?.layer(id: top.layerID)?.clips.first)
            return (project, TimelineSelection(timelineID: t, layerID: top.layerID, timelineClipID: first.id))
        case .long:
            var target: (layerID: UUID, clipID: UUID)?
            for kind in [EffectKind.rectangle, .ellipse, .star] {
                target = project.addShapeLayer(kind, to: t, duration: ten)
                if let target {
                    for tenth in 1..<100 {
                        project.split(target.clipID, in: t, layer: target.layerID, atTimelineTime: CMTime(value: Int64(tenth), timescale: 10))
                    }
                }
            }
            let top = try #require(target)
            let first = try #require(project.timeline(id: t)?.layer(id: top.layerID)?.clips.first)
            return (project, TimelineSelection(timelineID: t, layerID: top.layerID, timelineClipID: first.id))
        case .saved:
            let path = try #require(ProcessInfo.processInfo.environment["AMV_PROJECT"])
            project = try await ProjectStore.load(from: URL(fileURLWithPath: path)).project
            let root = project.rootTimelineID
            let timeline = try #require(project.timeline(id: root))
            let layer = try #require(timeline.layers.first { $0.kind == .video && !$0.clips.isEmpty })
            return (project, TimelineSelection(timelineID: root, layerID: layer.id, timelineClipID: layer.clips[0].id))
        }
    }

    /// Ten seconds of 1280×720 H.264 footage at 24 fps: diagonal stripes
    /// that move every frame, so each frame decodes as a new picture.
    private static func footage() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-benchmark-footage.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let width = 1280, height = 720, period = 64
        let partial = url.deletingLastPathComponent().appending(path: "amv-benchmark-footage-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // One row of stripes, long enough to copy from at any shift.
        let stripes: [UInt32] = (0..<(width + period)).map { x in
            let t = Double(x % period) / Double(period)
            let r = UInt32(127 + 120 * sin(t * 2 * .pi)), g = UInt32(127 + 120 * sin(t * 2 * .pi + 2)), b = UInt32(127 + 120 * sin(t * 2 * .pi + 4))
            return 0xFF00_0000 | r << 16 | g << 8 | b
        }
        for frame in 0..<240 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            stripes.withUnsafeBufferPointer { row in
                for y in 0..<height {
                    let shift = (frame * 4 + y) % period
                    base.advanced(by: y * stride).copyMemory(from: row.baseAddress! + shift, byteCount: width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "Couldn't write the footage: \(String(describing: writer.error))")
        try? FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
