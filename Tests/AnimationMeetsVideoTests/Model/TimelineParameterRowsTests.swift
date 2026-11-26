import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

/// Which parameters a layer's rows show, and what they change (see
/// docs/parameter-rows.md): two four-second video clips side by side on
/// one layer, each holding a Transform and a Color, the second clip a
/// second Color too.
@Suite struct TimelineParameterRowsTests {
    private struct Fixture {
        var project = EditingProject.empty
        let timelineID: UUID
        let first: UUID
        let second: UUID

        init() {
            timelineID = project.rootTimelineID
            let media = MediaClip(
                name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
                colorSpace: .rec709, codecName: "H.264"
            )
            first = project.importClip(media, intoTimeline: timelineID)!.clipID
            second = project.importClip(media, intoTimeline: timelineID)!.clipID
            let (a, b) = (first, second)
            project.editClip(a, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
            project.editClip(b, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = seconds(4) }
            // Both on the first clip's layer.
            if let from = project.clipAndLayer(b, in: timelineID)?.layer.id, let to = project.clipAndLayer(a, in: timelineID)?.layer.id, from != to,
               let t = project.timelines.firstIndex(where: { $0.id == timelineID }),
               let fi = project.timelines[t].layers.firstIndex(where: { $0.id == from }),
               let ti = project.timelines[t].layers.firstIndex(where: { $0.id == to }) {
                project.timelines[t].layers[ti].clips += project.timelines[t].layers[fi].clips
                project.timelines[t].layers.remove(at: fi)
            }
            for clip in [a, b] {
                _ = project.addEffect(.transform, toClip: clip, in: timelineID)
                _ = project.addEffect(.color, toClip: clip, in: timelineID)
            }
            _ = project.addEffect(.color, toClip: b, in: timelineID)
        }

        var layer: TimelineLayer { project.clipAndLayer(first, in: timelineID)!.layer }
        func clip(_ id: UUID) -> TimelineClip { project.clipAndLayer(id, in: timelineID)!.clip }
        func key(_ effect: EffectKind, _ ordinal: Int = 0, _ control: ControlKind) -> ParameterRowKey {
            ParameterRowKey(effectKind: effect, ordinal: ordinal, control: control)
        }

        /// Keyframes `control` of the clip's first effect of `kind`.
        mutating func keyframe(_ control: ControlKind, of kind: EffectKind, on clipID: UUID) {
            guard let effect = clip(clipID).effects.first(where: { $0.kind == kind }) else { return }
            project.editEffect(effect.id, ofClip: clipID, in: timelineID) { effect in
                effect.changeControl(control) { $0.number.setAnimated(true, at: .zero) }
            }
        }
    }

