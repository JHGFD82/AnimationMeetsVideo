import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A scratch directory with a fake media file and a package location.
private struct Sandbox {
    let root: URL
    let mediaURL: URL
    let packageURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amv-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mediaURL = root.appending(path: "footage.mov")
        try Data("not really video".utf8).write(to: mediaURL)
        packageURL = root.appending(path: "Test.amv", directoryHint: .isDirectory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var projectJSON: URL { packageURL.appending(path: ProjectStore.projectFileName) }

    /// What the footage looks like to the project, which saved results must name.
    var stamp: FileStamp { FileStamp(url: mediaURL)! }

    /// Stands in for `MediaImporter` so tests need no real footage.
    static let stubImporter: @Sendable (URL) async throws -> MediaClip = { url in
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return MediaClip(
            name: url.lastPathComponent,
            kind: .video,
            url: url,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24,
            colorSpace: .rec709,
            codecName: "Stub"
        )
    }

    /// A project with one asset pointing at `mediaURL` and one clip using it,
    /// trimmed to an NTSC frame boundary that has no exact decimal form.
    func makeProject() -> (project: EditingProject, clipID: UUID, assetID: UUID) {
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "footage.mov",
            kind: .video,
            url: mediaURL,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24,
            colorSpace: .rec709,
            codecName: "Stub"
        )
        let ids = project.importClip(asset, intoTimeline: project.rootTimelineID)!
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        let l = project.timelines[t].layers.firstIndex { $0.id == ids.layerID }!
        let c = project.timelines[t].layers[l].clips.firstIndex { $0.id == ids.clipID }!
        project.timelines[t].layers[l].clips[c].trimStart = CMTime(value: 1001, timescale: 24000)
        project.timelines[t].layers[l].clips[c].startOffset = CMTime(value: 2002, timescale: 24000)
        return (project, ids.clipID, asset.id)
    }
}

@Suite struct ProjectStoreTests {
    @Test func roundTripKeepsEffectStacksAndKeyframes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        let timelineID = project.rootTimelineID

        var move = Effect(kind: .transform, name: "Nudge")
        move.movesAnchor = false
        move.controls.removeAll { $0.kind == .opacity }
        move.controls[0].number = AnimatedValue(ComponentValue(values: [5, -2.5]))
        move.controls[1].number = AnimatedValue(ComponentValue(values: [50, 75]))
        move.controls[1].linked = false
        move.controls[2].number.setAnimated(true, at: .zero)
        move.controls[2].number.set(ComponentValue(values: [-30]), at: CMTime(value: 1001, timescale: 24000))
        move.controls[2].number.applyEase(.easyEase, at: CMTime(value: 1001, timescale: 24000))
        var blend = Effect(kind: .blending)
        blend.enabled = false
        blend.against = move.id
        blend.controls[0].blendMode = .softLight
        blend.controls[1].setComponent(0, to: 40, at: .zero)
        blend.controls[1].enabled = false

