import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// A project with two video clips on separate layers: the first 10 s of its
/// footage starting at 2 s, the second 4 s starting at 0.
private struct PasteFixture {
    var project = EditingProject.empty
    let timelineID: UUID
    let source: UUID
    let target: UUID

    init() {
        let media = MediaClip(name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let other = MediaClip(name: "B.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let first = project.importClip(media, intoTimeline: project.rootTimelineID)!
        let second = project.importClip(other, intoTimeline: project.rootTimelineID)!
        timelineID = project.rootTimelineID
        source = first.clipID
        target = second.clipID
        project.editClip(source, in: timelineID) { $0.trimStart = Pasting.second(2); $0.trimEnd = Pasting.second(12) }
        project.editClip(target, in: timelineID) { $0.trimStart = Pasting.second(5); $0.trimEnd = Pasting.second(9) }
    }

    func stack(_ clip: UUID) -> [Effect] { project.clipAndLayer(clip, in: timelineID)!.clip.effects }
}

private enum Pasting {
    static func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }
}

@Suite struct EffectPastingTests {
    @Test func pastingGivesNewIDsAndKeepsTheControlsValues() throws {
        var f = PasteFixture()
        var move = Effect(kind: .transform)
        move.controls[0].number = AnimatedValue(ComponentValue(values: [7, -3]))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [move] }

        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        let ids = f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        #expect(ids.count == 1 && ids[0] != move.id)
        let pasted = try #require(f.stack(f.target).first)
        #expect(pasted.controls[0].number.value == ComponentValue(values: [7, -3]))
        #expect(pasted.controls.map(\.id).allSatisfy { id in !move.controls.contains { $0.id == id } })
        #expect(pasted.pasteChanges.isEmpty)
        // The original is untouched.
        #expect(f.stack(f.source) == [move])
    }