    @Test func aKeyframedControlIsInTheRowsUntilTakenOut() {
        var f = Fixture()
        var rows = TimelineParameterRows()
        let rotation = f.key(.transform, .rotation)
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: true).isEmpty)
        f.keyframe(.rotation, of: .transform, on: f.first)
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: true) == [rotation])
        // Not with adding keyframed parameters off.
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: false).isEmpty)
        rows.remove([rotation], from: [f.first])
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: true).isEmpty)
        // Shown again by hand.
        rows.show([rotation], on: [f.first])
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: false) == [rotation])
    }

    @Test func clipsShareARowAndASecondEffectOfAKindHasItsOwn() {
        let f = Fixture()
        var rows = TimelineParameterRows()
        let exposure = f.key(.color, .exposure), secondExposure = f.key(.color, 1, .exposure)
        rows.show([exposure], on: [f.first, f.second])
        rows.show([secondExposure], on: [f.second])
        let groups = f.project.parameterRows(on: f.layer, rows: rows, addsKeyframed: true, selected: [])
        #expect(groups.map(\.name) == ["Color", "Color 2"])
        #expect(groups[0].rows.map(\.clips) == [[f.first, f.second]])
        #expect(groups[1].rows.map(\.clips) == [[f.second]])
        // Selecting the first clip narrows the layer to its rows.
        let narrowed = f.project.parameterRows(on: f.layer, rows: rows, addsKeyframed: true, selected: [f.first])
        #expect(narrowed.map(\.name) == ["Color"])
    }

    @Test func aRowActsOnTheSelectedClipsOrTheOneUnderThePlayhead() throws {
        var f = Fixture()
        var rows = TimelineParameterRows()
        let opacity = f.key(.transform, .opacity)
        rows.show([opacity], on: [f.first, f.second])
        let row = try #require(f.project.parameterRows(on: f.layer, rows: rows, addsKeyframed: true, selected: []).first?.rows.first)
        #expect(f.project.parameterActingClips(row, on: f.layer, selected: [], at: seconds(5)).map(\.id) == [f.second])
        let both = f.project.parameterActingClips(row, on: f.layer, selected: [f.first, f.second], at: seconds(5))
        #expect(both.count == 2)
        #expect(f.project.parameterValue(opacity, of: both, at: seconds(5)) == [100])
        // Set on both at once, as one edit.
        let timelineID = f.timelineID
        f.project.editParameter(opacity, of: both.map(\.id), in: timelineID, { control, source in
            control.setComponent(0, to: 40, at: source)
        }, at: seconds(5))
        let after = [f.clip(f.first), f.clip(f.second)]
        #expect(f.project.parameterValue(opacity, of: after, at: seconds(1)) == [40])
        // They differ once one is changed alone.
        f.project.editParameter(opacity, of: [f.second], in: timelineID, { control, source in
            control.setComponent(0, to: 70, at: source)
        }, at: seconds(5))
        #expect(f.project.parameterValue(opacity, of: [f.clip(f.first), f.clip(f.second)], at: seconds(1)) == nil)
    }

    @Test func uShowsTheAnimatedAndUUTheChangedWhateverIsPicked() {
        var f = Fixture()
        var rows = TimelineParameterRows()
        rows.show([f.key(.color, .exposure)], on: [f.first])
        f.keyframe(.rotation, of: .transform, on: f.first)
        let color = f.clip(f.first).effects.first { $0.kind == .color }!
        f.project.editEffect(color.id, ofClip: f.first, in: f.timelineID) { effect in
            effect.changeControl(.saturation) { $0.setComponent(0, to: 150, at: .zero) }
        }
        func names(_ filter: ParameterRowFilter) -> [String] {
            f.project.parameterRows(on: f.layer, rows: rows, addsKeyframed: false, selected: [], filter: filter).flatMap { $0.rows.map(\.name) }
        }
        #expect(names(.animated) == [ControlKind.rotation.name])
        #expect(Set(names(.changed)) == [ControlKind.rotation.name, ControlKind.saturation.name])
    }

    @Test func turningAddingOffKeepsTheRowsShown() {
        var f = Fixture()
        f.keyframe(.rotation, of: .transform, on: f.first)
        var rows = TimelineParameterRows()
        rows.keepKeyframedRows(of: [f.clip(f.first), f.clip(f.second)])
        #expect(rows.keys(of: f.clip(f.first), addsKeyframed: false) == [f.key(.transform, .rotation)])
    }

    @Test func rowsOfClipsAndLayersThatAreGoneAreLetGo() {
        let f = Fixture()
        var rows = TimelineParameterRows()
        rows.show([f.key(.color, .exposure)], on: [f.first, UUID()])
        rows.setClosed(true, "color#0", on: f.layer.id)
        rows.setClosed(true, "color#0", on: UUID())
        let kept = rows.kept(in: f.project.timeline(id: f.timelineID)!)
        #expect(Set(kept.picked.keys) == [f.first])
        #expect(kept.closed.count == 1)
    }

    @Test func viewStateKeepsTheRows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-rows-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        var rows = TimelineParameterRows()
        rows.show([ParameterRowKey(effectKind: .transform, ordinal: 0, control: .position)], on: [UUID()])
        rows.remove([ParameterRowKey(effectKind: .color, ordinal: 1, control: .exposure)], from: [UUID()])
        rows.setClosed(true, "transform#0", on: UUID())
        var state = ViewState()
        state.timelines[UUID()] = ViewState.Timeline(parameterRows: rows)
        try ViewStateFile.write(state, to: url)
        #expect(ViewStateFile.read(from: url) == state)
    }
}

