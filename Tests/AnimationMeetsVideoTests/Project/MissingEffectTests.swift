import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Projects using effect packages that aren't installed where they are
/// opened (see docs/effect-packages.md, "Missing effects").
@Suite struct MissingEffectTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "amv-missing-effects-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var packageURL: URL { root.appending(path: "Test.amv", directoryHint: .isDirectory) }
    private var projectFile: URL { packageURL.appending(path: ProjectStore.projectFileName) }

    /// A Glow effect as a package would save it, with a key this app
    /// doesn't know, to be kept as it is.
    private let glow: [String: Any] = [
        "id": UUID().uuidString, "kind": "com.example.glow",
        "controls": [["id": UUID().uuidString, "kind": "radius", "value": 40]],
        "futureSetting": ["anything": [1, 2, 3]],
    ]

    /// The Glow package, for opening the project where it is installed.
    private func glowPackage() throws -> EffectPackage {
        let radius: [String: Any] = ["id": "radius", "name": "Radius", "type": "number", "default": 8, "range": [0, 200]]
        let url = try writeEffectPackage(
            effectManifest("com.example.glow", function: "exGlow", controls: [radius], arguments: ["radius"]),
            kernel: "extern \"C\" [[stitchable]] float4 exGlow(coreimage::sample_t s, float space, float r) { return s; }",
            in: root, named: "Glow.amveffect"
        )
        return try EffectPackageStore.read(url)
    }

    /// A saved project with a rectangle, its clip's effects in the file
    /// replaced with `effects` (in its sound's stack with `audio`).
    private func project(with effects: [[String: Any]], audio: Bool = false) async throws -> UUID {
        var project = EditingProject.empty
        let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
        let shape = try #require(created)
        try await ProjectStore.save(project, to: packageURL)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: projectFile)) as! [String: Any]
        var timelines = json["timelines"] as! [[String: Any]]
        for t in timelines.indices {
            var layers = timelines[t]["layers"] as! [[String: Any]]
            for l in layers.indices {
                var clips = layers[l]["clips"] as! [[String: Any]]
                for c in clips.indices where clips[c]["id"] as? String == shape.clipID.uuidString {
                    clips[c][audio ? "audioEffects" : "effects"] = (clips[c]["effects"] as? [[String: Any]] ?? []) + effects
                }
                layers[l]["clips"] = clips
            }
            timelines[t]["layers"] = layers
        }
        json["timelines"] = timelines
        try JSONSerialization.data(withJSONObject: json).write(to: projectFile)
        return shape.clipID
    }

    private func open(_ clipID: UUID) async throws -> (project: EditingProject, clip: TimelineClip) {
        let project = try await ProjectStore.load(from: packageURL).project
        return (project, try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.clip))
    }

    /// The saved effects of the clip, as they are in the file.
    private func savedEffects(_ clipID: UUID) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: projectFile)) as! [String: Any]
        for timeline in json["timelines"] as! [[String: Any]] {
            for layer in timeline["layers"] as! [[String: Any]] {
                for clip in layer["clips"] as! [[String: Any]] where clip["id"] as? String == clipID.uuidString {
                    return clip["effects"] as? [[String: Any]] ?? []
                }
            }
        }
        return []
    }

    @Test func aProjectOpensWithAnEffectWhosePackageIsMissing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clipID = try await project(with: [glow])
        let (project, clip) = try await open(clipID)

        let effect = try #require(clip.effects.last)
        #expect(effect.kind == .missing)
        #expect(effect.missing?.kind == "com.example.glow")
        #expect(effect.displayName == "Glow")
        #expect(effect.isNoOp && effect.controls.isEmpty)
        let layer = try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.layer)
        let timeline = try #require(project.timelines.first)
        let note = project.note(forEffectAt: clip.effects.count - 1, in: clip, on: layer, of: timeline)
        #expect(note?.dims == true && note?.text.hasPrefix("Not installed (com.example.glow)") == true)
        // It isn't something the library offers.
        #expect(!EffectKind.all.contains(.missing))

        // Saved back as it was read, the key this app doesn't know too.
        try await ProjectStore.save(project, to: packageURL)
        #expect(NSDictionary(dictionary: try savedEffects(clipID).last!) == NSDictionary(dictionary: glow))
    }

    @Test func installingThePackageBringsTheEffectBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var known = glow
        known["futureSetting"] = nil
        let clipID = try await project(with: [known])
        let package = try glowPackage()
        try await EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
            let effect = try #require(try await open(clipID).clip.effects.last)
            #expect(effect.kind == package.kind && effect.missing == nil)
            let radius = try #require(package.kind.controlKind(savedAs: "radius"))
            #expect(effect.control(radius)?.values(at: .zero) == [40])
        }
    }

    @Test func anEffectSavedWithAControlItsPackageLacksOpensAndHoldsIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var newer = glow
        newer["futureSetting"] = nil
        newer["controls"] = [
            ["id": UUID().uuidString, "kind": "radius", "value": 40],
            ["id": UUID().uuidString, "kind": "sparkle", "value": "lots"],
        ]
        let clipID = try await project(with: [newer])
        let package = try glowPackage()
        try await EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
            let (project, clip) = try await open(clipID)
            let effect = try #require(clip.effects.last)
            // Opened with the package's controls, Sparkle held and noted.
            #expect(effect.missing == nil && effect.kind == package.kind)
            let radius = try #require(package.kind.controlKind(savedAs: "radius"))
            #expect(effect.control(radius)?.values(at: .zero) == [40])
            #expect(effect.packageChanges.held.keys.sorted() == ["sparkle"])
            #expect(effect.packageChanges.note == "Saved with a control this package no longer has: `sparkle`; saving leaves it out.")
            // Saved, Sparkle is left out.
            try await ProjectStore.save(project, to: packageURL)
            let saved = try #require(try savedEffects(clipID).last?["controls"] as? [[String: Any]])
            #expect(saved.map { $0["kind"] as? String } == ["radius"])
        }
    }

    @Test func aValueSavedAtAnotherSizeIsResetOnOpening() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var older = glow
        older["futureSetting"] = nil
        older["controls"] = [["id": UUID().uuidString, "kind": "radius", "value": [1, 2, 3]]]
        let clipID = try await project(with: [older])
        let package = try glowPackage()
        try await EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
            let effect = try #require(try await open(clipID).clip.effects.last)
            let radius = try #require(package.kind.controlKind(savedAs: "radius"))
            #expect(effect.control(radius)?.values(at: .zero) == radius.defaultValues)
            #expect(effect.packageChanges.note == "`radius` was reset: it is now one number.")
        }
    }

    @Test func aMalformedControlIsStillRefusedWithWhereItIs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try glowPackage()
        for (control, problem) in [
            (["enabled": "yes"], "Expected true or false"),
            (["colour": 1], "Unknown key \"colour\""),
            (["value": nil, "keyframes": 3] as [String: Any?], "Expected a list"),
        ] as [([String: Any?], String)] {
            var effect = glow
            effect["futureSetting"] = nil
            var entry: [String: Any] = ["id": UUID().uuidString, "kind": "radius", "value": 40]
            for (key, value) in control { entry[key] = value }
            effect["controls"] = [entry]
            let clipID = try await project(with: [effect])
            await EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
                await #expect {
                    _ = try await open(clipID)
                } throws: { error in
                    error.localizedDescription.contains(problem) && error.localizedDescription.contains(".controls[0]")
                }
            }
        }
    }

    @Test func aMissingEffectCanBeTurnedOffAndCopied() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clipID = try await project(with: [glow])
        let opened = try await open(clipID)
        var project = opened.project
        let effect = try #require(opened.clip.effects.last)
        var copy = effect.duplicated()
        copy.enabled = false
        project.editClip(clipID, in: project.rootTimelineID) { $0.effects.append(copy) }
        // Reset leaves what it can't read as it is.
        var reset = effect
        reset.reset()
        #expect(reset == effect)

        try await ProjectStore.save(project, to: packageURL)
        let saved = try savedEffects(clipID)
        let original = saved[saved.count - 2], copied = saved[saved.count - 1]
        #expect(copied["id"] as? String == copy.id.uuidString && copied["enabled"] as? Bool == false)
        #expect(original["enabled"] == nil)
        let ids = { (entry: [String: Any]) in (entry["controls"] as! [[String: Any]]).map { $0["id"] as! String } }
        #expect(ids(copied) != ids(original))
        #expect(copied["futureSetting"] as? [String: [Int]] == ["anything": [1, 2, 3]])
    }

    @Test func onlyAPackagesKindCanBeMissing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Without a dot it is a mistake, or a newer app's own effect.
        var unknown = glow
        unknown["kind"] = "glow"
        let first = try await project(with: [unknown])
        await #expect(throws: (any Error).self) { try await open(first) }
        // Packages' effects are all pictures', so one isn't in a sound's
        // stack.
        try? FileManager.default.removeItem(at: root)
        let second = try await project(with: [glow], audio: true)
        await #expect(throws: (any Error).self) { try await open(second) }
    }

    @Test func aPresetKeepsAnEffectWhosePackageIsMissing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "Glowing.json")
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "name": "Glowing", "effects": [glow]]).write(to: url)
        let preset = try PresetStore.read(url)
        #expect(preset.bundle.effects.map(\.effect.missing?.kind) == ["com.example.glow"])
        let saved = try PresetStore.save(preset.bundle, named: "Again", in: root)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.url)) as! [String: Any]
        #expect(NSDictionary(dictionary: (json["effects"] as! [[String: Any]])[0]) == NSDictionary(dictionary: glow))
    }
}