    @Test func pastingGoesBelowTheGivenPlaceOrAtTheEnd() throws {
        var f = PasteFixture()
        let a = Effect(kind: .color), b = Effect(kind: .blending)
        f.project.editClip(f.target, in: f.timelineID) { $0.effects = [a, b] }
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [Effect(kind: .transform)] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID, at: 1)
        #expect(f.stack(f.target).map(\.kind) == [.color, .transform, .blending])
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        #expect(f.stack(f.target).map(\.kind) == [.color, .transform, .blending, .transform])
        // The two Transforms are numbered apart.
        let names = f.stack(f.target).filter { $0.kind == .transform }.map(\.displayName)
        #expect(names == ["Transform", "Transform 2"])
    }

    @Test func pasteEffectsOnAClipReplacesItsWholeStack() throws {
        var f = PasteFixture()
        f.project.editClip(f.target, in: f.timelineID) { $0.effects = [Effect(kind: .color), Effect(kind: .color)] }
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [Effect(kind: .blending)] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID, replacingStack: true)
        #expect(f.stack(f.target).map(\.kind) == [.blending])
    }

    @Test func pasteEffectsAddsToTheStackAndReplacesTimeAndShutterWhenDifferent() throws {
        var f = PasteFixture()
        f.project.editClip(f.target, in: f.timelineID) { $0.effects = [Effect(kind: .color)] }
        f.project.editClip(f.source, in: f.timelineID) {
            $0.effects = [Effect(kind: .blending)]
            $0.time.frameBlending = .blend
            $0.shutter.motionBlur = MotionBlur()
        }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        let source = try #require(f.project.clipAndLayer(f.source, in: f.timelineID)?.clip)
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        f.project.pasteTimeAndShutter(of: source, ontoClip: f.target, in: f.timelineID)

        let target = try #require(f.project.clipAndLayer(f.target, in: f.timelineID)?.clip)
        // Added, not replaced.
        #expect(target.effects.map(\.kind) == [.color, .blending])
        // Time and shutter taken from the copied clip.
        #expect(target.time.frameBlending == .blend)
        #expect(target.shutter.motionBlur != nil)
    }

    @Test func aNameThePersonChoseSurvives() throws {
        var f = PasteFixture()
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [Effect(kind: .color, name: "Warm look")] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        #expect(f.stack(f.target).map(\.displayName) == ["Warm look"])
    }

    @Test func keyframesLandTheSameDistanceFromTheStartOfTheClip() throws {
        var f = PasteFixture()
        var move = Effect(kind: .transform)
        // One second and three seconds into the source clip (which starts at 2 s).
        move.controls[2].number.setAnimated(true, at: second(3))
        move.controls[2].number.set(ComponentValue(values: [90]), at: second(5))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [move] }

        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        let pasted = try #require(f.stack(f.target).first)
        // The target starts at 5 s, so they're at 6 s and 8 s.
        #expect(pasted.controls[2].number.keyframes.map(\.time) == [second(6), second(8)])
        #expect(pasted.pasteChanges.isEmpty)
    }

    @Test func keyframesThatFallOutsideTheClipAreFlagged() throws {
        var f = PasteFixture()
        var move = Effect(kind: .transform)
        // The target is four seconds long; these are 1, 6 and 8 s into the source.
        move.controls[2].number.setAnimated(true, at: second(3))
        move.controls[2].number.set(ComponentValue(values: [45]), at: second(8))
        move.controls[2].number.set(ComponentValue(values: [90]), at: second(10))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [move] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        let changes = try #require(f.stack(f.target).first?.pasteChanges)
        #expect(changes == [PasteChange(kind: .keyframesOutside, detail: "end", count: 2)])
        #expect(changes[0].message == "2 keyframes fall past the end of this clip.")
    }

    @Test func aMatteLeavesItsInputBehindAndSaysWhat() throws {
        var f = PasteFixture()
        let media = MediaClip(name: "Logo matte.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: second(4), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        f.project.addMedia(media)
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .asset(media.id))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [matte] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        let pasted = try #require(f.stack(f.target).first)
        #expect(pasted.input == nil)
        #expect(pasted.pasteChanges.map(\.message) == ["Input left behind (was Logo matte.mov)."])
    }

    @Test func againstFollowsTheEffectItReadWhenItCameAlong() throws {
        var f = PasteFixture()
        let grade = Effect(kind: .color)
        var blend = Effect(kind: .blending)
        blend.against = grade.id
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [grade, blend] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        let stack = f.stack(f.target)
        #expect(stack[1].against == stack[0].id)
        #expect(stack[1].pasteChanges.isEmpty)
    }

    @Test func againstGoesBackToTheBackdropWhenItDidntComeAlong() throws {
        var f = PasteFixture()
        let blur = Effect(kind: .color, name: "Blur")
        var blend = Effect(kind: .blending)
        blend.against = blur.id
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [blur, blend] }
        let bundle = try #require(f.project.bundle(ofEffects: [blend.id], fromClip: f.source, in: f.timelineID))
        f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        let pasted = try #require(f.stack(f.target).first)
        #expect(pasted.against == nil)
        #expect(pasted.pasteChanges.map(\.message) == ["Against reset to Backdrop: Before Blur wasn't pasted."])
    }

    @Test func anEffectWithNoStackToGoInIsRefused() throws {
        var f = PasteFixture()
        let sound = MediaClip(name: "S.wav", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: second(4), frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true)
        let imported = f.project.importClip(sound, intoTimeline: f.project.rootTimelineID)
        let placed = try #require(imported)
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [Effect(kind: .color)] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        let pastedIDs = f.project.paste(bundle, ontoClip: placed.clipID, in: f.timelineID)
        #expect(pastedIDs.isEmpty)
    }
}

