import CoreMedia
import Foundation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Pictures of the editor's views, for checking a UI change by eye. Runs
/// only with `SNAPSHOT_DIR` set (see `SnapshotSupport`), so CI and a
/// plain `swift test` skip it. Add a test here when changing a view that
/// has none.
@MainActor
@Suite(.serialized, .enabled(if: SnapshotSupport.isEnabled))
struct UISnapshots {
    /// The beat match panel at each step: choosing, drawing sections,
    /// marking, and a filled section with a beat selected.
    @Test func beatMatchSteps() async throws {
        let song = try SnapshotSupport.clickSong(named: "beat-match-song")
        let session = BeatMatchSession(asset: song, url: try #require(song.url))
        defer { session.end() }
        for _ in 0..<200 where session.audio == nil { try await Task.sleep(for: .milliseconds(50)) }
        let size = CGSize(width: 1300, height: 520)
        func render(_ name: String) throws {
            try SnapshotSupport.render(BeatMatchView(session: session, onConfirm: {}, onCancel: {}), name, size: size)
        }

        try render("beat-match-1-choose")
        session.chooseSections()
        session.drawSection(from: 0, to: 18, snap: 0)
        session.drawSection(from: 18, to: 22, snap: 0)
        session.drawSection(from: 22, to: 40, snap: 0)
        try render("beat-match-2-draw")
        session.finishDrawing()
        try render("beat-match-3-mark")
        session.addBeat(at: 8.25, position: 1)
        session.addBeat(at: 16.25, position: 1)
        session.fillSelected()
        for _ in 0..<100 where session.isFilling { try await Task.sleep(for: .milliseconds(50)) }
        session.selectBeat(step: 1)
        try render("beat-match-4-filled")
    }

    /// The whole editor with a song on a Music layer.
    @Test func editor() throws {
        let song = try SnapshotSupport.clickSong(named: "editor-song")
        var project = EditingProject.empty
        project.clips = [song]
        project.putOnMusicLayer([song.id])
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "editor", size: CGSize(width: 1500, height: 900))
    }