        var grade = Effect(kind: .color)
        grade.controls[0].number = AnimatedValue(ComponentValue(values: [0.5]))
        grade.controls[5].number = AnimatedValue(ComponentValue(values: [0.05, 0, 0.02, 0]))
        grade.controls[6].number.setAnimated(true, at: .zero)
        grade.controls[6].number.set(ComponentValue(values: [1.2, 1, 1, 0.9]), at: CMTime(value: 2, timescale: 1))
        project.editClip(clipID, in: timelineID) {
            $0.effects = [move, blend, grade]
            $0.anchorPoint.setAnimated(true, at: .zero)
            $0.anchorPoint.set(Vector2(x: 12, y: -4), at: CMTime(value: 2, timescale: 1))
            $0.volume.set(-6, at: .zero)
            $0.passThrough = true
            $0.time.speed.setAnimated(true, at: .zero)
            $0.time.speed.set(300, at: CMTime(value: 3, timescale: 1))
            $0.time.frameBlending = .blend
            $0.time.echo = Echo(count: 3, delay: CMTime(value: 1, timescale: 24), decay: 0.5)
            $0.time.sound = .mute
            $0.shutter.motionBlur = MotionBlur(angle: 90, samples: 4)
            $0.shutter.trails = Trails(count: 2, delay: CMTime(value: 2, timescale: 24), decay: 0.25)
        }

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let saved = try #require(project.clipAndLayer(clipID, in: timelineID)?.clip)
        let restored = try #require(loaded.project.clipAndLayer(clipID, in: timelineID)?.clip)
        #expect(restored.passThrough)
        #expect(restored.time == saved.time && restored.shutter == saved.shutter)
        #expect(restored.effects == saved.effects)
        #expect(restored.anchorPoint == saved.anchorPoint)
        #expect(restored.volume == saved.volume)
    }

    @Test func roundTripKeepsAnEffectsInput() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, assetID) = sandbox.makeProject()
        let timelineID = project.rootTimelineID
        var plain = Effect(kind: .matte)
        plain.input = EffectInput(source: .asset(assetID))
        var shifted = Effect(kind: .matte)
        shifted.controls[0].matteMode = .invertedAlpha
        shifted.input = EffectInput(source: .timeline(timelineID), offset: CMTime(value: 1001, timescale: 24000), loops: true)
        project.editClip(clipID, in: timelineID) { $0.effects = [plain, shifted] }

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let restored = try #require(loaded.project.clipAndLayer(clipID, in: timelineID)?.clip)
        #expect(restored.effects == [plain, shifted])
        #expect(restored.effects[0].input?.loops == false && restored.effects[0].input?.offset == .zero)
    }

    @Test func roundTripKeepsUnresolvedPasteChanges() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        let timelineID = project.rootTimelineID
        var effect = Effect(kind: .color)
        effect.pasteChanges = [
            PasteChange(kind: .inputLeftBehind, detail: "Logo matte.mov"),
            PasteChange(kind: .againstReset, detail: "Blur"),
            PasteChange(kind: .keyframesOutside, detail: "end", count: 3),
        ]
        project.editClip(clipID, in: timelineID) { $0.effects = [effect, Effect(kind: .transform)] }

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        let restored = try #require(loaded.project.clipAndLayer(clipID, in: timelineID)?.clip)
        #expect(restored.effects[0] == effect)
        #expect(restored.effects[0].pasteChanges == effect.pasteChanges)
        #expect(restored.effects[1].pasteChanges.isEmpty)
        // Resolved ones aren't written.
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(text.components(separatedBy: "pasteChanges").count == 2)
    }

    @Test func roundTripKeepsAdjustmentLayersAndTheirReach() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        let t = project.rootTimelineID
        let mediaLayer = project.timeline(id: t)!.layers[0].id
        let added = project.addAdjustmentLayer(to: t)!
        var grade = Effect(kind: .color, controls: [EffectControl(kind: .saturation)])
        grade.controls[0].number = AnimatedValue(ComponentValue(values: [40]))
        project.editClip(added.clipID, in: t) { $0.effects = [grade] }
        project.setReach(of: added.layerID, in: t, toLayer: mediaLayer)

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let json = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(json.contains("\"adjustment\" : true") && json.contains("\"reach\""))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        let layer = try #require(loaded.project.timeline(id: t)?.layer(id: added.layerID))
        #expect(layer.isAdjustment && layer.reach == mediaLayer && layer.kind == .video)
        #expect(layer.clips[0].source == .adjustment && layer.clips[0].effects == [grade])
        #expect(layer.clips[0] == project.timeline(id: t)!.layer(id: added.layerID)!.clips[0])

        // Plain layers write neither key.
        let plain = sandbox.makeProject().project
        try await ProjectStore.save(plain, to: sandbox.packageURL)
        let plainJSON = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(!plainJSON.contains("adjustment") && !plainJSON.contains("reach"))
    }

    @Test func aReachNamingNoLayerReachesEveryLayerBelow() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        let added = project.addAdjustmentLayer(to: project.rootTimelineID)!
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let edited = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
            .replacingOccurrences(of: "\"adjustment\" : true", with: "\"adjustment\" : true,\n          \"reach\" : \"\(UUID().uuidString)\"")
        try edited.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.timeline(id: project.rootTimelineID)!.layer(id: added.layerID)!.reach == nil)
    }

    @Test func plainClipsWriteNoStackAnchorOrVolume() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let json = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        for key in ["effects", "anchorPoint", "volume", "transform", "canvasMargin", "passThrough", "shutter", "\"time\" : {"] {
            #expect(!json.contains(key))
        }
    }

    @Test func defaultsAreLeftOutOfEffects() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        project.editClip(clipID, in: project.rootTimelineID) { $0.effects = [Effect(kind: .transform), Effect(kind: .blending)] }
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let json = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        for key in ["\"enabled\"", "movesAnchor", "linked", "against", "\"name\" : \"Transform"] {
            #expect(!json.contains(key))
        }
        #expect(json.contains("\"kind\" : \"transform\""))
    }

    @Test func roundTripKeepsTheCanvasMargin() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        project.canvasMargin = 1
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.canvasMargin == 1)
    }

    @Test func roundTripKeepsLayerVolume() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        let timelineID = project.rootTimelineID
        // Only Sound and Music layers have a volume of their own.
        project.timelines[0].layers[0].kind = .sound
        let layerID = try #require(project.timeline(id: timelineID)?.layers.first?.id)
        try await ProjectStore.save(project, to: sandbox.packageURL)
        #expect(!(try String(contentsOf: sandbox.projectJSON, encoding: .utf8)).contains("volume"))

        project.editVolume(of: layerID, in: timelineID) { volume in
            volume.setAnimated(true, at: .zero)
            volume.set(AudioLevel.silence, at: CMTime(value: 2, timescale: 1))
            volume.set(4.5, at: CMTime(value: 1, timescale: 1))
            volume.applyEase(.easyEase, at: CMTime(value: 1, timescale: 1))
            volume.setEase(at: .zero, in: nil, out: KeyframeEase(influence: 0.6, speed: 1.5))
        }
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let saved = try #require(project.timeline(id: timelineID)?.layers.first?.volume)
        let restored = try #require(loaded.project.timeline(id: timelineID)?.layers.first?.volume)
        #expect(restored == saved)
        #expect(restored.keyframes.count == 3)
    }

    @Test func roundTripKeepsStreamsAndTransitions() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        project.timelines[t].layers[0].clips[0].streams = .video
        project.timelines[t].layers[0].clips[0].transitionIn = ClipTransition(
            kind: .wipe, duration: CMTime(value: 1001, timescale: 24000), lead: CMTime(value: 1, timescale: 24000),
            options: TransitionOptions(direction: .up)
        )
        var curve = TransitionCurve(preset: .easyEase)
        curve.insertPoint(atTime: 0.4)
        curve.toggleCorner(1)
        project.timelines[t].layers[0].clips[0].transitionOut = ClipTransition(kind: .zoom, duration: CMTime(value: 1, timescale: 2), curve: curve)

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let saved = project.timelines[t].layers[0].clips[0]
        let clip = try #require(loaded.project.timeline(id: project.rootTimelineID)?.layers.first?.clips.first { $0.id == clipID })
        #expect(clip.streams == .video)
        #expect(clip.transitionIn == saved.transitionIn)
        #expect(clip.transitionOut == saved.transitionOut)
    }

    @Test func transitionsSavedBeforeDirectionsWereSettingsKeepTheirDirection() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        project.timelines[t].layers[0].clips[0].transitionIn = ClipTransition(kind: .wipe, duration: CMTime(value: 1, timescale: 1))
        project.timelines[t].layers[0].clips[0].transitionOut = ClipTransition(kind: .slide, duration: CMTime(value: 1, timescale: 1))
        try await ProjectStore.save(project, to: sandbox.packageURL)

        // Rewrite them as an earlier version wrote them.
        var json = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(json.contains("\"direction\" : \"right\""))
        json = json.replacingOccurrences(of: "\"direction\" : \"right\",", with: "")
        json = json.replacingOccurrences(of: "\"kind\" : \"wipe\"", with: "\"kind\" : \"wipeLeft\"")
        json = json.replacingOccurrences(of: "\"kind\" : \"slide\"", with: "\"kind\" : \"slideRight\"")
        try json.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        let clip = try #require(loaded.project.timeline(id: project.rootTimelineID)?.layers.first?.clips.first { $0.id == clipID })
        #expect(clip.transitionIn?.kind == .wipe)
        #expect(clip.transitionIn?.options.direction == .left)
        #expect(clip.transitionOut?.kind == .slide)
        #expect(clip.transitionOut?.options.direction == .right)
    }

    @Test func linkedClipsWithoutTransitionsWriteNeither() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let json = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(!json.contains("streams"))
        #expect(!json.contains("transition"))
    }

    @Test func roundTripKeepsStableIDsAndExactTimes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.missingMedia.isEmpty)
        #expect(loaded.project.id == project.id)
        #expect(loaded.project.rootTimelineID == project.rootTimelineID)
        #expect(loaded.project.clips.map(\.id) == [assetID])

        let timeline = try #require(loaded.project.timeline(id: project.rootTimelineID))
        let layer = try #require(timeline.layers.first)
        #expect(layer.id == project.timelines[0].layers[0].id)
        let clip = try #require(layer.clips.first { $0.id == clipID })
        #expect(clip.trimStart == CMTime(value: 1001, timescale: 24000))
        #expect(clip.startOffset == CMTime(value: 2002, timescale: 24000))
    }

    @Test func savingTwiceProducesIdenticalBytes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let first = try Data(contentsOf: sandbox.projectJSON)
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let second = try Data(contentsOf: sandbox.projectJSON)

        #expect(first == second)
        #expect(first.last == 0x0A)
    }

    @Test func writesTimesAsRationalStrings() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(text.contains("\"1001/24000s\""))
        #expect(text.contains("\"formatVersion\" : 2"))
    }

    @Test func roundTripKeepsLayerKinds() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        project.timelines[0].layers.append(TimelineLayer(customName: nil, kind: .music, clips: []))

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.timelines[0].layers.map(\.kind) == [.video, .music])
    }

    @Test func acceptsHandWrittenWholeSecondTimes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let edited = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
            .replacingOccurrences(of: "\"1001/24000s\"", with: "\"3s\"")
        try edited.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        let clip = try #require(loaded.project.timelines[0].layers[0].clips.first { $0.id == clipID })
        #expect(clip.trimStart == CMTime(value: 3, timescale: 1))
    }

    @Test func rejectsMalformedTime() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let edited = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
            .replacingOccurrences(of: "\"1001/24000s\"", with: "\"soon\"")
        try edited.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)

        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func rejectsNewerAndMissingFormatVersions() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let original = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        try original
            .replacingOccurrences(of: "\"formatVersion\" : 2", with: "\"formatVersion\" : 99")
            .write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }

        try original
            .replacingOccurrences(of: "\"formatVersion\" : 2,", with: "")
            .write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func rejectsFolderWithoutProjectFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.root, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func createsPackageLayoutAndIgnoreFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)

        for folder in ["Media", "Reference", "Cache", "Backups"] {
            var isDirectory: ObjCBool = false
            let path = sandbox.packageURL.appending(path: folder).path
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        let ignore = try String(contentsOf: sandbox.packageURL.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore.contains("Cache/"))
        let isPackage = try sandbox.packageURL.resourceValues(forKeys: [.isPackageKey]).isPackage
        #expect(isPackage == true)
    }

    @Test func theAppBundleDeclaresTheProjectType() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packaging/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        let declared = try #require((plist["UTExportedTypeDeclarations"] as? [[String: Any]])?.first)
        #expect(declared["UTTypeIdentifier"] as? String == ProjectStore.packageTypeIdentifier)
        #expect((declared["UTTypeConformsTo"] as? [String])?.contains("com.apple.package") == true)
        let tags = declared["UTTypeTagSpecification"] as? [String: Any]
        #expect(tags?["public.filename-extension"] as? [String] == [ProjectStore.packageExtension])
        let document = try #require((plist["CFBundleDocumentTypes"] as? [[String: Any]])?.first)
        #expect(document["LSItemContentTypes"] as? [String] == [ProjectStore.packageTypeIdentifier])
        #expect(document["LSTypeIsPackage"] as? Bool == true)
    }

    @Test func copiedMediaIsStoredWithRelativePath() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let candidates = ProjectStore.mediaToCopy(in: project, into: sandbox.packageURL)
        #expect(candidates.map(\.clipID) == [assetID])
        #expect(candidates.first?.byteCount == 16)

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])
        let copiedURL = try #require(saved.clips.first?.url)
        #expect(copiedURL.deletingLastPathComponent().lastPathComponent == "Media")
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
        #expect(FileManager.default.fileExists(atPath: sandbox.mediaURL.path))

        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(text.contains("\"Media/footage.mov\""))
        #expect(ProjectStore.mediaToCopy(in: saved, into: sandbox.packageURL).isEmpty)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.clips.first?.url?.lastPathComponent == "footage.mov")
        #expect(loaded.project.clips.first?.url?.deletingLastPathComponent().lastPathComponent == "Media")
    }

    @Test func copyingNeverOverwritesExistingMediaFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let existing = sandbox.packageURL.appending(path: "Media/footage.mov")
        try Data("other".utf8).write(to: existing)

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])

        #expect(saved.clips.first?.url?.lastPathComponent == "footage 2.mov")
        #expect(try Data(contentsOf: existing) == Data("other".utf8))
    }

    @Test func referencedMediaOutsidePackageKeepsAbsolutePath() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(text.contains(sandbox.mediaURL.path))
    }

    @Test func missingMediaIsReportedAndKeptOffline() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        try FileManager.default.removeItem(at: sandbox.mediaURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.missingMedia.count == 1)
        #expect(loaded.offlineMedia == [assetID])
        // The asset keeps what the project saved about it, and its clip stays.
        let asset = try #require(loaded.project.mediaClip(id: assetID))
        #expect(asset.kind == .video)
        #expect(asset.duration == CMTime(seconds: 10, preferredTimescale: 600))
        #expect(asset.url?.path == sandbox.mediaURL.path)
        #expect(loaded.project.timelines[0].layers.contains { $0.clips.contains { $0.id == clipID } })
    }

    @Test func savingWithMediaOfflineKeepsItsClips() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        try FileManager.default.removeItem(at: sandbox.mediaURL)

        // Opened while the file is gone, saved, then opened with it back.
        let offline = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        try await ProjectStore.save(offline.project, to: sandbox.packageURL)
        try Data("not really video".utf8).write(to: sandbox.mediaURL)
        let back = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(back.offlineMedia.isEmpty)
        #expect(back.project.mediaClip(id: assetID) != nil)
        #expect(back.project.timelines[0].layers.contains { $0.clips.contains { $0.id == clipID } })
    }

    @Test func offlineMediaInOldFilesCoversItsClips() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        // A file saved before assets recorded what they were.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.projectJSON)) as! [String: Any]
        var assets = json["assets"] as! [[String: Any]]
        for key in ["kind", "duration", "frameRate", "codec", "colorSpace", "hasAudio"] { assets[0][key] = nil }
        json["assets"] = assets
        try JSONSerialization.data(withJSONObject: json).write(to: sandbox.projectJSON)
        try FileManager.default.removeItem(at: sandbox.mediaURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let asset = try #require(loaded.project.mediaClip(id: assetID))
        // On a video layer, and long enough for the clip's trim.
        #expect(asset.kind == .video)
        let clip = try #require(loaded.project.timelines[0].layers.first?.clips.first)
        #expect(asset.duration >= clip.trimEnd)
    }

    @Test func packageURLAcceptsPackageOrProjectFile() {
        let package = URL(fileURLWithPath: "/tmp/My.amv", isDirectory: true)
        let file = package.appending(path: ProjectStore.projectFileName)
        #expect(ProjectStore.packageURL(forSelection: package) == package)
        #expect(ProjectStore.packageURL(forSelection: file).path == package.path)
    }

    @Test func backupGoesToBackupsFolderAndLeavesProjectFileAlone() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let savedBytes = try Data(contentsOf: sandbox.projectJSON)

        var edited = project
        edited.name = "Edited since save"
        let backup = try ProjectStore.writeBackup(of: edited, in: sandbox.packageURL)

        #expect(backup.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("Edited since save"))
        #expect(try Data(contentsOf: sandbox.projectJSON) == savedBytes)
    }

    @Test func backupIsALoadablePackageFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        var edited = project
        edited.name = "Recovered"
        let backup = try ProjectStore.writeBackup(of: edited, in: sandbox.packageURL)
        try FileManager.default.removeItem(at: sandbox.projectJSON)
        try FileManager.default.copyItem(at: backup, to: sandbox.projectJSON)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.name == "Recovered")
    }

    @Test func aBackupNewerThanTheSaveIsOfferedUntilSeen() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let saved = try #require(try? FileManager.default.attributesOfItem(atPath: sandbox.projectJSON.path)[.modificationDate] as? Date)
        #expect(ProjectStore.unsavedBackup(in: sandbox.packageURL) == nil)

        project.name = "Changed"
        let backup = try ProjectStore.writeBackup(of: project, in: sandbox.packageURL, now: saved.addingTimeInterval(60))
        try FileManager.default.setAttributes([.modificationDate: saved.addingTimeInterval(60)], ofItemAtPath: backup.path)
        #expect(ProjectStore.unsavedBackup(in: sandbox.packageURL) == backup)
        let restored = try await ProjectStore.load(from: sandbox.packageURL, projectFile: backup, importMedia: Sandbox.stubImporter)
        #expect(restored.project.name == "Changed")

        ProjectStore.markBackupsSeen(in: sandbox.packageURL)
        #expect(ProjectStore.unsavedBackup(in: sandbox.packageURL) == nil)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aReimportedFileFindsItsEarlierAnalysisAndCopy() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let copy = try ProjectStore.copyIntoPackage(sandbox.mediaURL, packageURL: sandbox.packageURL)
        let stamp = try #require(FileStamp(url: copy))
        let id = UUID()
        let reference = AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: copy.lastPathComponent, originalPath: copy.path, byteCount: stamp.byteCount, modified: stamp.modified,
                isVideo: true, durationValue: 10, durationTimescale: 1, frameRate: 24, width: 1920, height: 1080,
                codecName: "H.264", colorPrimaries: nil, colorTransfer: nil, colorMatrix: nil,
                audioSampleRate: nil, capturedAt: 1
            ),
            audioEnvelope: nil
        )
        try ProjectStore.writeReference(reference, for: id, in: sandbox.packageURL)

        // The copy keeps the original's size and date, so either matches.
        #expect(ProjectStore.reusableAssetID(for: sandbox.mediaURL, in: sandbox.packageURL, excluding: []) == id)
        #expect(ProjectStore.reusableAssetID(for: sandbox.mediaURL, in: sandbox.packageURL, excluding: [id]) == nil)
        #expect(ProjectStore.existingCopy(of: sandbox.mediaURL, in: sandbox.packageURL, excluding: []) == copy)
        let used = copy.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(ProjectStore.existingCopy(of: sandbox.mediaURL, in: sandbox.packageURL, excluding: [used]) == nil)
    }

    @Test func oldestBackupsArePrunedBeyondTheLimit() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        for second in 0..<5 {
            try ProjectStore.writeBackup(
                of: project,
                in: sandbox.packageURL,
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)),
                keeping: 3
            )
        }

        let folder = sandbox.packageURL.appending(path: "Backups")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 3)
        let newest = ProjectStore.backupPrefix
        #expect(names.allSatisfy { $0.hasPrefix(newest) })

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let kept = (2..<5).map { "\(newest)\(formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))).json" }
        #expect(names == kept)
    }

    @Test func applyingMediaLocationsKeepsOtherEdits() {
        var live = EditingProject.empty
        let media = MediaClip(
            name: "A", kind: .video, url: URL(fileURLWithPath: "/old/a.mov"),
            duration: .init(seconds: 1, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        live.clips = [media]
        var saved = live
        saved.clips[0].url = URL(fileURLWithPath: "/package/Media/a.mov")

        live.name = "Edited while saving"
        live.applyMediaLocations(from: saved)

        #expect(live.name == "Edited while saving")
        #expect(live.clips[0].url?.path == "/package/Media/a.mov")
    }
}

@Suite struct SceneDataPersistenceTests {
    private func sampleEdits() -> SceneEdits {
        SceneEdits(
            sensitivity: 0.7,
            regions: [SensitivityRegion(start: CMTime(value: 1001, timescale: 24000), end: CMTime(value: 5, timescale: 1), value: 0.9)],
            manualCuts: [CMTime(value: 2002, timescale: 24000)],
            ignoredCuts: [CMTime(value: 3, timescale: 1)]
        )
    }

    @Test func sceneEditsAndDefaultSensitivityRoundTrip() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.defaultSensitivity = 0.35
        let edits = sampleEdits()
        project.clips[0].sceneEdits = edits

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.project.defaultSensitivity == 0.35)
        #expect(loaded.project.mediaClip(id: assetID)?.sceneEdits == edits)
    }

    @Test func untouchedProjectsWriteNoSceneFields() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(!text.contains("sceneEdits"))
        #expect(!text.contains("defaultSensitivity"))
    }

    @Test func projectFilesFromBeforeSceneDetectionStillLoad() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.project.defaultSensitivity == SceneDetector.balancedSensitivity)
        #expect(loaded.project.mediaClip(id: assetID)?.sceneEdits == SceneEdits())
        #expect(loaded.changeScores.isEmpty)
    }

    @Test func changeScoresAreSavedInReferenceAndLoadedBack() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25, 50], scores: [0, 200, 3])

        try await ProjectStore.save(
            project, to: sandbox.packageURL, changeScores: [assetID: track],
            sources: AnalysisSources(scores: [assetID: sandbox.stamp])
        )

        let file = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: ProjectStore.changeScoreFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changeScores[assetID] == track)
    }

    @Test func scoresForUnknownAssetsAreNotWritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        let stray = UUID()

        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [stray: ChangeScoreTrack(timescale: 600, times: [0], scores: [0])]
        )

        let folder = ProjectStore.referenceFolder(for: stray, in: sandbox.packageURL)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aDamagedScoreFileJustMeansNotAnalyzed() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 9])
        try await ProjectStore.save(project, to: sandbox.packageURL, changeScores: [assetID: track])
        let file = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: ProjectStore.changeScoreFileName)
        try Data("garbage".utf8).write(to: file)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.changeScores[assetID] == nil)
        #expect(loaded.project.clips.count == 1)
    }
}