@Suite struct PasteChangeResolutionTests {
    private func flagged() throws -> (PasteFixture, UUID) {
        var f = PasteFixture()
        let media = MediaClip(name: "M.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: second(4), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        f.project.addMedia(media)
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .asset(media.id))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [matte] }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID))
        let ids = f.project.paste(bundle, ontoClip: f.target, in: f.timelineID)
        return (f, ids[0])
    }

    @Test func unresolvedChangesAreListedWithWhereTheyAre() throws {
        let (f, effectID) = try flagged()
        let entries = f.project.unresolvedPasteChanges()
        #expect(entries.count == 1)
        #expect(entries[0].effectID == effectID && entries[0].clipID == f.target && entries[0].timelineID == f.timelineID)
        #expect(entries[0].clipName == "B.mov" && entries[0].effectName == "Matte")
        let clip = try #require(f.project.clipAndLayer(f.target, in: f.timelineID)?.clip)
        #expect(f.project.hasUnresolvedPasteChanges(clip))
    }

    @Test func markingOneResolvedRemovesOnlyIt() throws {
        var (f, effectID) = try flagged()
        // A second change on the same effect.
        f.project.editEffect(effectID, ofClip: f.target, in: f.timelineID) {
            $0.pasteChanges.append(PasteChange(kind: .keyframesOutside, detail: "end", count: 1))
        }
        let first = try #require(f.project.unresolvedPasteChanges().first)
        f.project.resolvePasteChange(first.change, ofEffect: effectID, onClip: f.target, in: f.timelineID)
        #expect(f.project.unresolvedPasteChanges().map(\.change.kind) == [.keyframesOutside])
    }

    @Test func acceptAllResolvesEverything() throws {
        var (f, _) = try flagged()
        f.project.resolve(f.project.unresolvedPasteChanges())
        #expect(f.project.unresolvedPasteChanges().isEmpty)
    }

    @Test func anExportCountsTheTimelinesItDrawsAndNoOthers() throws {
        var (f, _) = try flagged()
        // The flagged clip is in the root. A timeline nothing uses has one too.
        let lonely = f.project.addTimeline(name: "Lonely", frameSize: CGSize(width: 64, height: 36), frameRate: 24, colorSpace: .rec709)
        let media = MediaClip(name: "L.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: second(4), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let imported = f.project.importClip(media, intoTimeline: lonely)
        let placed = try #require(imported)
        f.project.editClip(placed.clipID, in: lonely) {
            var effect = Effect(kind: .color)
            effect.pasteChanges = [PasteChange(kind: .keyframesOutside, detail: "end", count: 1)]
            $0.effects = [effect]
        }
        #expect(f.project.unresolvedPasteChanges(drawnBy: f.timelineID).count == 1)
        #expect(f.project.unresolvedPasteChanges().count == 2)
        // Once the root nests it, an export of the root draws it.
        f.project.embedTimeline(lonely, intoTimeline: f.timelineID)
        #expect(f.project.unresolvedPasteChanges(drawnBy: f.timelineID).count == 2)
    }
}

