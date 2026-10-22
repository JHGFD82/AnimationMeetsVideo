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
        // stretch after it and selected: its two ramp handles, the ramp in
        // reaching further than the ramp out, and the sidebar's sliders.
        let easedRun: MotionRun = {
            var copy = run
            let quick = copy.addMarker(toPiece: first.id, atSource: seconds(1.5))!
            copy.movePoint(quick, to: seconds(3.4))
            copy.setEased(true, ofPoint: slow)
            copy.setEase(TimeEase(before: 0.6, after: 0.4), ofPoint: slow)
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
    }

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
    /// fourth: the legend's chips, the zoom dials, the toolbar's eases and
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

    /// The browser's Presets tab with the look recipes and one preset whose
    /// file can't be read.
    @Test func presetsList() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-snapshot-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        for recipe in LookRecipes.all.prefix(5) { try PresetStore.save(recipe.bundle, named: recipe.name, in: folder) }
        try Data("{}".utf8).write(to: folder.appending(path: "Broken.json"))
        let list = PresetsList(model: PresetsModel(folder: folder), onApply: { _ in })
        try SnapshotSupport.render(list.preferredColorScheme(.dark), "presets-list", size: CGSize(width: 280, height: 360))
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
}