@Suite struct ReferenceDataPersistenceTests {
    private func sampleReference() -> AssetReference {
        AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "footage.mov", originalPath: "/Volumes/Footage/footage.mov", byteCount: 1234, modified: 1_700_000_000.5,
                isVideo: true, durationValue: 10010, durationTimescale: 1000, frameRate: 29.97, width: 3840, height: 2160,
                codecName: "HEVC", colorPrimaries: "ITU_R_2020", colorTransfer: "SMPTE_ST_2084_PQ", colorMatrix: "ITU_R_2020",
                audioSampleRate: 48000, capturedAt: 1_700_000_100
            ),
            audioEnvelope: AudioEnvelope(startWindow: 0, levels: [0, 40, 200, 255])
        )
    }

    @Test func referenceRoundTripsThroughThePackage() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let reference = sampleReference()

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference])
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID] == reference)
    }

    @Test func aFileWithoutAudioWritesNoEnvelope() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        var reference = sampleReference()
        reference.audioEnvelope = nil

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference])

        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ProjectStore.audioEnvelopeFileName).path))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.references[assetID] == reference)
    }

    @Test func aDamagedEnvelopeIsDroppedButTheSnapshotSurvives() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: sampleReference()])
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        try Data("garbage".utf8).write(to: folder.appending(path: ProjectStore.audioEnvelopeFileName))

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID]?.metadata == sampleReference().metadata)
        #expect(loaded.references[assetID]?.audioEnvelope == nil)
    }

    @Test func aDamagedSnapshotMeansNoReference() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: sampleReference()])
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        try Data("{".utf8).write(to: folder.appending(path: ProjectStore.referenceMetadataFileName))

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID] == nil)
    }

    @Test func referencesForUnknownAssetsAreNotWritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        let stray = UUID()

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [stray: sampleReference()])

        #expect(!FileManager.default.fileExists(atPath: ProjectStore.referenceFolder(for: stray, in: sandbox.packageURL).path))
    }
}

