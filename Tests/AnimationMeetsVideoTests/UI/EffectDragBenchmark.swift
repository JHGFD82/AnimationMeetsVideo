import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Times dragging an effect's value in the hosted editor, with the effects
/// panel open on a shape clip: each step edits the shape's size, as a drag
/// on its field does, and lays out and draws the window. Prints the times;
/// nothing is asserted, since they vary too much from machine to machine.
/// Runs only with `EFFECT_DRAG_BENCHMARK` set, to how many seconds to keep
/// dragging, which leaves time to attach `sample` to the test process.
/// Release timings are the ones that matter:
///
///     swift build -c release -Xswiftc -enable-testing --build-tests
///     EFFECT_DRAG_BENCHMARK=20 swift test -c release -Xswiftc -enable-testing \
///         --skip-build --filter EffectDragBenchmark
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EFFECT_DRAG_BENCHMARK"] != nil))
struct EffectDragBenchmark {
    @Observable final class Model {
        var project: EditingProject
        init(_ project: EditingProject) { self.project = project }
    }

    struct Host: View {
        @Bindable var model: Model
        let history: ProjectHistory
        let selection: TimelineSelection
        var body: some View {
            EditorView(
                project: $model.project, history: history, analysis: AssetAnalysis(),
                replacement: MediaReplacementController(), packageURL: nil, selection: selection
            )
        }
    }

    @Test func dragShapeSize() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let ten = CMTime(value: 10, timescale: 1)
        var target: (layerID: UUID, clipID: UUID)?
        for kind in [EffectKind.rectangle, .ellipse, .star, .polygon, .rectangle, .ellipse] {
            target = project.addShapeLayer(kind, to: t, duration: ten)
        }
        let selected = try #require(target)
        for kind in [EffectKind.color, .wave, .grain] {
            _ = project.addEffect(kind, toClip: selected.clipID, in: t)
        }
        let shape = try #require(project.clipAndLayer(selected.clipID, in: t)?.clip.effects.first)
        let size = try #require(shape.control(.shapeSize))

        // The effects panel open, and the timeline tall enough for the layers.
        let defaults = UserDefaults.standard
        let preferences: [String: Any] = [
            Preferences.showsSidePanel: true, Preferences.sidePanelTab: SidePanelTab.effects.rawValue,
            Preferences.timelineHeight: 420.0,
        ]
        let remembered = preferences.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in remembered { defaults.set(value, forKey: key) } }
        for (key, value) in preferences { defaults.set(value, forKey: key) }

        let model = Model(project)
        let history = ProjectHistory(project: project)
        let bounds = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let selection = TimelineSelection(timelineID: t, layerID: selected.layerID, timelineClipID: selected.clipID)
        let host = NSHostingView(
            rootView: Host(model: model, history: history, selection: selection).frame(width: bounds.width, height: bounds.height)
        )
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        func settle(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        // Lets the panel's rows and the first build land.
        settle(1)

        var times: [Double] = []
        let seconds = Double(ProcessInfo.processInfo.environment["EFFECT_DRAG_BENCHMARK"] ?? "") ?? 0
        let deadline = Date().addingTimeInterval(max(seconds, 0))
        history.beginGesture()
        var step = 0
        repeat {
            for _ in 0..<60 {
                step += 1
                let start = ContinuousClock.now
                model.project.editEffect(shape.id, ofClip: selected.clipID, in: t) { effect in
                    guard let index = effect.controlIndex(size.id) else { return }
                    var value = effect.controls[index].number.value
                    value.values = value.values.map { $0 + (step.isMultiple(of: 2) ? 1 : -1) }
                    effect.controls[index].number = AnimatedValue(value)
                }
                // What the run loop does between two mouse moves.
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let elapsed = ContinuousClock.now - start
                times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
        } while Date() < deadline
        history.endGesture()

        let sorted = times.dropFirst(5).sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        print(String(format: "EffectDragBenchmark: %d steps, mean %.2f ms, median %.2f, p90 %.2f, max %.2f",
                     sorted.count, mean, percentile(0.5), percentile(0.9), sorted.last ?? 0))
        // With `SNAPSHOT_DIR` set, a picture of the editor, to check the
        // panel showed the clip.
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("effect-drag.png"))
        }
        window.orderOut(nil)
    }
}
