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

    /// The effects panel for a sound clip: an EQ with its treble cut and a
    /// compressor, then volume and pan.
    @Test func soundEffectsPanel() throws {
        var (project, clipID, layerID) = try AudioMixSupport.project(playing: URL(filePath: "/dev/null"), seconds: 8)
        let timelineID = project.rootTimelineID
        let eqID = project.addEffect(.equalizer, toClip: clipID, in: timelineID)
        let eq = try #require(eqID)
        project.editEffect(eq, ofClip: clipID, in: timelineID) { $0.controls[4].setComponent(0, to: -6, at: .zero) }
        project.addEffect(.compressor, toClip: clipID, in: timelineID)
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "sound-effects-panel", size: CGSize(width: 520, height: 520)
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