@Suite struct ReferenceThumbnailPersistenceTests {
    private func sample() -> ReferenceThumbnails {
        ReferenceThumbnails(frames: [
            ReferenceFrame(time: CMTime(value: 0, timescale: 600), jpeg: Data([1, 2, 3])),
            ReferenceFrame(time: CMTime(value: 1001, timescale: 24000), jpeg: Data([4, 5])),
            ReferenceFrame(time: CMTime(value: 7, timescale: 1), jpeg: Data([6])),
        ])
    }

    @Test func picturesRoundTripInTimeOrder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])

        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.assetsWithThumbnails == [assetID])
    }

    @Test func aLeftoverPartialFolderCountsAsNotCaptured() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let partial = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: "thumbs.partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1]).write(to: partial.appending(path: "0_600.jpg"))

        #expect(!ProjectStore.hasThumbnails(for: assetID, in: sandbox.packageURL))
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])
        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
    }

    @Test func savedPicturesAreNeverOverwritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])

        let other = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([9]))])
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: other])

        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
    }

    @Test func fileNamesCarryTheExactTime() {
        let time = CMTime(value: 1001, timescale: 24000)
        #expect(ProjectStore.thumbnailFileName(for: time) == "1001_24000.jpg")
        #expect(ProjectStore.thumbnailTime(fromFileName: "1001_24000.jpg") == time)
        #expect(ProjectStore.thumbnailTime(fromFileName: "notes.txt") == nil)
        #expect(ProjectStore.thumbnailTime(fromFileName: "1_0.jpg") == nil)
    }
}

