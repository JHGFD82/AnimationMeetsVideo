import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct EffectPackageStoreTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-effect-packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A package using every kind of control, an Amount and a filter after.
    private var glow: [String: Any] {
        [
            "formatVersion": 1, "id": "com.example.glow", "version": 2, "name": "Glow", "category": "recolor",
            "symbol": "sparkles",
            "kernel": ["file": "kernel.metal", "function": "exGlow", "type": "general"],
            "controls": [
                ["id": "radius", "name": "Radius", "type": "number", "default": 8, "range": [0, 200], "unit": "px"],
                ["id": "speed", "name": "Speed", "type": "number", "default": 0, "range": [-20, 20], "unit": "/s", "rate": true],
                ["id": "tint", "name": "Tint", "type": "color", "default": [1, 0.8, 0.4]],
                ["id": "middle", "name": "Center", "type": "point"],
                ["id": "gains", "name": "Gains", "type": "vector", "components": ["Low", "High"], "default": [1, 1], "range": [0, 4]],
                [
                    "id": "mode", "name": "Mode", "type": "choice", "default": "soft",
                    "options": [["id": "soft", "name": "Soft"], ["id": "hard", "name": "Hard"]],
                ],
            ],
            "amount": true,
            "arguments": ["radius * scale", "fract(speed * seconds)", "tint", "center(middle)", "gains", "index(mode)"],
            "reach": "radius * scale + 1", "input": "clamped",
            "after": [["filter": "CIBloom", "when": "radius > 0", "parameters": ["inputRadius": "radius * scale", "inputIntensity": "0.5"]]],
        ]
    }

    private let kernel = """
    extern "C" [[stitchable]] float4 exGlow(coreimage::sampler s, float space, float radius, float phase, float4 tint,
        float2 middle, float2 gains, float mode, float amount) { return s.sample(s.coord()); }
    """

    @discardableResult
    private func write(_ manifest: [String: Any], named name: String = "Glow.amveffect") throws -> URL {
        try writeEffectPackage(manifest, kernel: kernel, in: folder, named: name)
    }

    private func problem(_ manifest: [String: Any], builtIn: Bool = false) throws -> String? {
        let url = try write(manifest)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try EffectPackageStore.read(url, builtIn: builtIn)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func aPackageBecomesAnEffectWithItsControls() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try EffectPackageStore.read(try write(glow))
        #expect(package.id == "com.example.glow" && package.version == 2)
        #expect(package.kernelType == .general && package.kernelFunction == "exGlow" && package.kernelSource == kernel)
        #expect(package.edges == .clamped)

        let definition = package.definition
        #expect(definition.name == "Glow" && definition.category == .recolor && definition.systemImage == "sparkles")
        #expect(definition.controlKinds.map(\.savedName) == ["radius", "speed", "tint", "middle", "gains", "mode", "amount"])
        // Amount is the shared one, which the renderer mixes by.
        #expect(definition.controlKinds.last == .amount)

        let controls = Dictionary(uniqueKeysWithValues: package.controls.map { ($0.kind.savedName, $0) })
        #expect(controls["radius"]?.kind.rawValue == "com.example.glow/radius")
        #expect(controls["radius"]?.defaultValues == [8] && controls["radius"]?.unit == " px" && controls["radius"]?.range == 0...200)
        #expect(controls["speed"]?.dragStep == 0.01)
        #expect(package.rateControls == [controls["speed"]!.kind])
        // A color gets an alpha of 1.
        #expect(controls["tint"]?.isColor == true && controls["tint"]?.defaultValues == [1, 0.8, 0.4, 1])
        #expect(controls["middle"]?.defaultValues == [0, 0] && controls["middle"]?.componentNames == ["Δx", "Δy"])
        #expect(controls["gains"]?.componentNames == ["Low", "High"])
        #expect(controls["mode"]?.choiceOptions.map(\.id) == ["soft", "hard"] && controls["mode"]?.defaultChoice == "soft")

        #expect(package.arguments.map(\.type) == [.number, .number, .vector(4), .vector(2), .vector(2), .number])
        #expect(package.reach?.text == "radius * scale + 1")
        #expect(package.after.map(\.name) == ["CIBloom"])
        #expect(package.after[0].parameters.map(\.key) == ["inputIntensity", "inputRadius"])
    }

    @Test func packagesAreInstalledAfterTheBuiltInEffects() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try EffectPackageStore.read(try write(glow))
        var copy = glow
        copy["id"] = "posterize"
        let clash = try EffectPackageStore.read(try write(copy, named: "Posterize.amveffect"), builtIn: true)
        let registry = EffectRegistry.withBuiltIns([package, package, clash])

        #expect(registry.effects.count == EffectRegistry.builtIn.effects.count + 1)
        #expect(registry.effects.last?.package?.id == "com.example.glow")
        // A taken ID is refused, whether a built-in effect's (Posterize ships
        // as a package) or another package's, and the effect that has it is
        // kept.
        #expect(registry.problems.map(\.message) == [
            "An effect called \"com.example.glow\" is already installed.", "An effect called \"posterize\" is already installed.",
        ])
        #expect(registry.effect(named: "posterize")?.package?.url == EffectKind.posterize.definition.package?.url)

        EffectRegistry.$override.withValue(registry) {
            let kind = EffectKind(rawValue: "com.example.glow")
            #expect(kind == package.kind)
            #expect(EffectKind.all.contains(package.kind))
            #expect(kind?.name == "Glow")
            #expect(kind?.controlKinds.first?.name == "Radius")
        }
        #expect(EffectKind(rawValue: "com.example.glow") == nil)
    }

    @Test func problemsSayWhereTheyAre() throws {
        func changed(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var manifest = glow
            change(&manifest)
            return manifest
        }
        func control(_ index: Int, _ key: String, _ value: Any) -> [String: Any] {
            changed {
                var controls = $0["controls"] as! [[String: Any]]
                controls[index][key] = value
                $0["controls"] = controls
            }
        }
        func filter(_ key: String, _ value: Any) -> [String: Any] {
            changed {
                var after = $0["after"] as! [[String: Any]]
                after[0][key] = value
                $0["after"] = after
            }
        }
        let cases: [([String: Any], String)] = [
            (changed { $0["id"] = "glow" }, "The ID \"glow\" needs a dot, as in \"com.example.glow\" at id."),
            (changed { $0["id"] = "com..glow" }, "\"com..glow\" isn't a valid ID: use letters, digits and hyphens, in parts joined by dots at id."),
            (changed { $0["colour"] = "red" }, "Unknown key \"colour\" at the top level of the file."),
            (changed { $0["category"] = "blur" }, "Unknown category \"blur\" at category."),
            (changed { $0["arguments"] = ["radius", "spped"] }, "Unknown name \"spped\" at arguments[1]."),
            (changed { $0["kernel"] = ["file": "missing.metal", "function": "exGlow", "type": "general"] },
             "The package has no file \"missing.metal\" at kernel.file."),
            (changed { $0["kernel"] = ["file": "../kernel.metal", "function": "exGlow", "type": "general"] },
             "\"../kernel.metal\" isn't a file in the package at kernel.file."),
            (changed { $0["kernel"] = ["file": "kernel.metal", "function": "exBlur", "type": "general"] },
             "kernel.metal has no function \"exBlur\" at kernel.function."),
            (changed { $0["kernel"] = ["file": "kernel.metal", "function": "exGlow", "type": "color"]; $0["input"] = nil },
             "A color kernel reads only its own pixel, so it has no reach at reach."),
            (changed { $0["reach"] = "tint" }, "Expected one number, not 4 numbers at reach."),
            (control(0, "type", "slider"), "Unknown control type \"slider\" at controls[0].type."),
            (control(0, "default", 500), "The default 500.0 is outside the range at controls[0].default."),
            (control(1, "id", "radius"), "Another control is called \"radius\" at controls[1].id."),
            (control(1, "id", "seconds"), "\"seconds\" is a name expressions already use at controls[1].id."),
            (control(4, "default", [1, 1, 1]), "Expected a list of 2 numbers, one per component at controls[4].default."),
            (control(5, "default", "medium"), "The default \"medium\" isn't one of the options at controls[5].default."),
            (filter("filter", "CINope"), "Core Image has no filter \"CINope\" at after[0].filter."),
            (filter("parameters", ["inputNope": "1"]), "CIBloom has no input \"inputNope\" at after[0].parameters.inputNope."),
            (filter("when", "mode"), "\"mode\" is a choice; read it as index(mode) at after[0].when."),
        ]
        for (manifest, message) in cases {
            #expect(try problem(manifest) == "The package can't be used. " + message)
        }
        #expect(try problem(changed { $0["formatVersion"] = 2 }) == "The package has format version 2; this app reads version 1.")
        // Packages that ship with the app keep the names their effects
        // were saved under before they were packages.
        #expect(try problem(changed { $0["id"] = "glow" }, builtIn: true) == nil)
    }

    @Test func loadingListsThePackagesAndWhatCouldntBeRead() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(glow)
        var broken = glow
        broken["arguments"] = ["radius +"]
        try write(broken, named: "Broken.amveffect")
        try write(glow, named: "Not a package")
        let library = EffectPackageStore.load(from: folder)
        #expect(library.packages.map(\.id) == ["com.example.glow"])
        #expect(library.problems.map(\.url.lastPathComponent) == ["Broken.amveffect"])
        #expect(library.problems.first?.message == "The package can't be used. The expression ends too soon at arguments[0].")
        #expect(EffectPackageStore.load(from: folder.appending(path: "nowhere")).packages.isEmpty)
    }

    @Test func aPackageEffectIsSavedUnderItsOwnNames() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try EffectPackageStore.read(try write(glow))
        let registry = EffectRegistry.withBuiltIns([package])
        try EffectRegistry.$override.withValue(registry) {
            var effect = Effect(kind: package.kind)
            let radius = effect.controls.firstIndex { $0.kind.savedName == "radius" }!
            effect.controls[radius].setComponent(0, to: 40, at: .zero)
            let bundle = EffectBundle(effects: [EffectBundle.Effect(effect: effect)], origin: .zero)
            let presets = folder.appending(path: "Presets", directoryHint: .isDirectory)
            let saved = try PresetStore.save(bundle, named: "Big Glow", in: presets)

            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.url)) as! [String: Any]
            let entry = (json["effects"] as! [[String: Any]])[0]
            #expect(entry["kind"] as? String == "com.example.glow")
            #expect((entry["controls"] as! [[String: Any]]).map { $0["kind"] as! String } == [
                "radius", "speed", "tint", "middle", "gains", "mode", "amount",
            ])

            let read = try PresetStore.read(saved.url).bundle.effects[0].effect
            #expect(read.kind == package.kind)
            #expect(read.controls.map(\.kind) == effect.controls.map(\.kind))
            #expect(read.control(effect.controls[radius].kind)?.values(at: .zero) == [40])
        }
    }

    /// Posterize, saved when it was written in Swift (as the app writes
    /// times, in rational seconds), reads as the package and is saved as it
    /// was.
    @Test func anEffectSavedBeforeItsLookMovedReadsAndSavesTheSame() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects: [[String: Any]] = [[
            "id": UUID().uuidString, "kind": "posterize",
            "controls": [
                ["id": UUID().uuidString, "kind": "levels", "value": 5],
                ["id": UUID().uuidString, "kind": "amount", "keyframes": [["time": "0/1s", "value": 20], ["time": "1/1s", "value": 90]]],
            ],
        ]]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Old.json")
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "name": "Old", "effects": effects]).write(to: url)

        let read = try PresetStore.read(url)
        let effect = read.bundle.effects[0].effect
        #expect(effect.kind == .posterize && effect.kind.definition.package != nil)
        #expect(effect.control(EffectKind.posterize.controlKind(savedAs: "levels")!)?.values(at: .zero) == [5])

        let saved = try PresetStore.save(read.bundle, named: "Again", in: folder)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.url)) as! [String: Any]
        #expect(NSArray(array: json["effects"] as! [[String: Any]]) == NSArray(array: effects))
    }
}