    /// The editor with an adjustment layer over three shape layers: its
    /// first clip reaches every layer below, its second only the one under
    /// it, each drawn as a box down over the layers it reaches.
    @Test func adjustmentReach() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let ten = CMTime(value: 10, timescale: 1)
        var shapes: [UUID] = []
        for kind in [EffectKind.rectangle, .ellipse, .star] {
            let added = project.addShapeLayer(kind, to: t, duration: ten)
            shapes.append(try #require(added).layerID)
        }
        let added = project.addAdjustmentLayer(to: t, duration: CMTime(value: 4, timescale: 1))
        let adjustment = try #require(added)
        project.split(adjustment.clipID, in: t, layer: adjustment.layerID, atTimelineTime: CMTime(value: 2, timescale: 1))
        let second = try #require(project.timeline(id: t)?.layer(id: adjustment.layerID)?.clips.last)
        // Shape layers go on top, so the last added is just under the adjustment.
        project.setReach(ofClip: second.id, in: t, toLayer: shapes[2])
        // Tall enough to show every layer.
        UserDefaults.standard.set(560.0, forKey: Preferences.timelineHeight)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.timelineHeight) }
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "adjustment-reach", size: CGSize(width: 1500, height: 900))
    }

    /// The inspector for an adjustment clip reaching down to one layer,
    /// with a Music layer below that isn't offered.
    @Test func adjustmentInspector() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.timelines[0].layers.append(TimelineLayer(customName: nil, kind: .music, clips: []))
        let shape = project.addShapeLayer(.rectangle, to: t)
        let shapeLayer = try #require(shape).layerID
        let added = project.addAdjustmentLayer(to: t)
        let adjustment = try #require(added)
        project.setReach(ofClip: adjustment.clipID, in: t, toLayer: shapeLayer)
        let clip = try #require(project.clipAndLayer(adjustment.clipID, in: t)?.clip)
        try SnapshotSupport.render(
            InspectorPanel(
                project: .constant(project), timelineID: t,
                selection: TimelineSelection(timelineID: t, layerID: adjustment.layerID, timelineClipID: adjustment.clipID),
                info: .adjustment, timelineClip: clip, playheadTime: .zero, onSeek: { _ in }, onDeleteSelection: {}
            ),
            "adjustment-inspector", size: CGSize(width: 340, height: 420)
        )
    }

    /// The audio meter mid-song: left in the red with a held peak, right
    /// in the yellow, and the left clip lamp lit.
    @Test func audioMeter() throws {
        // Read at about the time the snapshot is taken, so the bars
        // haven't fallen by then.
        let now = Date().timeIntervalSinceReferenceDate + 0.3
        var meter = MeterBallistics()
        meter.update(peak: SIMD2(1, 0.3), at: now - 0.5)
        meter.update(peak: SIMD2(0.5, 0.25), at: now)
        try SnapshotSupport.render(
            AudioMeterView(playback: PlaybackModel(), showing: meter, loudness: -14.2),
            "audio-meter", size: CGSize(width: 60, height: 300)
        )
    }

    /// The Tape Scrubber's box, its dial ready, and dimmed while a timeline
    /// other than Main is open.
    @Test func tapeScrubber() throws {
        let playback = PlaybackModel()
        try SnapshotSupport.render(
            VStack(spacing: 0) {
                TapeScrubberView(playback: playback, isAvailable: true).frame(width: 384, height: 104)
                TapeScrubberView(playback: playback, isAvailable: false).frame(width: 384, height: 104)
            },
            "tape-scrubber", size: CGSize(width: 384, height: 208)
        )
    }

    /// A clip's sound rows: a steady volume, and a pan keyframed from left
    /// to right with the playhead on its first keyframe.
    @Test func audioPropertyRows() throws {
        var pan = AnimatedValue(-60.0)
        pan.setAnimated(true, at: .zero)
        pan.set(40, at: CMTime(value: 2, timescale: 1))
        try SnapshotSupport.render(
            VStack(spacing: 6) {
                AudioPropertyRow(value: AnimatedValue(-4.5), time: .zero, onEdit: { _ in }, onSeek: { _ in })
                AudioPropertyRow(property: .pan, value: pan, time: .zero, onEdit: { _ in }, onSeek: { _ in }, onShowGraph: {})
            }
            .padding(8)
            .background(Design.Surface.overlay.color),
            "audio-property-rows", size: CGSize(width: 320, height: 70)
        )
    }

    /// The effects panel for a sound clip: an EQ with its high shelf cut and a
    /// compressor, then volume and pan.
    @Test func soundEffectsPanel() throws {
        var (project, clipID, layerID) = try AudioMixSupport.project(playing: URL(filePath: "/dev/null"), seconds: 8)
        let timelineID = project.rootTimelineID
        let eqID = project.addEffect(.equalizer, toClip: clipID, in: timelineID)
        let eq = try #require(eqID)
        project.editEffect(eq, ofClip: clipID, in: timelineID) { effect in
            guard let index = effect.controls.firstIndex(where: { $0.kind == .eqHighShelf }) else { return }
            effect.controls[index].enabled = true
            effect.controls[index].setComponent(1, to: -6, at: .zero)
        }
        project.addEffect(.compressor, toClip: clipID, in: timelineID)
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "sound-effects-panel", size: CGSize(width: 520, height: 760)
        )
    }

    /// The EQ's graph: a 24 dB low cut, a low shelf down, a narrow bell up
    /// and a high shelf, over the frequency and gain grid.
    @Test func equalizerGraph() throws {
        var effect = Effect(kind: .equalizer)
        for (kind, values) in [
            (ControlKind.eqLowCut, [60, EqualizerBand.flatQ]), (.eqLowShelf, [150, -6, EqualizerBand.flatQ]),
            (.eqBell2, [900, 9, 3]), (.eqHighShelf, [9000, 4, EqualizerBand.flatQ]),
        ] {
            guard let index = effect.controls.firstIndex(where: { $0.kind == kind }) else { continue }
            effect.controls[index].enabled = true
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        if let slope = effect.controls.firstIndex(where: { $0.kind == .eqLowCutSlope }) { effect.controls[slope].choice = "24" }
        try SnapshotSupport.render(
            EqualizerGraph(effect: effect, time: .zero, onEdit: { _, _ in }, onExpand: {})
                .frame(width: 480, height: 200)
                .background(Design.Surface.overlay.color),
            "equalizer-graph", size: CGSize(width: 480, height: 200)
        )
    }

    /// The larger EQ sheet's fields: two bands on, a 48 dB high cut.
    @Test func equalizerBandStrip() throws {
        var effect = Effect(kind: .equalizer)
        for (kind, values) in [(ControlKind.eqBell1, [320, -3.5, 1.4]), (.eqHighCut, [12_000, EqualizerBand.flatQ])] {
            guard let index = effect.controls.firstIndex(where: { $0.kind == kind }) else { continue }
            effect.controls[index].enabled = true
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        if let slope = effect.controls.firstIndex(where: { $0.kind == .eqHighCutSlope }) { effect.controls[slope].choice = "48" }
        try SnapshotSupport.render(
            EqualizerBandStrip(effect: effect, time: .zero, onEdit: { _, _ in })
                .padding(8)
                .background(Design.Surface.overlay.color),
            "equalizer-band-strip", size: CGSize(width: 520, height: 300)
        )
    }

    /// The effects panel for a shape clip: a rectangle with rounded corners,
    /// an orange fill and a stroke, so the color wells show.
    @Test func shapeEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        project.editClip(shape.clipID, in: timelineID) { clip in
            for index in clip.effects[0].controls.indices {
                switch clip.effects[0].controls[index].kind {
                case .cornerRadius: clip.effects[0].controls[index].number = AnimatedValue(ComponentValue(values: [24]))
                case .fill: clip.effects[0].controls[index].number = AnimatedValue(ComponentValue(values: [0.95, 0.55, 0.15, 1]))
                case .strokeWidth: clip.effects[0].controls[index].number = AnimatedValue(ComponentValue(values: [6]))
                default: break
                }
            }
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "shape-effects-panel", size: CGSize(width: 520, height: 420)
        )
    }

    /// The shape button's popover: a row for each shape a new layer can
    /// start with.
    @Test func newShapePopover() throws {
        try SnapshotSupport.render(
            NewShapePopover(onAdd: { _ in }).background(Design.Surface.overlay.color),
            "new-shape-popover", size: CGSize(width: 200, height: 150)
        )
    }

    /// The record popover before a take, with the last take's error.
    @Test func recordPopover() throws {
        try SnapshotSupport.render(
            RecordPopover(
                recorder: AudioRecorder(), onRecord: { _, _ in }, onStop: {},
                error: RecordingError.nothingRecorded.localizedDescription
            )
            .background(Design.Surface.overlay.color),
            "record-popover", size: CGSize(width: 300, height: 230)
        )
    }

    /// Annotation ink: two finished strokes and one being drawn.
    @Test func annotations() throws {
        let model = AnnotationModel()
        model.beginStroke(at: CGPoint(x: 40, y: 60))
        for x in stride(from: 50.0, through: 260, by: 10) { model.appendPoint(CGPoint(x: x, y: 60 + (x - 40) * 0.4)) }
        model.endStroke()
        model.beginStroke(at: CGPoint(x: 60, y: 200))
        model.appendPoint(CGPoint(x: 160, y: 150))
        model.appendPoint(CGPoint(x: 260, y: 200))
        model.endStroke()
        model.beginStroke(at: CGPoint(x: 300, y: 40))
        for y in stride(from: 50.0, through: 220, by: 10) { model.appendPoint(CGPoint(x: 300 + sin(y / 20) * 30, y: y)) }
        try SnapshotSupport.render(
            AnnotationOverlay(model: model).background(Color.black),
            "annotations", size: CGSize(width: 400, height: 260)
        )
    }

    /// Each tab of the Settings window. The window's tab is remembered,
    /// so it is put back afterwards.
    @Test func settingsWindow() throws {
        let key = "settingsTab"
        let remembered = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(remembered, forKey: key) }
        for tab in ["viewer", "timeline", "sound", "library", "layout"] {
            UserDefaults.standard.set(tab, forKey: key)
            try SnapshotSupport.render(SettingsView(), "settings-\(tab)", size: CGSize(width: 460, height: 420))
        }
    }

    @Test func projectSettings() throws {
        try SnapshotSupport.render(
            ProjectSettingsView(project: .empty) { _, _ in }, "project-settings", size: CGSize(width: 460, height: 300)
        )
    }
}