@Suite struct MediaReplacementPersistenceTests {
    @Test func alignmentAndPreviousPathsRoundTrip() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.clips[0].alignmentOffset = CMTime(value: -1001, timescale: 24000)
        project.clips[0].previousPaths = ["/Volumes/Cards/proxy.mov", "Media/older.mov"]

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let clip = try #require(loaded.project.mediaClip(id: assetID))
        #expect(clip.alignmentOffset == CMTime(value: -1001, timescale: 24000))
        #expect(clip.previousPaths == ["/Volumes/Cards/proxy.mov", "Media/older.mov"])
    }

    @Test func untouchedAssetsWriteNoReplacementFields() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(!text.contains("alignmentOffset"))
        #expect(!text.contains("previousPaths"))
    }

    @Test func aSwappedFileIsReportedOnLoad() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.clips[0].acceptedStamp = FileStamp(url: sandbox.mediaURL)
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let unchanged = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(unchanged.changedMedia.isEmpty)

        try Data("a different, longer file".utf8).write(to: sandbox.mediaURL)
        let changed = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(changed.changedMedia == [assetID])
    }

    @Test func projectsWithoutAStampAreNotReportedAsChanged() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.changedMedia.isEmpty)
        #expect(loaded.project.clips[0].acceptedStamp != nil)
    }

    @Test func copyingIntoThePackageStampsTheCopy() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])
        let copy = try #require(saved.mediaClip(id: assetID)?.url)

        #expect(saved.mediaClip(id: assetID)?.acceptedStamp == FileStamp(url: copy))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changedMedia.isEmpty)
    }

    @Test func copyOnImportIsOmittedWhileOnAndRoundTripsWhenOff() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        #expect(!(try String(contentsOf: sandbox.projectJSON, encoding: .utf8)).contains("copiesMediaOnImport"))
        #expect(try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter).project.copiesMediaOnImport)

        project.copiesMediaOnImport = false
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(!loaded.project.copiesMediaOnImport)
    }

    @Test func importCopiesLandInMediaWithoutOverwriting() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try ProjectStore.preparePackage(at: sandbox.packageURL)

        let first = try ProjectStore.copyIntoPackage(sandbox.mediaURL, packageURL: sandbox.packageURL)
        let second = try ProjectStore.copyIntoPackage(sandbox.mediaURL, packageURL: sandbox.packageURL)

        #expect(first.deletingLastPathComponent().lastPathComponent == "Media")
        #expect(first.lastPathComponent == "footage.mov")
        #expect(second.lastPathComponent == "footage 2.mov")
        #expect(try ProjectStore.copyIntoPackage(first, packageURL: sandbox.packageURL) == first)
        #expect(FileManager.default.fileExists(atPath: sandbox.mediaURL.path))
    }

    @Test func saveAsCopiesOnlyMediaFromThePreviousPackage() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let inside = try ProjectStore.copyIntoPackage(sandbox.mediaURL, packageURL: sandbox.packageURL)
        var other = project.clips[0]
        other.id = UUID()
        project.addMedia(other)
        project.clips[0].url = inside

        let newPackage = sandbox.root.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: newPackage)
        let candidates = ProjectStore.mediaToCopy(in: project, into: newPackage, from: sandbox.packageURL)

        #expect(candidates.map(\.clipID) == [assetID])
    }
}