/// Copying keyframes from one clip's controls and pasting them at the
/// playhead onto another's (see docs/parameter-rows.md, "Copying
/// keyframes").
@Suite struct KeyframeCopyingTests {
    private func project() -> (EditingProject, UUID, [UUID]) {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let media = MediaClip(
            name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        var clips: [UUID] = []
        for start in [0.0, 6] {
            let id = project.importClip(media, intoTimeline: timelineID)!.clipID
            project.editClip(id, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = seconds(start) }
            _ = project.addEffect(.transform, toClip: id, in: timelineID)
            clips.append(id)
        }
        // Rotation on the first clip: 0 at 1 s, 90 at 2 s, eased in.
        let transform = project.clipAndLayer(clips[0], in: timelineID)!.clip.effects.first { $0.kind == .transform }!
        project.editEffect(transform.id, ofClip: clips[0], in: timelineID) { effect in
            effect.changeControl(.rotation) { control in
                control.number = AnimatedValue(ComponentValue(values: [0]), keyframes: [
                    Keyframe(time: seconds(1), value: ComponentValue(values: [0])),
                    Keyframe(time: seconds(2), value: ComponentValue(values: [90]), easeIn: .easy),
                ])
            }
        }
        return (project, timelineID, clips)
    }

    private func rotation(_ project: EditingProject, _ clipID: UUID, in timelineID: UUID) -> EffectControl {
        project.clipAndLayer(clipID, in: timelineID)!.clip.effects.first { $0.kind == .transform }!.control(.rotation)!
    }

    @Test func keyframesPasteAtThePlayheadOntoTheSameControlKeepingTheirSpacingAndEases() throws {
        var (project, timelineID, clips) = project()
        let source = project.clipAndLayer(clips[0], in: timelineID)!.clip
        let transform = source.effects.first { $0.kind == .transform }!
        let picked = [transform.id: [transform.control(.rotation)!.id: [seconds(1), seconds(2)]]]
        let copied = try #require(project.copiedKeyframes(picked, ofClip: clips[0], in: timelineID))
        #expect(copied.count == 2)
        #expect(copied.lanes[0].keyframes.map(\.offset) == [0, 1])
        // At 7 s of the timeline: 1 s into the second clip.
        #expect(project.pasteKeyframes(copied, onClip: clips[1], in: timelineID, at: seconds(7)) == 2)
        let pasted = rotation(project, clips[1], in: timelineID).number.keyframes
        #expect(pasted.map(\.time.seconds) == [1, 2])
        #expect(pasted.map(\.value.values) == [[0], [90]])
        #expect(pasted[1].easeIn == .easy)
        // Again over them: replaced, not doubled.
        project.pasteKeyframes(copied, onClip: clips[1], in: timelineID, at: seconds(7))
        #expect(rotation(project, clips[1], in: timelineID).number.keyframes.count == 2)
    }

    @Test func oneControlsKeyframesPasteOntoAnotherWithAsManyNumbers() throws {
        var (project, timelineID, clips) = project()
        let source = project.clipAndLayer(clips[0], in: timelineID)!.clip
        let transform = source.effects.first { $0.kind == .transform }!
        let copied = try #require(project.copiedKeyframes(
            [transform.id: [transform.control(.rotation)!.id: [seconds(1), seconds(2)]]], ofClip: clips[0], in: timelineID
        ))
        let target = project.clipAndLayer(clips[1], in: timelineID)!.clip.effects.first { $0.kind == .transform }!
        // Opacity has one number, as Rotation does; Position two.
        let opacity = target.control(.opacity)!, position = target.control(.position)!
        #expect(project.pasteKeyframes(copied, onClip: clips[1], in: timelineID, at: seconds(6), onto: (target.id, opacity.id)) == 2)
        #expect(project.pasteKeyframes(copied, onClip: clips[1], in: timelineID, at: seconds(6), onto: (target.id, position.id)) == 0)
    }

    @Test func copiedKeyframesGoThroughTheirText() throws {
        let (project, timelineID, clips) = project()
        let transform = project.clipAndLayer(clips[0], in: timelineID)!.clip.effects.first { $0.kind == .transform }!
        let copied = try #require(project.copiedKeyframes(
            [transform.id: [transform.control(.rotation)!.id: [seconds(2)]]], ofClip: clips[0], in: timelineID
        ))
        let text = try #require(copied.json)
        #expect(CopiedKeyframes(json: text) == copied)
        #expect(CopiedKeyframes(json: "not keyframes") == nil)
    }
}
