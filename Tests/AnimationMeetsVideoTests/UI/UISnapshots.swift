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
    /// The motion designer on two shots over a click song: the first held
    /// by a hit on a downbeat and slowed by a dragged marker, the second
    /// sped up by a pace marker that is selected; the retimed filmstrip,
    /// the graph's speeds, the hit's pin down to its beat, and the bracket
    /// where the first shot's scene starts.
    @Test func motionDesigner() async throws {
        var song = try SnapshotSupport.clickSong(named: "motion-designer-song", seconds: 16)
        let beats = (0..<31).map { MappedBeat(time: CMTime(seconds: 0.25 + Double($0) * 0.5, preferredTimescale: 600), position: $0 % 4 + 1) }
        song.hasAudio = true
        song.beatMap = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: CMTime(value: 16, timescale: 1), isConfirmed: true, beats: beats)])
        let movie = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-motion-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await writeMovie(to: movie, segments: [(90, 24), (200, 24), (120, 24), (230, 24), (100, 24), (180, 24), (140, 24), (240, 24)])
        let footage = MediaClip(
            name: "Skate", kind: .video, url: movie, duration: CMTime(value: 8, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )

        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        project.addMedia(footage)
        project.addMedia(song)
        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        let first = TimelineClip(source: .media(footage.id), startOffset: seconds(1), trimStart: .zero, trimEnd: seconds(3))
        let second = TimelineClip(source: .media(footage.id), startOffset: seconds(6), trimStart: seconds(4), trimEnd: seconds(7))
        var music = TimelineClip(source: .media(song.id), startOffset: .zero, trimStart: .zero, trimEnd: seconds(16))
        music.streams = .audio
        project.timelines[0].layers = [
            TimelineLayer(customName: nil, kind: .video, clips: [first, second]),
            TimelineLayer(customName: nil, kind: .music, clips: [music]),
        ]

        // The first shot's scene starts where its trim does, so its start
        // shows the scene's edge.
        var run = try MotionRun.opening([first.id, second.id], in: timelineID, of: project) { clip in
            clip.id == first.id ? CMTimeRange(start: .zero, end: seconds(3.5)) : nil
        }.get()
        let hitAdded = run.addMarker(toPiece: first.id, atSource: seconds(0.25))
        let hit = try #require(hitAdded)
        run.movePoint(hit, to: seconds(1.25))
        run.setKind(.hit, ofPoint: hit)
        let slowAdded = run.addMarker(toPiece: first.id, atSource: seconds(1.25))
        let slow = try #require(slowAdded)
        run.movePoint(slow, to: seconds(3.25))
        let paceAdded = run.addMarker(toPiece: second.id, atSource: seconds(5))
        let pace = try #require(paceAdded)
        run.setKind(.pace(250), ofPoint: pace)
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        session.select(point: pace)
        session.seek(to: 2.25)
        let view = MotionDesignView(session: session, onDone: {}, onCancel: {})
        let size = CGSize(width: 1240, height: 600)
        // The same, with the first shot's slow marker eased into a quick
        // stretch after it and selected: its two handles on its tangent,
        // the one in reaching further than the one out, and the sidebar's
        // reach sliders and speeds.
        let easedRun: MotionRun = {
            var copy = run
            let quick = copy.addMarker(toPiece: first.id, atSource: seconds(1.5))!
            copy.movePoint(quick, to: seconds(3.4))
            copy.setEase(.easyEase, ofPoint: slow)
            copy.setHandle(.before, ofPoint: slow, to: KeyframeEase(influence: 0.6, speed: 0.3), alone: true)
            copy.setHandle(.after, ofPoint: slow, to: KeyframeEase(influence: 0.4, speed: 0.5), alone: true)
            return copy
        }()
        let easedSession = MotionDesignSession(run: easedRun, project: project, playback: PlaybackModel())
        defer { easedSession.end() }
        easedSession.select(point: slow)
        easedSession.seek(to: 2.25)

        // The first pass asks for the thumbnails and the waveform.
        try SnapshotSupport.render(view, "motion-designer", size: size)
        _ = WaveformCache.shared.waveform(for: try #require(song.url))
        try await Task.sleep(for: .milliseconds(1500))
        // Two songs: a second Music layer above with a song from 3 s to 6 s,
        // which leads there, its lane full and the first's dimmed beneath.
        var twoSongs = project
        var chorus = TimelineClip(source: .media(song.id), startOffset: seconds(3), trimStart: seconds(8), trimEnd: seconds(11))
        chorus.streams = .audio
        let musicIndex = try #require(twoSongs.timelines[0].layers.firstIndex { $0.kind == .music })
        twoSongs.timelines[0].layers.insert(TimelineLayer(customName: "Chorus", kind: .music, clips: [chorus]), at: musicIndex)
        let twoSession = MotionDesignSession(run: run, project: twoSongs, playback: PlaybackModel())
        defer { twoSession.end() }
        twoSession.select(point: hit)
        twoSession.seek(to: 2.25)

        // The monitor is the editor's player, which has nothing to show
        // here: no editor builds it.
        try SnapshotSupport.render(view, "motion-designer", size: size)
        try SnapshotSupport.render(MotionDesignView(session: easedSession, onDone: {}, onCancel: {}), "motion-designer-ease", size: size)
        try SnapshotSupport.render(MotionDesignView(session: twoSession, onDone: {}, onCancel: {}), "motion-designer-two-songs", size: size)
        // The first shot's first frame selected, its one handle pulled out
        // into the clip, and the sidebar's edge controls.
        let edgeSession = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { edgeSession.end() }
        edgeSession.select(edge: .init(piece: first.id, edge: .start))
        edgeSession.setSelectedEdgeHandle(KeyframeEase(influence: 0.5, speed: 0.2))
        edgeSession.seek(to: 2.25)
        try SnapshotSupport.render(MotionDesignView(session: edgeSession, onDone: {}, onCancel: {}), "motion-designer-edge", size: size)
        // The first shot, held by its hit, dragged: the notice saying why.
        session.select(point: nil)
        session.selectedPieceID = first.id
        session.explainHeldPiece()
        try SnapshotSupport.render(MotionDesignView(session: session, onDone: {}, onCancel: {}), "motion-designer-held", size: size)
    }

    /// The beat match panel at each step: choosing, drawing sections,
    /// marking, a filled section with a beat selected, and started over on
    /// a song that had beats.
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
        // Placed by ear a little late, so the fill snaps it.
        session.addBeat(at: 8.256, position: 1)
        for _ in 0..<100 where session.provisionalTempo == nil { try await Task.sleep(for: .milliseconds(50)) }
        try render("beat-match-3-anchor")
        session.addBeat(at: 16.25, position: 1)
        session.fillSelected()
        for _ in 0..<100 where session.isFilling { try await Task.sleep(for: .milliseconds(50)) }
        session.selectBeat(step: 1)
        try render("beat-match-4-filled")
        // The anchor the fill snapped: how far, and Undo Snap.
        session.selectedBeat = session.map.sections[0].beats.first { $0.heardTime != nil }?.time
        try SnapshotSupport.render(BeatMatchView(session: session, onConfirm: {}, onCancel: {}), "beat-match-4-snapped", size: CGSize(width: 1300, height: 900))

        // Started over on a song that had beats: Remove Beats.
        var matched = song
        matched.beatMap = session.map
        let again = BeatMatchSession(asset: matched, url: try #require(song.url))
        defer { again.end() }
        again.startOver()
        try SnapshotSupport.render(BeatMatchView(session: again, onConfirm: {}, onCancel: {}), "beat-match-5-remove", size: size)
    }

    /// The scene splitter on the last three shots of a four-shot movie,
    /// the second of them split by hand: two scenes picked, the marker in
    /// the second and the pointer skimming the next; then with the
    /// sensitivity slider being dragged, which shows the extra cut it
    /// would find before it is let go.
    @Test func sceneSplitter() async throws {
        let movie = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-splitter-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await writeMovie(to: movie, segments: [(90, 24), (200, 24), (120, 24), (230, 24)])
        var footage = MediaClip(
            name: "Skate.mov", kind: .video, url: movie, duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        footage.sceneEdits.manualCuts = [CMTime(value: 60, timescale: 24)]
        var scores = [UInt8](repeating: 2, count: 96)
        scores[0] = 0
        for frame in [24, 48, 72] { scores[frame] = 200 }
        // A small change, a cut only at a high sensitivity.
        scores[84] = 14
        let track = ChangeScoreTrack(timescale: 24, times: (0..<96).map(Int64.init), scores: scores)
        var project = EditingProject.empty
        project.addMedia(footage)

        let splitter = SceneSplitter()
        splitter.sceneTracks = { [footage.id: track] }
        splitter.update(project: project)
        splitter.openWithoutPanel(SceneSplitter.Focus(assetID: footage.id, start: CMTime(value: 1, timescale: 1), end: CMTime(value: 4, timescale: 1)))
        defer { splitter.skim.end() }
        // Scenes 3 and 4 picked, the marker in 4, the pointer skimming 5.
        splitter.click(atSeconds: 1.2)
        splitter.click(atSeconds: 1.75, modifiers: .shift)
        splitter.hover(atSeconds: 2.4)
        let size = CGSize(width: 680, height: 600)
        // The strip's pictures load in the background.
        try await SnapshotSupport.render(SceneSplitterView(splitter: splitter), "scene-splitter", size: size, settle: .seconds(2))
        splitter.drag(sensitivity: 0.95)
        try SnapshotSupport.render(SceneSplitterView(splitter: splitter), "scene-splitter-sensitivity", size: size)
        // Made larger, the picture takes the room and the strip stays at
        // the bottom.
        try SnapshotSupport.render(SceneSplitterView(splitter: splitter), "scene-splitter-large", size: CGSize(width: 960, height: 800))
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

    /// The editor of a new project with no media: the Clips tab offers
    /// Import Media… and the viewer says how to begin.
    @Test func emptyEditor() throws {
        let project = EditingProject.empty
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "empty-editor", size: CGSize(width: 1500, height: 900))
    }

    /// Over the Clips list: one file missing and two changed on disk, each
    /// with the button that deals with them.
    @Test func mediaProblemsBar() throws {
        let controller = MediaReplacementController()
        controller.markMissing([UUID()])
        controller.markChanged([UUID(), UUID()])
        let context = MediaReplacementController.Context(project: .constant(.empty), analysis: AssetAnalysis(), packageURL: nil)
        try SnapshotSupport.render(
            MediaProblemsBar(controller: controller, context: context)
                .frame(width: 300)
                .background(Design.Surface.base.color)
                .preferredColorScheme(.dark),
            "media-problems-bar", size: CGSize(width: 300, height: 70)
        )
    }

    /// The start sheet with three recent projects, two of one name in
    /// different folders.
    @Test func projectStart() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let recents = [
            home.appendingPathComponent("Movies/Music Video.amv"),
            home.appendingPathComponent("Movies/Tests/Music Video.amv"),
            URL(fileURLWithPath: "/Volumes/Projects/Trailer.amv"),
        ]
        try SnapshotSupport.render(
            ProjectStartView(recents: recents, onNew: {}, onOpen: {}),
            "project-start", size: CGSize(width: 560, height: 470)
        )
    }

    /// The Effects Library's transitions, the Audio ones last.
    @Test func transitionsPanel() throws {
        try SnapshotSupport.render(
            TransitionsPanel().preferredColorScheme(.dark),
            "transitions-panel", size: CGSize(width: 320, height: 1100)
        )
    }

    /// Timeline Settings for a timeline with a teal preview background.
    @Test func timelineSettings() async throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        project.updateTimeline(timelineID) { $0.previewBackground = [0.1, 0.5, 0.55] }
        try await SnapshotSupport.render(
            TimelineSettingsSheet(mode: .edit(timelineID), project: .constant(project), isPresented: .constant(true))
                .preferredColorScheme(.dark),
            "timeline-settings", size: CGSize(width: 520, height: 520), settle: .milliseconds(200)
        )
    }

    /// The Timelines tab: Main embeds Chorus, which embeds Logo; Outtakes
    /// is embedded nowhere. Main is the one open.
    @Test func timelinesList() throws {
        var project = EditingProject.empty
        let size = CGSize(width: 1920, height: 1080)
        let chorus = project.addTimeline(name: "Chorus", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let logo = project.addTimeline(name: "Logo", frameSize: size, frameRate: 24, colorSpace: .rec709)
        _ = project.addTimeline(name: "Outtakes", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let still = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        _ = project.importClip(still, intoTimeline: logo)
        _ = project.importClip(still, intoTimeline: chorus)
        _ = project.embedTimeline(logo, intoTimeline: chorus)
        _ = project.embedTimeline(chorus, intoTimeline: project.rootTimelineID)
        let defaults = try #require(UserDefaults(suiteName: "amv-snapshot-timelines-tree"))
        defaults.set(TimelinesLayout.tree.rawValue, forKey: Preferences.timelinesLayout)
        try SnapshotSupport.render(
            TimelinesList(project: project, activeTimelineID: project.rootTimelineID, onOpen: { _ in }, onEmbed: { _, _ in }, onDuplicate: { _ in })
                .defaultAppStorage(defaults)
                .frame(width: 260, height: 260)
                .background(Design.Surface.base.color)
                .preferredColorScheme(.dark),
            "timelines-list", size: CGSize(width: 260, height: 260)
        )
    }

    /// Find All on a clip used three times: twice on Main, on two layers,
    /// and once as the input of a matte on a timeline of its own.
    @Test func usesFinder() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let shot = MediaClip(
            name: "Beach.mov", kind: .video, url: nil, duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        _ = project.importClip(shot, intoTimeline: main)
        _ = project.addPieces(
            [MediaPiece(assetID: shot.id, start: .zero, end: CMTime(seconds: 2, preferredTimescale: 600))],
            intoTimeline: main, at: CMTime(seconds: 7, preferredTimescale: 600)
        )
        let titles = project.addTimeline(name: "Titles", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let card = MediaClip(
            name: "Card", kind: .video, url: nil, duration: CMTime(seconds: 3, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        let imported = project.importClip(card, intoTimeline: titles)
        let placed = try #require(imported)
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .asset(shot.id))
        project.editClip(placed.clipID, in: titles) { $0.effects = [matte] }
        let finder = UsesFinder()
        finder.update(project: project)
        finder.showWithoutPanel([UsesFinder.Query(item: .media(shot.id), range: nil, name: shot.name)])
        try SnapshotSupport.render(UsesFinderView(finder: finder), "uses-finder", size: CGSize(width: 620, height: 260))
    }

    /// The Clips tab: a video under its name as five scenes (the fourth
    /// set by hand), the second and third underlined where Main uses them,
    /// then a song as one clip, a thumbnail each.
    @Test func clipsTab() async throws {
        let movie = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-clips-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await writeMovie(to: movie, segments: [(90, 24), (200, 24), (120, 24), (230, 24)])
        var footage = MediaClip(
            name: "Skate.mov", kind: .video, url: movie, duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        footage.sceneEdits.manualCuts = [CMTime(value: 60, timescale: 24)]
        var scores = [UInt8](repeating: 2, count: 96)
        scores[0] = 0
        for frame in [24, 48, 72] { scores[frame] = 200 }
        let track = ChangeScoreTrack(timescale: 24, times: (0..<96).map(Int64.init), scores: scores)
        let song = try SnapshotSupport.clickSong(named: "clips-tab-song")
        var project = EditingProject.empty
        project.addMedia(footage)
        project.addMedia(song)
        _ = project.addPieces(
            [MediaPiece(assetID: footage.id, start: CMTime(value: 30, timescale: 24), end: CMTime(value: 54, timescale: 24))],
            intoTimeline: project.rootTimelineID
        )
        let access = ProjectAccess()
        access.value = project
        let analysis = AssetAnalysis()
        // Scores are kept only with the file they were read from.
        let stamp = try #require(FileStamp(url: movie))
        analysis.reset(tracks: [footage.id: track], sources: AnalysisSources(scores: [footage.id: stamp]))

        let defaults = try #require(UserDefaults(suiteName: "amv-snapshot-clips-tab"))
        defaults.set(ThumbnailInterval.all.rawValue, forKey: Preferences.thumbnailInterval)
        defaults.set(ThumbnailSize.small.rawValue, forKey: Preferences.thumbnailSize)
        let size = CGSize(width: 300, height: 520)
        try await SnapshotSupport.render(
            ClipsTab(
                access: access, activeTimelineID: project.rootTimelineID, selection: .constant(nil), analysis: analysis,
                replacement: MediaReplacementController(), packageURL: nil, revealing: .constant(nil), onImport: {}
            )
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            .background(Design.Surface.base.color)
            .preferredColorScheme(.dark),
            "clips-tab", size: size, settle: .seconds(2)
        )
    }

    /// The Timelines tab as filmstrips: Main embeds a dark-then-bright
    /// Chorus for its first two seconds, so Chorus is underlined there.
    /// Each strip's frames are made from its own timeline.
    @Test func timelineFilmstrips() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let size = fixture.project.timelines[0].frameSize
        let chorus = fixture.project.addTimeline(name: "Chorus", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let url = fixture.directory.appending(path: "chorus.mov")
        try await writeMovie(to: url, segments: [(luma: 50, frames: 48), (luma: 210, frames: 48)])
        let media = MediaClip(
            name: "chorus", kind: .video, url: url, duration: CMTime(value: 96, timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        _ = fixture.project.importClip(media, intoTimeline: chorus)
        _ = fixture.project.embedTimeline(chorus, intoTimeline: fixture.timelineID, range: CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)))

        let defaults = try #require(UserDefaults(suiteName: "amv-snapshot-timelines-filmstrips"))
        defaults.set(TimelinesLayout.filmstrips.rawValue, forKey: Preferences.timelinesLayout)
        defaults.set(ThumbnailInterval.oneSecond.rawValue, forKey: Preferences.thumbnailInterval)
        defaults.set(ThumbnailSize.small.rawValue, forKey: Preferences.thumbnailSize)
        try await SnapshotSupport.render(
            TimelinesList(project: fixture.project, activeTimelineID: fixture.timelineID, onOpen: { _ in }, onEmbed: { _, _ in }, onDuplicate: { _ in })
                .defaultAppStorage(defaults)
                .frame(width: 320, height: 240)
                .background(Design.Surface.base.color)
                .preferredColorScheme(.dark),
            "timeline-filmstrips", size: CGSize(width: 320, height: 240), settle: .seconds(3)
        )
    }

    /// A transition's shaded wedge with its curve editor over it, as on a
    /// selected clip: the wedge's edge is the editor's line, a way in
    /// (linear) beside a way out (eased).
    @Test func transitionWedgeAndCurve() throws {
        func mark(_ curve: TransitionCurve, _ edge: TransitionEdge) -> some View {
            let size = CGSize(width: 180, height: 60)
            return ZStack(alignment: .topLeading) {
                Design.ClipTone.video.color
                TransitionWedge(curve: curve, edge: edge).fill(Color.white.opacity(0.34))
                TransitionCurveEditor(curve: curve, edge: edge, size: size, onChange: { _ in })
            }
            .frame(width: size.width, height: size.height)
        }
        try SnapshotSupport.render(
            HStack(spacing: 20) {
                mark(TransitionCurve(preset: .linear), .leading)
                mark(TransitionCurve(preset: .easyEase), .trailing)
            }
            .padding(16)
            .background(Design.Surface.sunken.color)
            .preferredColorScheme(.dark),
            "transition-wedge-curve", size: CGSize(width: 412, height: 92)
        )
    }

    /// An expanded transition joining two clips with sound: its footage
    /// lane, then its sound lane in each crossfade shape (S-curve, the
    /// project's, then equal power and linear).
    @Test func expandedTransition() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(
            name: "Interview", kind: .video, url: nil, duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: t)
        let placed = try #require(imported)
        project.trimClipEnd(placed.clipID, in: t, layer: placed.layerID, to: CMTime(seconds: 4, preferredTimescale: 600))
        let b = TimelineClip(
            source: .media(media.id), startOffset: CMTime(seconds: 4, preferredTimescale: 600),
            trimStart: CMTime(seconds: 6, preferredTimescale: 600), trimEnd: CMTime(seconds: 9, preferredTimescale: 600)
        )
        let tIndex = try #require(project.timelines.firstIndex { $0.id == t })
        project.timelines[tIndex].layers[0].clips.append(b)
        project.setTransition(.crossDissolve, at: .leading, of: b.id, in: t, layer: placed.layerID)
        project.applyJointEdit(.place(duration: CMTime(seconds: 2, preferredTimescale: 600), lead: CMTime(seconds: 1, preferredTimescale: 600)), at: b.id, in: t, layer: placed.layerID)
        let joint = try #require(project.joint(at: b.id, in: t, layer: placed.layerID))
        func sound(_ shape: AudioCrossfade?) -> some View {
            var shaped = joint
            shaped.transition.audioCrossfade = shape
            return TransitionSoundLane(joint: shaped, projectCrossfade: .sCurve, pixelsPerSecond: 60, width: 480, onSetCrossfade: { _ in })
        }
        try SnapshotSupport.render(
            VStack(spacing: 2) {
                TransitionFootageLane(
                    joint: joint, frameRate: 24, outgoingName: "Interview", incomingName: "Interview",
                    pixelsPerSecond: 60, width: 480, visibleX: 0...480,
                    preview: { _ in nil }, onCommit: { _ in }, tool: .arrow, onTrimPreview: { _, _ in }
                )
                sound(nil)
                sound(.equalPower)
                sound(.linear)
            }
            .background(Design.Surface.sunken.color)
            .preferredColorScheme(.dark),
            "expanded-transition", size: CGSize(width: 480, height: TransitionFootageLane.height + 3 * TransitionSoundLane.height + 6)
        )
    }

    /// A name beside its icon, shown and being renamed: the field is
    /// bordered, and neither the icon nor the name moves.
    @Test func inlineNameField() throws {
        func row(editing: Bool) -> some View {
            Label {
                InlineNameField(name: "Chorus", isEditing: .constant(editing), onCommit: { _ in })
                    .foregroundStyle(Design.textPrimary)
            } icon: {
                Image(systemName: "rectangle.stack").foregroundStyle(Design.ClipTone.nested.color)
            }
            .font(Design.Typeface.label)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        try SnapshotSupport.render(
            VStack(alignment: .leading, spacing: 12) {
                row(editing: false)
                row(editing: true)
            }
            .padding(16)
            .frame(width: 260, alignment: .topLeading)
            .background(Design.Surface.base.color)
            .preferredColorScheme(.dark),
            "inline-name-field", size: CGSize(width: 260, height: 90)
        )
    }

    /// The toolbar's warning while automatic backups fail.
    @Test func autosaveWarning() throws {
        let status = AutosaveStatus()
        status.failed("The disk is full.")
        try SnapshotSupport.render(
            AutosaveWarning()
                .environment(status)
                .padding(10)
                .background(Design.Surface.raised.color)
                .preferredColorScheme(.dark),
            "autosave-warning", size: CGSize(width: 220, height: 44)
        )
    }

    /// Help > Keyboard Shortcuts: every key the editor answers, grouped.
    @Test func keyboardShortcuts() throws {
        try SnapshotSupport.render(KeyboardShortcutsView(), "keyboard-shortcuts", size: CGSize(width: 720, height: 620))
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

    /// The inspector for a text layer of two lines, right-aligned, with its
    /// size keyframed (shown read-only, with the keyframe badge): the
    /// words; Character and Paragraph as fields with icons two to a row,
    /// alignment, case, underline and OpenType as icon buttons; and a
    /// yellow fill with a stroke, its edge, join and cap as drawn buttons.
    @Test func textInspector() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let added = project.addShapeLayer(.text, to: t)
        let text = try #require(added)
        project.editClip(text.clipID, in: t) { clip in
            clip.effects[0].text?.string = "Animation\nmeets video"
            clip.effects[0].changeControl(.textAlign) { $0.choice = TextAlign.right.rawValue }
            clip.effects[0].changeControl(.tracking) { $0.setComponent(0, to: 40, at: .zero) }
            clip.effects[0].changeControl(.underline) { $0.choice = OnOff.on.rawValue }
            clip.effects[0].changeControl(.figures) { $0.choice = TextFigures.tabularLining.rawValue }
            clip.effects[0].changeControl(.fill) { $0.number = AnimatedValue(ComponentValue(values: [1, 0.8, 0.1, 1])) }
            clip.effects[0].changeControl(.strokeWidth) { $0.setComponent(0, to: 6, at: .zero) }
            clip.effects[0].changeControl(.fontSize) { size in
                size.number.setAnimated(true, at: .zero)
                size.setComponent(0, to: 160, at: CMTime(seconds: 2, preferredTimescale: 600))
            }
        }
        let clip = try #require(project.clipAndLayer(text.clipID, in: t)?.clip)
        try SnapshotSupport.render(
            InspectorPanel(
                project: .constant(project), timelineID: t,
                selection: TimelineSelection(timelineID: t, layerID: text.layerID, timelineClipID: text.clipID),
                info: project.resolvedInfo(for: clip), timelineClip: clip, playheadTime: .zero, onSeek: { _ in }, onDeleteSelection: {}
            ),
            "text-inspector", size: CGSize(width: 340, height: 1700)
        )
    }

    /// A Text effect's groups with "meets" selected, set apart in red and
    /// with a size keyframed from 80 to 160 pixels: the selected letters'
    /// rows, their own settings with a button giving the block's back, the
    /// size read-only with its badge, and the block's that can't be.
    @Test func textSelectionInspector() throws {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "Animation meets video")
        effect.text?.changeStyle(in: NSRange(location: 10, length: 5)) { style in
            var size = AnimatedValue(80.0)
            size.setAnimated(true, at: .zero)
            size.set(160, at: CMTime(seconds: 1, preferredTimescale: 600))
            style.size = size
            style.fill = AnimatedValue(ComponentValue(values: [1, 0.2, 0.2, 1]))
        }
        try SnapshotSupport.render(
            ScrollView {
                TextInspectorGroup(
                    effect: effect, prefix: nil, playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in },
                    selection: NSRange(location: 10, length: 5)
                )
                .padding(Design.Space.group)
            }
            .panelSurface(.base),
            "text-selection-inspector", size: CGSize(width: 340, height: 1300)
        )
    }

    /// A Text effect's Character group with the cursor between "A" and
    /// "V", kerned by hand: the block's rows and the pair's Kern row.
    @Test func textPairKerningInspector() throws {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "AVATAR")
        effect.text?.changeStyle(in: NSRange(location: 0, length: 1)) { $0.kerning = AnimatedValue(-60) }
        try SnapshotSupport.render(
            ScrollView {
                TextInspectorGroup(
                    effect: effect, prefix: nil, playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in },
                    selection: NSRange(location: 1, length: 0)
                )
                .padding(Design.Space.group)
            }
            .panelSurface(.base),
            "text-pair-kerning-inspector", size: CGSize(width: 340, height: 700)
        )
    }

    /// A Text effect in Skia, a variable font: its Weight and Width fields,
    /// the weight keyframed and so read-only.
    @Test func textVariableFontInspector() throws {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "Variable", fontName: "Skia-Regular")
        effect.text?.changeVariation("wght", initial: 1) { value in
            value.setAnimated(true, at: .zero)
            value.set(2, at: CMTime(seconds: 1, preferredTimescale: 600))
        }
        try SnapshotSupport.render(
            ScrollView {
                TextInspectorGroup(effect: effect, prefix: nil, playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in })
                    .padding(Design.Space.group)
            }
            .panelSurface(.base),
            "text-variable-font-inspector", size: CGSize(width: 340, height: 520)
        )
    }

    /// The inspector's clip sound rows, which don't keyframe: a fixed pan
    /// to type or drag, and a keyframed volume shown read-only with its
    /// badge.
    @Test func inspectorSoundRows() throws {
        var volume = AnimatedValue(-6.0)
        volume.setAnimated(true, at: .zero)
        volume.set(0, at: CMTime(seconds: 1, preferredTimescale: 600))
        try SnapshotSupport.render(
            InspectorGroup("Sound") {
                AudioPropertyRow(
                    value: volume, playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in }, keyframing: false
                )
                AudioPropertyRow(
                    property: .pan, value: AnimatedValue(-30), playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in },
                    keyframing: false
                )
            }
            .padding(Design.Space.group)
            .panelSurface(.base),
            "inspector-sound-rows", size: CGSize(width: 340, height: 120)
        )
    }

    /// The inspector for a text layer with a Text Animator below its Text
    /// effect: the animator's range, shape and properties, its Fill off.
    @Test func textAnimatorInspector() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let added = project.addShapeLayer(.text, to: t)
        let text = try #require(added)
        _ = project.addEffect(.textAnimator, toClip: text.clipID, in: t)
        project.editClip(text.clipID, in: t) { clip in
            clip.effects[1].changeControl(.animatorEnd) { range in
                range.number.setAnimated(true, at: .zero)
                range.setComponent(0, to: 0, at: .zero)
                range.setComponent(0, to: 100, at: CMTime(seconds: 2, preferredTimescale: 600))
            }
            clip.effects[1].changeControl(.animatorPosition) { $0.number = AnimatedValue(ComponentValue(values: [0, -80])) }
            clip.effects[1].changeControl(.animatorOpacity) { $0.setComponent(0, to: 0, at: .zero) }
            clip.effects[1].changeControl(.animatorShape) { $0.choice = TextAnimatorShape.rampDown.rawValue }
        }
        let clip = try #require(project.clipAndLayer(text.clipID, in: t)?.clip)
        try SnapshotSupport.render(
            InspectorPanel(
                project: .constant(project), timelineID: t,
                selection: TimelineSelection(timelineID: t, layerID: text.layerID, timelineClipID: text.clipID),
                info: project.resolvedInfo(for: clip), timelineClip: clip, playheadTime: .zero, onSeek: { _ in }, onDeleteSelection: {}
            ),
            "text-animator-inspector", size: CGSize(width: 340, height: 2400)
        )
    }

    /// What the compositor's shape steps draw for a stack of a circle, a
    /// Text effect on its path, and a Text Animator raising and reddening
    /// the first word: the words around the circle. Drawn here with
    /// SwiftUI from the same paints, to see the glyphs' placement.
    @Test func textOnPathDrawing() throws {
        var circle = Effect(kind: .ellipse)
        circle.changeControl(.shapeSize) { $0.number = AnimatedValue(ComponentValue(values: [500, 500])) }
        circle.changeControl(.fill) { $0.number = AnimatedValue(ComponentValue(values: [0.15, 0.3, 0.6, 1])) }
        var text = Effect(kind: .text)
        text.text = TextContent(string: "Animation meets video · around and around")
        text.changeControl(.fontSize) { $0.setComponent(0, to: 44, at: .zero) }
        text.changeControl(.textOnPath) { $0.choice = OnOff.on.rawValue }
        text.changeControl(.underline) { $0.choice = OnOff.on.rawValue }
        text.changeControl(.strokeWidth) { $0.setComponent(0, to: 2, at: .zero) }
        var animator = Effect(kind: .textAnimator)
        animator.changeControl(.animatorEnd) { $0.setComponent(0, to: 25, at: .zero) }
        animator.changeControl(.animatorPosition) { $0.number = AnimatedValue(ComponentValue(values: [0, -12])) }
        animator.changeControl(.animatorFill) { $0.enabled = true }
        animator.changeControl(.animatorStroke) { $0.enabled = true; $0.number = AnimatedValue(ComponentValue(values: [1, 1, 0.3, 1])) }
        // From the top, clockwise round the outside, as in Illustrator.
        text.changeControl(.textAlign) { $0.choice = TextAlign.left.rawValue }
        // And flipped: inside, the other way round.
        var inside = Effect(kind: .text)
        inside.text = TextContent(string: "flipped inside")
        inside.changeControl(.fontSize) { $0.setComponent(0, to: 36, at: .zero) }
        inside.changeControl(.textAlign) { $0.choice = TextAlign.left.rawValue }
        inside.changeControl(.textOnPath) { $0.choice = OnOff.on.rawValue }
        inside.changeControl(.pathFlip) { $0.choice = OnOff.on.rawValue }
        inside.changeControl(.fill) { $0.number = AnimatedValue(ComponentValue(values: [0.6, 0.9, 1, 1])) }
        let steps = StackFolding.steps(
            effects: [circle, text, animator, inside], anchorPoint: AnimatedValue(.zero), at: .zero, center: CGPoint(x: 350, y: 350)
        )
        var paints: [(area: CGPath, color: [Double])] = []
        for case .shape(let shape) in steps { paints += shape.paints }
        try SnapshotSupport.render(
            Canvas { context, _ in
                for paint in paints where paint.color.count == 4 {
                    context.fill(
                        Path(paint.area),
                        with: .color(Color(.sRGB, red: paint.color[0], green: paint.color[1], blue: paint.color[2], opacity: paint.color[3]))
                    )
                }
            }
            .background(Color.black),
            "text-on-path", size: CGSize(width: 700, height: 700)
        )
    }

    /// The inspector for a shape layer: a rounded rectangle's size, corners
    /// and position, then its fill and a dashed outside stroke.
    @Test func shapeInspector() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: t)
        let shape = try #require(added)
        project.editClip(shape.clipID, in: t) { clip in
            clip.effects[0].changeControl(.cornerRadius) { $0.setComponent(0, to: 24, at: .zero) }
            clip.effects[0].changeControl(.fill) { $0.number = AnimatedValue(ComponentValue(values: [0.2, 0.5, 0.9, 0.75])) }
            clip.effects[0].changeControl(.stroke) { $0.number = AnimatedValue(ComponentValue(values: [1, 1, 1, 1])) }
            clip.effects[0].changeControl(.strokeWidth) { $0.setComponent(0, to: 8, at: .zero) }
            clip.effects[0].changeControl(.strokeEdge) { $0.choice = StrokeEdge.outside.rawValue }
            clip.effects[0].changeControl(.dash) { $0.number = AnimatedValue(ComponentValue(values: [20, 10])) }
        }
        let clip = try #require(project.clipAndLayer(shape.clipID, in: t)?.clip)
        try SnapshotSupport.render(
            InspectorPanel(
                project: .constant(project), timelineID: t,
                selection: TimelineSelection(timelineID: t, layerID: shape.layerID, timelineClipID: shape.clipID),
                info: project.resolvedInfo(for: clip), timelineClip: clip, playheadTime: .zero, onSeek: { _ in }, onDeleteSelection: {}
            ),
            "shape-inspector", size: CGSize(width: 340, height: 820)
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

    /// The tone graphs: Curves with an S curve on RGB and red lifted, the
    /// RGB curve picked; Levels with its black, gamma and white handles on
    /// its measured line; Highs & Lows with shadows lifted.
    @Test func toneGraphs() async throws {
        func setting(_ id: String, _ settings: [String: [Double]]) throws -> Effect {
            var effect = Effect(kind: try #require(EffectKind(rawValue: id)))
            for index in effect.controls.indices {
                if let values = settings[effect.controls[index].kind.savedName] {
                    effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
                }
            }
            return effect
        }
        let size = CGSize(width: 440, height: ToneGraph.panelHeight)
        let cases: [(String, Effect)] = [
            ("tone-graph-curves", try setting("curves", [
                "masterCurve": [0.06, 0, 0.25, 0.18, 0.75, 0.84, 0.92, 1], "redCurve": [0, 0.08, 1, 1],
            ])),
            ("tone-graph-levels", try setting("levels", [
                "inputBlack": [12], "inputWhite": [88], "levelsGamma": [1.6], "outputBlack": [4],
            ])),
            ("tone-graph-highs-lows", try setting("shadowsHighlights", ["shadows": [70], "highlights": [-40]])),
        ]
        for (name, effect) in cases {
            try await SnapshotSupport.render(
                ToneGraph(effect: effect, time: .zero, onEdit: { _, _ in })
                    .frame(width: size.width, height: size.height)
                    .background(Design.Surface.overlay.color),
                name, size: size, settle: .seconds(1)
            )
        }
    }

    /// A Sound layer's sound effects in the inspector: an EQ and a
    /// compressor, closed, and the menu to add more.
    @Test func layerSoundEffectsList() throws {
        var (project, _, layerID) = try AudioMixSupport.project(playing: URL(filePath: "/dev/null"))
        let timelineID = project.rootTimelineID
        project.addEffect(.equalizer, toLayer: layerID, in: timelineID)
        project.addEffect(.compressor, toLayer: layerID, in: timelineID)
        let layer = try #require(project.timeline(id: timelineID)?.layer(id: layerID))
        try SnapshotSupport.render(
            LayerSoundEffectsList(project: .constant(project), timelineID: timelineID, layer: layer, time: .zero)
                .padding(8)
                .background(Design.Surface.overlay.color),
            "layer-sound-effects", size: CGSize(width: 300, height: 120)
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

    /// The effects panel for a shape clip: the rectangle pinned at the top
    /// as the clip's own content, with rounded corners, an orange fill and
    /// a stroke, so the color wells show; its Shape and Fill & Stroke
    /// headers, and no Edge, Join or Cap, which are the inspector's.
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
            "shape-effects-panel", size: CGSize(width: 520, height: 480)
        )
    }

    /// The effects panel for a text layer in Skia, a variable font, its
    /// Text effect cut down to Size: rows for its Weight and Width axes
    /// after Size under Character, the weight keyframed, with its lane.
    @Test func textAxesEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.text, to: timelineID)
        let text = try #require(added)
        project.editClip(text.clipID, in: timelineID) { clip in
            clip.effects[0].controls = clip.effects[0].controls.filter { $0.kind == .fontSize }
            clip.effects[0].text?.fontName = "Skia-Regular"
            clip.effects[0].text?.changeVariation("wght", initial: 1) { value in
                value.setAnimated(true, at: CMTime(seconds: 1, preferredTimescale: 600))
                value.set(0.6, at: CMTime(seconds: 1, preferredTimescale: 600))
                value.set(2.5, at: CMTime(seconds: 3, preferredTimescale: 600))
            }
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: text.layerID, timelineClipID: text.clipID),
                playheadTime: CMTime(seconds: 2, preferredTimescale: 600), state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "text-axes-effects-panel", size: CGSize(width: 620, height: 300)
        )
    }

    /// The effects panel for a text clip in Skia, a variable font, with a
    /// Transform after it: the Text pinned at the top as the clip's own
    /// content, its numbers and colors under Character (the font's axes
    /// last), Paragraph, Path, OpenType and Fill & Stroke headers, none of
    /// its choices, and the Transform in the stack below the anchor point.
    @Test func textEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.text, to: timelineID)
        let text = try #require(added)
        project.editClip(text.clipID, in: timelineID) { clip in
            clip.effects[0].text?.fontName = "Skia-Regular"
            clip.effects[0].changeControl(.tracking) { control in
                control.number.setAnimated(true, at: .zero)
                control.number.set(ComponentValue(values: [0]), at: .zero)
                control.number.set(ComponentValue(values: [200]), at: CMTime(seconds: 2, preferredTimescale: 600))
            }
        }
        _ = project.addEffect(.transform, toClip: text.clipID, in: timelineID)
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: text.layerID, timelineClipID: text.clipID),
                playheadTime: CMTime(seconds: 1, preferredTimescale: 600), state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "text-effects-panel", size: CGSize(width: 620, height: 1100)
        )
    }

    /// The effects panel for a text clip with "meets" set apart: after the
    /// text's own sections, a Letters “meets” header with its keyframed
    /// Size and its Fill, the settings it has its own of.
    @Test func textRunEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.text, to: timelineID)
        let text = try #require(added)
        project.editClip(text.clipID, in: timelineID) { clip in
            clip.effects[0].text = TextContent(string: "Animation meets video")
            clip.effects[0].text?.changeStyle(in: NSRange(location: 10, length: 5)) { style in
                var size = AnimatedValue(80.0)
                size.setAnimated(true, at: .zero)
                size.set(160, at: CMTime(seconds: 2, preferredTimescale: 600))
                style.size = size
                style.fill = AnimatedValue(ComponentValue(values: [1, 0.2, 0.2, 1]))
            }
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: text.layerID, timelineClipID: text.clipID),
                playheadTime: CMTime(seconds: 1, preferredTimescale: 600), state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "text-run-effects-panel", size: CGSize(width: 620, height: 1200)
        )
    }

    /// The effects library with a package that couldn't be read and a look
    /// whose kernel doesn't compile: the chip is marked, and both are
    /// listed at the end with why.
    @Test func effectsLibraryProblems() throws {
        let project = EditingProject.empty
        let unread = EffectPackageProblem(
            url: URL(filePath: "/Effects/Glow.amveffect"),
            message: "The package can't be used. Unknown name \"spped\" at arguments[1]."
        )
        let status = EffectPackageStatus(kernelProblems: ["hueCycle": "kernel.metal:4:12: use of undeclared identifier 'turnn'"])
        try EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns(problems: [unread])) {
            try SnapshotSupport.render(
                EffectsListPanel(
                    project: .constant(project), timelineID: project.rootTimelineID, selection: nil,
                    state: EffectsPanelState(), packageStatus: status
                ),
                "effects-library-problems", size: CGSize(width: 380, height: 1100)
            )
        }
    }

    /// A rectangle with an effect whose package isn't installed below it,
    /// and a copy turned off: each says what it is and does nothing.
    @Test func missingEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let saved = JSONValue.object(["id": .string(UUID().uuidString), "kind": .string("com.example.glow"), "controls": .array([])])
        let glow = Effect.missing(MissingEffect(kind: "com.example.glow", saved: saved), id: UUID(), enabled: true)
        var off = glow.duplicated()
        off.enabled = false
        project.editClip(shape.clipID, in: timelineID) { $0.effects += [glow, off] }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "missing-effects-panel", size: CGSize(width: 520, height: 520)
        )
    }

    /// The same panel with a rectangle size too wide for the control column:
    /// the column widens to fit it, and the lanes keep what is left.
    @Test func wideValuesEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        project.editClip(shape.clipID, in: timelineID) { clip in
            for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .shapeSize {
                clip.effects[0].controls[index].setComponent(0, to: 1_234_567, at: .zero)
                clip.effects[0].controls[index].setComponent(1, to: 7_654_321, at: .zero)
            }
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "wide-values-effects-panel", size: CGSize(width: 620, height: 420)
        )
    }

    /// The timeline's header inside a nested timeline: the timelines gone
    /// through to reach it before its own name, each a way back.
    @Test func timelineBreadcrumb() throws {
        var project = EditingProject.empty
        let outer = project.rootTimelineID
        let nested = project.addTimeline(name: "Nested 1", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let deeper = project.addTimeline(name: "Nested 2", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        try SnapshotSupport.render(
            TimelineHeaderBar(project: .constant(project), timelineID: .constant(deeper), trail: [outer, nested]),
            "timeline-breadcrumb", size: CGSize(width: 640, height: 44)
        )
    }

    /// The viewer's trim preview while a left edge is dragged: the first
    /// frame alone, with its timecode (black here, as no file is read).
    @Test func trimEdgePreview() throws {
        let model = TrimPreviewModel()
        let missing = URL(fileURLWithPath: "/nonexistent/clip.mov")
        model.show(.file(missing), first: .zero, last: .zero, labelFirst: CMTime(value: 49, timescale: 24), labelLast: .zero, frames: .first)
        try SnapshotSupport.render(
            TrimPreviewOverlay(model: model, frameRate: 24, aspectRatio: 16 / 9).padding(20),
            "trim-edge-preview", size: CGSize(width: 520, height: 340)
        )
    }

    /// The box over the pointer while something on the timeline is
    /// dragged: moved later, earlier, and back where it started; a
    /// transition lengthened; a slip.
    @Test func dragTimecodeLabel() throws {
        try SnapshotSupport.render(
            VStack(alignment: .leading, spacing: 12) {
                DragTimecodeLabel(value: .time(CMTime(value: 349, timescale: 24)), moved: CMTime(value: 36, timescale: 24), frameRate: 24)
                DragTimecodeLabel(value: .time(CMTime(value: 7_225, timescale: 24)), moved: CMTime(value: -1_441, timescale: 24), frameRate: 24)
                DragTimecodeLabel(value: .time(CMTime(value: 48, timescale: 24)), moved: .zero, frameRate: 24)
                DragTimecodeLabel(value: .length(CMTime(value: 30, timescale: 24)), moved: CMTime(value: 6, timescale: 24), frameRate: 24)
                DragTimecodeLabel(value: nil, moved: CMTime(value: -17, timescale: 24), frameRate: 24)
            }
            .padding(20)
            .background(Design.Surface.sunken.color)
            .preferredColorScheme(.dark),
            "drag-timecode-label", size: CGSize(width: 260, height: 210)
        )
    }

    /// Clip blocks on the timeline, a row each: a video clip with its
    /// pictures; the same selected, with its shadow outside it only; the
    /// same turned off, grey and faded, then also selected, its shadow's
    /// cleared inside not showing through; clips too narrow for a name,
    /// drawn as fill and outline; a sound clip's volume ramping up.
    @Test func clipBlocks() async throws {
        let movie = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-blocks-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await writeMovie(to: movie, segments: [(60, 24), (200, 24), (120, 24), (230, 24)])
        let footage = MediaClip(
            name: "Skate", kind: .video, url: movie, duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        let video = TimelineClip(source: .media(footage.id), startOffset: seconds(0.4), trimStart: .zero, trimEnd: seconds(4))
        var off = video
        off.enabled = false
        let narrow = TimelineClip(source: .media(footage.id), startOffset: seconds(0.4), trimStart: .zero, trimEnd: seconds(0.3))
        let sliver = TimelineClip(source: .media(footage.id), startOffset: seconds(1.2), trimStart: .zero, trimEnd: seconds(0.08))
        let wide = TimelineClip(source: .media(footage.id), startOffset: seconds(1.6), trimStart: .zero, trimEnd: seconds(2))
        var song = TimelineClip(source: .media(UUID()), startOffset: seconds(0.4), trimStart: .zero, trimEnd: seconds(8))
        song.streams = .audio
        song.volume = AnimatedValue(0, keyframes: [Keyframe(time: seconds(1), value: -30), Keyframe(time: seconds(5), value: 0)])

        func block(_ model: ClipBlockModel) -> some View {
            ClipBlockView(model: model, handlers: LiveClipHandlers(.inert()))
        }
        func row(_ height: CGFloat, @ViewBuilder _ blocks: () -> some View) -> some View {
            ZStack(alignment: .topLeading) { blocks() }
                .frame(width: 520, height: height, alignment: .topLeading)
        }
        let pictures = ResolvedClipInfo.media(footage)
        let view = VStack(alignment: .leading, spacing: 14) {
            row(64) { block(.sample(video, info: pictures, height: 64)) }
            row(64) { block(.sample(video, info: pictures, selected: true, height: 64)) }
            row(64) { block(.sample(off, info: pictures, height: 64)) }
            row(64) { block(.sample(off, info: pictures, selected: true, height: 64)) }
            row(40) {
                block(.sample(narrow, info: pictures))
                block(.sample(sliver, info: pictures))
                block(.sample(wide, info: pictures))
            }
            row(40) { block(.sample(song, info: nil, color: Design.ClipTone.audio.color, showsVolumeLine: true)) }
        }
        .padding(20)
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        try await SnapshotSupport.render(view, "clip-blocks", size: CGSize(width: 560, height: 460), settle: .seconds(2))
    }

    /// Nested timeline clips showing the timeline's own frames, as video
    /// clips show their file's: the second plays a second later into the
    /// same timeline, so its pictures sit a second further left, as a slip
    /// draws them.
    @Test func nestedClipBlocks() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "steps.mov")
        try await writeMovie(to: url, segments: [(40, 24), (200, 24), (110, 24), (235, 24)])
        let media = MediaClip(
            name: "steps", kind: .video, url: url, duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let size = fixture.project.timelines[0].frameSize
        let inner = fixture.project.addTimeline(name: "Chorus", frameSize: size, frameRate: 24, colorSpace: .rec709)
        _ = fixture.project.importClip(media, intoTimeline: inner)
        let timeline = try #require(fixture.project.timeline(id: inner))
        let previews = NestedTimelinePreviews()
        previews.projectChanged(fixture.project)

        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        let nested = TimelineClip(source: .timeline(inner), startOffset: seconds(0.4), trimStart: .zero, trimEnd: seconds(3))
        var slipped = nested
        slipped.trimStart = seconds(1)
        slipped.trimEnd = seconds(4)
        let tone = Design.ClipTone.nested.color
        func row(_ clip: TimelineClip, tool: TimelineTool = .arrow) -> some View {
            ClipBlockView(model: .sample(clip, info: .timeline(timeline), color: tone, height: 64, tool: tool), handlers: LiveClipHandlers(.inert()))
                .frame(width: 520, height: 64, alignment: .topLeading)
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            row(nested)
            row(slipped, tool: .slip)
        }
        .padding(20)
        .environment(previews)
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        try await SnapshotSupport.render(view, "nested-clip-blocks", size: CGSize(width: 560, height: 182), settle: .seconds(3))
    }

    /// A selected effect outlined whole, its controls included, in the
    /// active panel (accent) and in one that isn't (grey).
    @Test func selectedEffectOutline() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        project.addEffect(.color, toClip: shape.clipID, in: timelineID)
        let selected = try #require(project.clipAndLayer(shape.clipID, in: timelineID)?.clip.effects.last?.id)
        for active in [true, false] {
            let state = EffectsPanelState()
            state.select(effect: selected)
            try SnapshotSupport.render(
                EffectsPanel(
                    project: .constant(project), timelineID: timelineID,
                    selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                    playheadTime: .zero, state: state, onSeek: { _ in }, onSelectTransition: { _ in }
                )
                .environment(\.isInActivePanel, active),
                active ? "selected-effect-active" : "selected-effect-inactive", size: CGSize(width: 520, height: 520)
            )
        }
    }

    /// A Wiggler writing to a rectangle's Position, above an Oscillator
    /// whose target is gone: their Target, Component and Combine rows, the
    /// curve in place of a thumbnail, the generated keyframes in the lane
    /// and the note on the one that writes nothing.
    @Test func keyframingEffectsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let ids = [EffectKind.oscillator, .wiggler].map { project.addEffect($0, toClip: shape.clipID, in: timelineID) }
        let oscillatorID = try #require(ids[0])
        project.editEffect(oscillatorID, ofClip: shape.clipID, in: timelineID) {
            $0.keyframing?.target = .control(effectID: UUID(), controlID: UUID())
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "keyframing-effects-panel", size: CGSize(width: 560, height: 640)
        )
    }

    /// A selected Wiggler writing to the second and third seconds of its
    /// clip: its range as a band over the ruler, with a handle at each end.
    @Test func keyframingRangeBar() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let wiggler = project.addEffect(.wiggler, toClip: shape.clipID, in: timelineID)
        let id = try #require(wiggler)
        let clip = try #require(project.clipAndLayer(shape.clipID, in: timelineID)?.clip)
        project.editEffect(id, ofClip: shape.clipID, in: timelineID) {
            $0.keyframing?.setRange(start: CMTime(value: 1, timescale: 1), end: CMTime(value: 3, timescale: 1), in: clip)
        }
        let state = EffectsPanelState()
        state.select(effect: id)
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: state, onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "keyframing-range-bar", size: CGSize(width: 640, height: 200)
        )
    }

    /// A Wiggler whose keyframes were edited by hand before its clip was
    /// trimmed: the Regenerate and Keep Edits row.
    @Test func keyframingEditsPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        _ = project.addEffect(.wiggler, toClip: shape.clipID, in: timelineID)
        project.editClip(shape.clipID, in: timelineID) { clip in
            clip.effects[1].controls[0].number.set(ComponentValue(values: [800, 400]), at: CMTime(value: 1, timescale: 1))
            clip.trimEnd = CMTimeSubtract(clip.trimEnd, CMTime(value: 1, timescale: 1))
        }
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "keyframing-edits-panel", size: CGSize(width: 560, height: 360)
        )
    }

    /// Audio Keys listening to a song's low burst, with the playhead in
    /// it: Listen To, the spectrum and its box, and the settings.
    @Test func audioKeysPanel() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let url = URL(fileURLWithPath: "/tmp/audio-keys-snapshot-\(UUID().uuidString).wav")
        let samples = tone(60, amplitude: 0.5, seconds: 1) + tone(2500, amplitude: 0.05, seconds: 1)
        SpectrogramStore.shared.set(Spectrogram.analyze(zip(samples, tone(400, amplitude: 0.1, seconds: 2)).map { $0 + $1 }), for: url)
        var song = MediaClip(
            name: "Song.wav", kind: .audio, url: url, duration: CMTime(value: 2, timescale: 1), frameRate: 24,
            colorSpace: .rec709, codecName: "PCM"
        )
        song.hasAudio = true
        project.clips.append(song)
        project.putOnMusicLayer([song.id])
        _ = project.addEffect(.audioKeys, toClip: shape.clipID, in: timelineID)
        try SnapshotSupport.render(
            EffectsPanel(
                project: .constant(project), timelineID: timelineID,
                selection: TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID),
                playheadTime: CMTime(value: 1, timescale: 2), state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
            ),
            "audio-keys-panel", size: CGSize(width: 560, height: 560)
        )
    }

    /// The graph editor on a Position keyframed in x and y, the second
    /// keyframe eased and selected and the third a hold, stepping to the
    /// fourth: the legend's chips, the zoom sliders, the toolbar's eases and
    /// the playhead inside the clip, which starts later on the timeline
    /// than its footage does.
    @Test func keyframeGraph() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let transform = project.addEffect(.transform, toClip: shape.clipID, in: timelineID)
        let transformID = try #require(transform)
        var controlID = UUID()
        project.editClip(shape.clipID, in: timelineID) { clip in
            clip.startOffset = CMTime(value: 1, timescale: 1)
            let e = clip.effects.index(of: transformID)!
            controlID = clip.effects[e].controls[0].id
            clip.effects[e].controls[0].number = AnimatedValue(ComponentValue(values: [0, 0]), keyframes: [
                Keyframe(time: .zero, value: ComponentValue(values: [0, 0])),
                Keyframe(time: CMTime(value: 2, timescale: 1), value: ComponentValue(values: [400, 60]), easeIn: .easy, easeOut: .easy),
                Keyframe(time: CMTime(value: 4, timescale: 1), value: ComponentValue(values: [200, -40]), hold: true),
                Keyframe(time: CMTime(value: 5, timescale: 1), value: ComponentValue(values: [320, 20])),
            ])
        }
        let hud = KeyframeGraphHUDs()
        hud.update(project: project)
        hud.playhead = CMTime(value: 2, timescale: 1)
        let key = ParameterKey(timelineID: timelineID, parameter: .control(.position, clipID: shape.clipID, effectID: transformID, controlID: controlID))
        try SnapshotSupport.render(
            KeyframeGraphView(hud: hud, key: key, input: GraphInput()),
            "keyframe-graph", size: CGSize(width: 620, height: 320)
        )
    }

    /// Two shapes' Position graphs linked into one panel, the second shape
    /// starting 2 s after the first: one row of presets on top for the
    /// first, each graph's row with its name and Unlink, and one time slider
    /// under both, on one shared stretch of the timeline, so their
    /// keyframes, 2 s apart in each clip, sit 2 s apart across too.
    @Test func linkedKeyframeGraphs() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        var keys: [ParameterKey] = []
        for start in [1.0, 3.0] {
            let added = project.addShapeLayer(.rectangle, to: timelineID)
            let shape = try #require(added)
            let transform = project.addEffect(.transform, toClip: shape.clipID, in: timelineID)
            let effectID = try #require(transform)
            var controlID = UUID()
            project.editClip(shape.clipID, in: timelineID) { clip in
                clip.startOffset = CMTime(seconds: start, preferredTimescale: 600)
                let e = clip.effects.index(of: effectID)!
                controlID = clip.effects[e].controls[0].id
                clip.effects[e].controls[0].number = AnimatedValue(ComponentValue(values: [0, 0]), keyframes: [
                    Keyframe(time: .zero, value: ComponentValue(values: [0, 0])),
                    Keyframe(time: CMTime(value: 2, timescale: 1), value: ComponentValue(values: [300, 80]), easeIn: .easy),
                ])
            }
            keys.append(ParameterKey(timelineID: timelineID, parameter: .control(.position, clipID: shape.clipID, effectID: effectID, controlID: controlID)))
        }
        let hud = KeyframeGraphHUDs()
        hud.update(project: project)
        hud.playhead = CMTime(value: 3, timescale: 1)
        try SnapshotSupport.render(
            KeyframeGraphStack(hud: hud, link: KeyframeGraphLink(keys), input: GraphInput()),
            "keyframe-graphs-linked", size: CGSize(width: 620, height: 600)
        )
        // One graph alone: one row, its presets ending in Link With.
        try SnapshotSupport.render(
            KeyframeGraphStack(hud: hud, link: KeyframeGraphLink([keys[0]]), input: GraphInput()),
            "keyframe-graph-single", size: CGSize(width: 620, height: 320)
        )
    }

    /// The Audio Keys editor on the same song, the playhead in its low
    /// burst: the spectrum filling the panel, the box with the level
    /// across it, and every setting as fields.
    @Test func audioKeysEditor() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let url = URL(fileURLWithPath: "/tmp/audio-keys-editor-\(UUID().uuidString).wav")
        let samples = tone(60, amplitude: 0.5, seconds: 1) + tone(2500, amplitude: 0.05, seconds: 1)
        SpectrogramStore.shared.set(Spectrogram.analyze(zip(samples, tone(400, amplitude: 0.1, seconds: 2)).map { $0 + $1 }), for: url)
        var song = MediaClip(
            name: "Song.wav", kind: .audio, url: url, duration: CMTime(value: 2, timescale: 1), frameRate: 24,
            colorSpace: .rec709, codecName: "PCM"
        )
        song.hasAudio = true
        project.clips.append(song)
        project.putOnMusicLayer([song.id])
        let effect = project.addEffect(.audioKeys, toClip: shape.clipID, in: timelineID)
        let effectID = try #require(effect)
        let hud = KeyframeGraphHUDs()
        hud.update(project: project)
        hud.playhead = CMTime(value: 1, timescale: 2)
        try SnapshotSupport.render(
            AudioKeysEditor(hud: hud, key: AudioKeysEditorKey(timelineID: timelineID, clipID: shape.clipID, effectID: effectID)),
            "audio-keys-editor", size: CGSize(width: 640, height: 460)
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
        for tab in ["viewer", "timeline", "sound", "library", "projects", "layout"] {
            UserDefaults.standard.set(tab, forKey: key)
            try SnapshotSupport.render(SettingsView(), "settings-\(tab)", size: CGSize(width: 460, height: tab == "projects" ? 560 : 420))
        }
    }

    @Test func projectSettings() throws {
        try SnapshotSupport.render(
            ProjectSettingsView(project: .empty) { _ in }, "project-settings", size: CGSize(width: 460, height: 400)
        )
    }

    /// A panel's tab bar at widths that fit its tabs at each size: they
    /// step down to small, then mini, keeping the panel's buttons in view.
    @Test func panelTabBarWidths() throws {
        for width in [400, 310, 280] {
            let bar = PanelTabBar(tabs: BrowserTab.allCases, selection: .constant(.clips), title: \.title, onClose: {}, closeHelp: "Close") {
                Button {} label: { Image(systemName: "plus") }
                    .buttonStyle(.icon)
            }
            try SnapshotSupport.render(bar.preferredColorScheme(.dark), "panel-tab-bar-\(width)", size: CGSize(width: width, height: 40))
        }
    }

    /// The Effects Library's Presets tab with the look recipes and one
    /// preset whose file can't be read, under the library's tab bar.
    @Test func presetsList() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        for recipe in LookRecipes.all.prefix(5) { try PresetStore.save(recipe.bundle, named: recipe.name, in: folder) }
        try Data("{}".utf8).write(to: folder.appending(path: "Broken.json"))
        let project = EditingProject.empty
        let library = EffectsLibrary(
            project: .constant(project), timelineID: project.rootTimelineID, selection: nil, state: EffectsPanelState(),
            tab: .constant(.presets), onClose: {}, presets: PresetsModel(folder: folder)
        )
        try SnapshotSupport.render(library.preferredColorScheme(.dark), "presets-list", size: CGSize(width: 280, height: 360))
    }

    /// The Effects Library's Effects tab: no text or shapes, which are
    /// generators, and Stroke and Text Animator under their own heading.
    @Test func effectsLibraryEffects() throws {
        let project = EditingProject.empty
        let library = EffectsLibrary(
            project: .constant(project), timelineID: project.rootTimelineID, selection: nil, state: EffectsPanelState(),
            tab: .constant(.effects), onClose: {}, presets: PresetsModel(folder: FileManager.default.temporaryDirectory.appending(path: "amv-none-\(UUID().uuidString)"))
        )
        try SnapshotSupport.render(library.preferredColorScheme(.dark), "effects-library-effects", size: CGSize(width: 280, height: 900))
    }

    /// The browser's Generators tab: text and the shapes, each making a
    /// clip of its own.
    @Test func generatorsList() throws {
        let list = GeneratorsList(onAdd: { _ in }, onAddToSelected: nil)
            .panelSurface(.base)
        try SnapshotSupport.render(list.preferredColorScheme(.dark), "generators-list", size: CGSize(width: 280, height: 320))
    }

    /// The timeline's view options, with skimming beside zoom and the
    /// areas.
    @Test func timelineViewOptions() throws {
        let popover = ViewOptionsPopover(
            zoomFraction: .constant(0.4), onFit: {}, areaLayout: .constant(TimelineAreaLayout()),
            followsPlayhead: .constant(true), beatLayers: [], beatLayerID: .constant(nil),
            clickOnBeats: .constant(false), clickFrequency: .constant(1_000), clickVolume: .constant(0.8), onPreviewClick: {}
        )
        try SnapshotSupport.render(
            popover.background(Design.Surface.floating.color).preferredColorScheme(.dark),
            "timeline-view-options", size: CGSize(width: 320, height: 430)
        )
    }

    /// Files on their way into the Clips tab: a Matroska file partway
    /// through, and one that can't tell its progress yet.
    @Test func importingClips() throws {
        let imports = MediaImports()
        let ids = imports.begin([URL(fileURLWithPath: "/Movies/Movie.mkv"), URL(fileURLWithPath: "/Movies/Interview.mov")])
        imports.update(ids[0], fraction: 0.42)
        try SnapshotSupport.render(
            VStack(alignment: .leading, spacing: 0) { ImportingClips(imports: imports) }
                .padding(10)
                .frame(width: 240, alignment: .leading)
                .background(Design.Surface.base.color)
                .preferredColorScheme(.dark),
            "importing-clips", size: CGSize(width: 240, height: 110)
        )
    }

    /// What a preset holds, as shown while the pointer rests on it: a
    /// recipe, and a stack with a renamed effect that is off.
    @Test func presetContents() throws {
        let recipe = try #require(LookRecipes.all.first { $0.name == "Infinite Tunnel" })
        var grade = Effect(kind: .color, name: "Warm")
        grade.enabled = false
        grade.controls[3].number = AnimatedValue(ComponentValue(values: [25]))
        var move = Effect(kind: .transform)
        move.controls[2].number.setAnimated(true, at: .zero)
        let url = URL(fileURLWithPath: "/dev/null")
        for (name, bundle) in [
            (recipe.name, recipe.bundle),
            ("Graded", EffectBundle(effects: [grade, move].map { EffectBundle.Effect(effect: $0) }, origin: .zero)),
        ] {
            let preset = EffectPreset(id: name, name: name, bundle: bundle, url: url)
            try SnapshotSupport.render(
                PresetContents(preset: preset).padding(20).preferredColorScheme(.dark),
                "preset-contents-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", size: CGSize(width: 300, height: 260)
            )
        }
    }

    /// The viewer while a clip is skimmed in the browser: the clip in place
    /// of the timeline, with its name and the time skimmed to.
    @Test func skimmingViewer() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-skim-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(40, 24), (200, 24)])
        let clip = MediaClip(
            name: "Interview", kind: .video, url: url, duration: CMTime(value: 2, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let skim = BrowserSkim()
        defer { skim.end() }
        skim.skim(BrowserSkim.Target(item: "clip", clip: clip, start: .zero, duration: clip.duration), at: 1.5)
        try await Task.sleep(for: .milliseconds(300))
        let viewer = ViewerPanel(
            playback: PlaybackModel(), hasContent: false, frameSize: CGSize(width: 1920, height: 1080),
            frameRate: 24, buildError: nil, trimPreview: TrimPreviewModel()
        )
        try SnapshotSupport.render(
            viewer.environment(skim).preferredColorScheme(.dark), "skimming-viewer", size: CGSize(width: 800, height: 520)
        )
    }

    /// The viewer of a timeline with no clips: what says so covers the
    /// picture, which stays under it for when clips come back.
    @Test func emptyViewer() throws {
        let viewer = ViewerPanel(
            playback: PlaybackModel(), hasContent: false, frameSize: CGSize(width: 1920, height: 1080),
            frameRate: 24, buildError: nil, trimPreview: TrimPreviewModel()
        )
        try SnapshotSupport.render(viewer.preferredColorScheme(.dark), "empty-viewer", size: CGSize(width: 800, height: 520))
    }

    /// Two shape layers, the upper clip turned off (V): faded and without
    /// colour, where it was.
    @Test func disabledClip() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let ten = CMTime(value: 10, timescale: 1)
        let below = project.addShapeLayer(.ellipse, to: t, duration: ten)
        let above = project.addShapeLayer(.rectangle, to: t, duration: ten)
        _ = try #require(below)
        let off = try #require(above)
        project.editClip(off.clipID, in: t) { $0.enabled = false }
        UserDefaults.standard.set(420.0, forKey: Preferences.timelineHeight)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.timelineHeight) }
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "disabled-clip", size: CGSize(width: 1500, height: 900))
    }

    /// Two videos with sound, the upper one's muted: its speaker badge is
    /// struck through.
    @Test func mutedClip() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        func video(_ name: String) -> MediaClip {
            MediaClip(
                name: name, kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
                frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
            )
        }
        let playing = project.importClip(video("Playing"), intoTimeline: t)
        let placed = project.importClip(video("Muted"), intoTimeline: t)
        _ = try #require(playing)
        let muted = try #require(placed)
        project.editClip(muted.clipID, in: t) { $0.soundMuted = true }
        UserDefaults.standard.set(420.0, forKey: Preferences.timelineHeight)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.timelineHeight) }
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "muted-clip", size: CGSize(width: 1500, height: 900))
    }

    /// A video retimed by a speed ramp: the speed readout along its bar,
    /// each reading and its arrow on a dark shade over the thumbnails.
    @Test func retimedClip() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let video = MediaClip(
            name: "Ramped", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = project.importClip(video, intoTimeline: t)
        let ramped = try #require(placed)
        project.editClip(ramped.clipID, in: t) { clip in
            clip.time.speed = AnimatedValue(100, keyframes: [
                Keyframe(time: CMTime(value: 2, timescale: 1), value: 100),
                Keyframe(time: CMTime(value: 5, timescale: 1), value: 250),
                Keyframe(time: CMTime(value: 7, timescale: 1), value: 50),
            ])
        }
        UserDefaults.standard.set(420.0, forKey: Preferences.timelineHeight)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.timelineHeight) }
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil
        )
        try SnapshotSupport.render(editor, "retimed-clip", size: CGSize(width: 1500, height: 900))
    }
    /// Two videos over a song, each tied to the music: a green line with a
    /// point at its foot where each is tied, the first at its first frame,
    /// the second (selected, with a knob to drag) at a frame inside it,
    /// marked on the song too with its point at the top. The playhead is
    /// yellow.
    @Test func musicPoints() throws {
        let song = try SnapshotSupport.clickSong(named: "music-points-song")
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.clips = [song]
        project.putOnMusicLayer([song.id])
        func video(_ name: String) -> MediaClip {
            MediaClip(
                name: name, kind: .video, url: nil, duration: CMTime(value: 8, timescale: 1),
                frameRate: 24, colorSpace: .rec709, codecName: "H.264"
            )
        }
        let placedFirst = project.importClip(video("Intro"), intoTimeline: t)
        let placedSecond = project.importClip(video("Chorus"), intoTimeline: t)
        let first = try #require(placedFirst)
        let second = try #require(placedSecond)
        project.moveClip(first.clipID, in: t, layer: first.layerID, to: CMTime(value: 2, timescale: 1))
        project.moveClip(second.clipID, in: t, layer: second.layerID, to: CMTime(value: 14, timescale: 1))
        project.attachToMusic(first.clipID, in: t, at: CMTime(value: 2, timescale: 1))
        project.attachToMusic(second.clipID, in: t, at: CMTime(value: 17, timescale: 1))
        UserDefaults.standard.set(420.0, forKey: Preferences.timelineHeight)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.timelineHeight) }
        let editor = EditorView(
            project: .constant(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), packageURL: nil,
            selection: TimelineSelection(timelineID: t, layerID: second.layerID, timelineClipID: second.clipID)
        )
        try SnapshotSupport.render(editor, "music-points", size: CGSize(width: 1500, height: 900))
    }
}