@Suite struct ForgetOriginalTests {
    private func reference() -> AssetReference {
        AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "footage.mov", originalPath: "/tmp/footage.mov", byteCount: 1, modified: 1,
                isVideo: true, durationValue: 10, durationTimescale: 1, frameRate: 24, width: 1920, height: 1080,
                codecName: "H.264", colorPrimaries: nil, colorTransfer: nil, colorMatrix: nil,
                audioSampleRate: 48000, capturedAt: 1
            ),
            audioEnvelope: AudioEnvelope(startWindow: 0, levels: [1, 2, 3])
        )
    }

    @Test func theFlagSurvivesSaveAndLoadAndIsOmittedWhenFalse() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(!text.contains("referenceForgotten"))

        project.markReferenceForgotten(forAsset: assetID)
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.mediaClip(id: assetID)?.referenceForgotten == true)
    }

    @Test func forgettingDeletesTheReferenceButKeepsTheScores() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [assetID: track], references: [assetID: reference()],
            sources: AnalysisSources(scores: [assetID: sandbox.stamp])
        )
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        let thumbs = folder.appending(path: ProjectStore.thumbnailFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try Data([1]).write(to: thumbs.appending(path: "0.jpg"))

        try ProjectStore.forgetReference(for: assetID, in: sandbox.packageURL)

        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: folder.appending(path: ProjectStore.referenceMetadataFileName).path))
        #expect(!fileManager.fileExists(atPath: folder.appending(path: ProjectStore.audioEnvelopeFileName).path))
        #expect(!fileManager.fileExists(atPath: thumbs.path))
        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == nil)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changeScores[assetID] == track)
    }

    @Test func savingAForgottenOriginalDeletesItsDataAndWritesNoNewData() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])
        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) != nil)

        project.markReferenceForgotten(forAsset: assetID)
        let pictures = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([1]))])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            references: [assetID: reference()], thumbnails: [assetID: pictures]
        )

        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == nil)
        #expect(!ProjectStore.hasThumbnails(for: assetID, in: sandbox.packageURL))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.references[assetID] == nil)
    }

    @Test func saveAsCarriesTheSavedReferenceDataToTheNewPackage() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])
        let pictures = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([1]))])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [assetID: track], references: [assetID: reference()], thumbnails: [assetID: pictures]
        )

        let copy = sandbox.root.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(project, to: copy, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: copy) == reference())
        #expect(ProjectStore.readChangeScores(for: assetID, in: copy) == track)
        #expect(ProjectStore.readThumbnails(for: assetID, in: copy) == pictures)
    }

    @Test func saveAsLeavesAForgottenOriginalBehind() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])

        project.markReferenceForgotten(forAsset: assetID)
        let copy = sandbox.root.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(project, to: copy, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: copy) == nil)
    }

    @Test func savingInPlaceWithItselfAsThePreviousPackageChangesNothing() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])

        try await ProjectStore.save(project, to: sandbox.packageURL, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == reference())
    }

    @Test func forgettingWhenNothingWasSavedIsHarmless() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try ProjectStore.forgetReference(for: UUID(), in: sandbox.packageURL)
    }
}