@Suite struct PresetStoreTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundle() throws -> (EffectBundle, PasteFixture) {
        var f = PasteFixture()
        var grade = Effect(kind: .color, name: "Warm")
        grade.controls[3].number = AnimatedValue(ComponentValue(values: [25]))
        var move = Effect(kind: .transform)
        move.controls[2].number.setAnimated(true, at: second(3))
        move.controls[2].number.set(ComponentValue(values: [90]), at: second(5))
        var blend = Effect(kind: .blending)
        blend.against = grade.id
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .asset(UUID()))
        f.project.editClip(f.source, in: f.timelineID) { $0.effects = [grade, move, blend, matte] }
        return (try #require(f.project.bundle(ofEffects: nil, fromClip: f.source, in: f.timelineID)), f)
    }

    @Test func aSavedPresetLoadsBackWithTimesFromTheStartOfItsClip() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _) = try bundle()
        let saved = try PresetStore.save(bundle, named: "Warm grade", in: dir)
        #expect(saved.url.lastPathComponent == "Warm grade.json")

        let library = PresetStore.load(from: dir)
        #expect(library.problems.isEmpty)
        let loaded = try #require(library.presets.first)
        #expect(loaded.name == "Warm grade" && loaded.bundle.origin == .zero)
        // The source clip starts at 2 s, so 3 s and 5 s are 1 s and 3 s in.
        #expect(loaded.bundle.effects[1].effect.controls[2].number.keyframes.map(\.time) == [second(1), second(3)])
        #expect(loaded.bundle.effects.map(\.effect.kind) == [.color, .transform, .blending, .matte])
        #expect(loaded.bundle.effects[0].effect.controls[3].number.value == ComponentValue(values: [25]))
        #expect(loaded.bundle.effects[3].inputName == "missing media")
        #expect(loaded.bundle.effects[3].effect.input == nil)
    }

    @Test func applyingAPresetPutsItsEffectsOnAClipWithWhatWasLeftBehind() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, fixture) = try bundle()
        var f = fixture
        try PresetStore.save(bundle, named: "Look", in: dir)
        let preset = try #require(PresetStore.load(from: dir).presets.first)
        f.project.paste(preset.bundle, ontoClip: f.target, in: f.timelineID)
        let stack = f.stack(f.target)
        #expect(stack.map(\.kind) == [.color, .transform, .blending, .matte])
        // The target starts at 5 s: the 1 s and 3 s keyframes are at 6 s and 8 s.
        #expect(stack[1].controls[2].number.keyframes.map(\.time) == [second(6), second(8)])
        // Against kept following the effect it read, which came along.
        #expect(stack[2].against == stack[0].id)
        #expect(stack[3].pasteChanges.map(\.kind) == [.inputLeftBehind])
    }

    @Test func aPresetNeedsOnlyItsFileAndTheSameNameGetsANumber() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _) = try bundle()
        let a = try PresetStore.save(bundle, named: "Look", in: dir)
        let b = try PresetStore.save(bundle, named: "Look", in: dir)
        #expect(a.id == "Look" && b.id == "Look 2")
        let c = try PresetStore.save(bundle, named: "a/b: c", in: dir)
        #expect(c.url.lastPathComponent == "a-b- c.json")
    }

    @Test func renamingKeepsTheEffectsAndMovesTheFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _) = try bundle()
        let saved = try PresetStore.save(bundle, named: "Old", in: dir)
        let renamed = try PresetStore.rename(saved, to: "New", in: dir)
        #expect(renamed.name == "New" && renamed.bundle == saved.bundle)
        let library = PresetStore.load(from: dir)
        #expect(library.presets.map(\.name) == ["New"])
        #expect(!FileManager.default.fileExists(atPath: saved.url.path))
        try PresetStore.delete(renamed)
        #expect(PresetStore.load(from: dir).presets.isEmpty)
    }

    @Test func aPresetThatCantBeReadIsReportedAndNothingElseIsStopped() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _) = try bundle()
        try PresetStore.save(bundle, named: "Good", in: dir)
        try Data(#"{"formatVersion": 1, "name": "Bad", "effects": [{"id": "\#(UUID().uuidString)", "kind": "shimmer", "controls": []}]}"#.utf8)
            .write(to: dir.appending(path: "Bad.json"))
        try Data(#"{"formatVersion": 9, "name": "Newer", "effects": []}"#.utf8).write(to: dir.appending(path: "Newer.json"))
        try Data("nope".utf8).write(to: dir.appending(path: "Broken.json"))

        let library = PresetStore.load(from: dir)
        #expect(library.presets.map(\.name) == ["Good"])
        #expect(library.problems.count == 3)
        let bad = try #require(library.problems.first { $0.url.lastPathComponent == "Bad.json" })
        #expect(bad.message == "The preset can't be used. Unknown effect kind \"shimmer\" at effects[0].kind.")
        let newer = try #require(library.problems.first { $0.url.lastPathComponent == "Newer.json" })
        #expect(newer.message.contains("version 9"))
    }

    @Test func aMissingFolderIsAnEmptyLibrary() {
        let library = PresetStore.load(from: FileManager.default.temporaryDirectory.appending(path: "amv-nothing-\(UUID().uuidString)"))
        #expect(library == PresetLibrary())
    }
}

@Suite struct PresetDragPayloadTests {
    @Test func anIDWithSpacesAndColonsSurvivesTheTripThroughAURL() {
        let payload = PresetDragPayload(presetID: "Warm: grade 2 – “best”")
        #expect(PresetDragPayload(url: payload.url)?.presetID == "Warm: grade 2 – “best”")
    }

    @Test func otherPayloadsAreNotPresets() {
        #expect(PresetDragPayload(url: URL(string: "amv-effect:transform")!) == nil)
        #expect(PresetDragPayload(url: URL(string: "amv-preset:")!) == nil)
    }
}