@Suite struct StrictLoadingTests {
    /// Saves a project whose first clip holds a Transform and a Blending
    /// effect and a way in, then lets `edit` change the JSON that was
    /// written, and returns what loading it says.
    private func loadingMessage(edit: (inout [String: Any]) -> Void) async throws -> String {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, clipID, _) = sandbox.makeProject()
        var move = Effect(kind: .transform)
        move.controls[0].number = AnimatedValue(ComponentValue(values: [5, 0]))
        var blend = Effect(kind: .blending)
        blend.controls[0].blendMode = .multiply
        project.editClip(clipID, in: project.rootTimelineID) {
            $0.effects = [move, blend]
            $0.transitionIn = ClipTransition(kind: .crossDissolve, duration: CMTime(value: 1, timescale: 1))
        }
        try await ProjectStore.save(project, to: sandbox.packageURL)

        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.projectJSON)) as? [String: Any])
        edit(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: sandbox.projectJSON)
        do {
            _ = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
            return "loaded"
        } catch {
            return error.localizedDescription
        }
    }

    /// Changes the clip at timelines[0].layers[0].clips[0].
    private func editClip(_ json: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var timelines = json["timelines"] as! [[String: Any]]
        var layers = timelines[0]["layers"] as! [[String: Any]]
        var clips = layers[0]["clips"] as! [[String: Any]]
        change(&clips[0])
        layers[0]["clips"] = clips
        timelines[0]["layers"] = layers
        json["timelines"] = timelines
    }

    private func editEffect(_ json: inout [String: Any], _ index: Int, _ change: (inout [String: Any]) -> Void) {
        editClip(&json) { clip in
            var effects = clip["effects"] as! [[String: Any]]
            change(&effects[index])
            clip["effects"] = effects
        }
    }

    @Test func anInputOnAnEffectThatTakesNoneIsAnUnknownKey() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { $0["input"] = ["asset": UUID().uuidString] }
        }
        #expect(message == "The project can't be opened. Unknown key \"input\" at timelines[0].layers[0].clips[0].effects[0].")
    }

    @Test func anUnknownPasteChangeKindIsRejected() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { $0["pasteChanges"] = [["kind": "teleported", "detail": "x"]] }
        }
        #expect(message == "The project can't be opened. Unknown paste change \"teleported\" at timelines[0].layers[0].clips[0].effects[0].pasteChanges[0].kind.")
    }

    @Test func aMatteInputNamingNothingIsRejected() async throws {
        let message = try await loadingMessage { json in
            editClip(&json) { clip in
                let matte: [String: Any] = [
                    "id": UUID().uuidString, "kind": "matte", "input": ["loops": true],
                    "controls": [["id": UUID().uuidString, "kind": "matteMode", "value": "luma"]],
                ]
                clip["effects"] = [matte]
            }
        }
        #expect(message.hasPrefix("The project can't be opened."))
        #expect(message.contains("effects[0].input"))
    }

    @Test func aLayerTransformIsAnUnknownKey() async throws {
        let message = try await loadingMessage { json in
            var timelines = json["timelines"] as! [[String: Any]]
            var layers = timelines[0]["layers"] as! [[String: Any]]
            layers[0]["transform"] = ["opacity": ["value": 50]]
            timelines[0]["layers"] = layers
            json["timelines"] = timelines
        }
        #expect(message == "The project can't be opened. Unknown key \"transform\" at timelines[0].layers[0].")
    }

    @Test func anUnknownEffectKindNamesItsPath() async throws {
        let message = try await loadingMessage { editEffect(&$0, 1) { $0["kind"] = "glow" } }
        #expect(message == "The project can't be opened. Unknown effect kind \"glow\" at timelines[0].layers[0].clips[0].effects[1].kind.")
    }

    @Test func anUnknownBlendModeIsRejected() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 1) { effect in
                var controls = effect["controls"] as! [[String: Any]]
                controls[0]["value"] = "sparkle"
                effect["controls"] = controls
            }
        }
        #expect(message == "The project can't be opened. Unknown blend mode \"sparkle\" at timelines[0].layers[0].clips[0].effects[1].controls[0].value.")
    }

    @Test func aControlOfAnotherEffectIsAnUnknownControl() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { effect in
                var controls = effect["controls"] as! [[String: Any]]
                controls[1]["kind"] = "mode"
                effect["controls"] = controls
            }
        }
        #expect(message == "The project can't be opened. Unknown control kind \"mode\" at timelines[0].layers[0].clips[0].effects[0].controls[1].kind.")
    }

    @Test func aValueOfTheWrongTypeIsRejected() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { effect in
                var controls = effect["controls"] as! [[String: Any]]
                controls[0]["value"] = "far"
                effect["controls"] = controls
            }
        }
        #expect(message == "The project can't be opened. Expected a list of 2 numbers at timelines[0].layers[0].clips[0].effects[0].controls[0].value.")
    }

    @Test func aMissingRequiredFieldIsNamed() async throws {
        let message = try await loadingMessage { editClip(&$0) { $0["id"] = nil } }
        #expect(message == "The project can't be opened. Missing \"id\" at timelines[0].layers[0].clips[0].")
    }

    @Test func aColorControlWithTheWrongNumberOfChannelsIsRejected() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { effect in
                effect["kind"] = "color"
                effect["controls"] = [["id": UUID().uuidString, "kind": "lift", "value": [0.1, 0.2]]]
            }
        }
        #expect(message == "The project can't be opened. Expected a list of 4 numbers at timelines[0].layers[0].clips[0].effects[0].controls[0].value.")
    }

    @Test func anUnknownFrameBlendingIsRejected() async throws {
        let message = try await loadingMessage { json in
            editClip(&json) { $0["time"] = ["frameBlending": "smear"] }
        }
        #expect(message == "The project can't be opened. Unknown frame blending \"smear\" at timelines[0].layers[0].clips[0].time.frameBlending.")
    }

    @Test func aMotionBlurWithoutItsSamplesIsRejected() async throws {
        let message = try await loadingMessage { json in
            editClip(&json) { $0["shutter"] = ["motionBlur": ["angle": 180]] }
        }
        #expect(message == "The project can't be opened. Missing \"samples\" at timelines[0].layers[0].clips[0].shutter.motionBlur.")
    }

    @Test func aControlNeedsAValueOrKeyframes() async throws {
        let message = try await loadingMessage { json in
            editEffect(&json, 0) { effect in
                var controls = effect["controls"] as! [[String: Any]]
                controls[0]["value"] = nil
                effect["controls"] = controls
            }
        }
        #expect(message == "The project can't be opened. Missing \"value\" or \"keyframes\" at timelines[0].layers[0].clips[0].effects[0].controls[0].")
    }

    @Test func anUnknownTransitionKindIsRejectedNotDropped() async throws {
        let message = try await loadingMessage { json in
            editClip(&json) { clip in
                var transition = clip["transitionIn"] as! [String: Any]
                transition["kind"] = "swirl"
                clip["transitionIn"] = transition
            }
        }
        #expect(message == "The project can't be opened. Unknown transition kind \"swirl\" at timelines[0].layers[0].clips[0].transitionIn.kind.")
    }

    @Test func aMalformedTimeIsRejectedWithItsPath() async throws {
        let message = try await loadingMessage { editClip(&$0) { $0["trimStart"] = "soon" } }
        #expect(message.hasPrefix("The project can't be opened. \"soon\" isn't a valid time"))
        #expect(message.hasSuffix("at timelines[0].layers[0].clips[0].trimStart."))
    }

    @Test func anUnknownKeyAtTheTopIsReportedThere() async throws {
        let message = try await loadingMessage { $0["glow"] = true }
        #expect(message == "The project can't be opened. Unknown key \"glow\" at the top level of the file.")
    }

    @Test func version1ProjectsAreNotOpened() async throws {
        let message = try await loadingMessage { $0["formatVersion"] = 1 }
        #expect(message == "This project uses format version 1, which this version of the app can't open.")
    }

    @Test func aFileWithoutProblemsLoads() async throws {
        #expect(try await loadingMessage { _ in } == "loaded")
    }
}
