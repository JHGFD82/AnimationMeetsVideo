import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Making an effect package from the app, and installing it while the app
/// runs (see docs/effect-packages.md, "Starting one from the app").
@Suite struct MakingEffectPackagesTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-making-packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func aPackagesIDIsItsNameInCamelCase() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        func id(_ name: String) -> String { EffectPackageStore.userID(for: name, in: folder) }
        #expect(id("My Glow") == "user.myGlow")
        #expect(id("  neon   edges 2 ") == "user.neonEdges2")
        #expect(id("Rainbow-Smear!") == "user.rainbowSmear")
        // Other scripts are written in Latin letters, as IDs and Metal
        // names must be.
        #expect(id("Crème Brûlée") == "user.cremeBrulee")
        #expect(id("Ölfarbe Glühen") == "user.olfarbeGluhen")
        #expect(id("Straße") == "user.strasse")
        #expect(id("光") == "user.guang")
        #expect(id("Свет") == "user.svet")
        // A name with no letter to start it takes the first free
        // `user.effect`, past those of packages in the folder.
        #expect(id("2 Fast") == "user.effect")
        #expect(id("★") == "user.effect")
        #expect(id("…") == "user.effect")
        let first = try EffectPackageStore.makePackage(named: "★", in: folder)
        #expect(try EffectPackageStore.read(first).id == "user.effect")
        #expect(id("★★") == "user.effect2")
        let second = try EffectPackageStore.read(try EffectPackageStore.makePackage(named: "★★", in: folder))
        // Named exactly as typed, its kernel a Metal name.
        #expect(second.id == "user.effect2" && second.name == "★★" && second.kernelFunction == "userEffect2")
        #expect(PackageKernels.problem(for: second) == nil)
    }

    @Test func aNewPackageReadsCompilesAndIsNamedAsAsked() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try EffectPackageStore.makePackage(named: "My Glow", in: folder)
        #expect(url.lastPathComponent == "My Glow.amveffect")
        let package = try EffectPackageStore.read(url)
        #expect(package.id == "user.myGlow" && package.name == "My Glow" && package.kernelFunction == "userMyGlow")
        #expect(PackageKernels.problem(for: package) == nil)
        #expect(package.definition.controlKinds.map(\.savedName) == ["tint", "strength", "amount"])
        // A name that is a Metal word still makes a kernel that compiles.
        let half = try EffectPackageStore.read(try EffectPackageStore.makePackage(named: "Half", in: folder))
        #expect(PackageKernels.problem(for: half) == nil)
    }

    @Test func aPackageIsntMadeOverAnother() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try EffectPackageStore.makePackage(named: "My Glow", in: folder)
        #expect(throws: (any Error).self) { try EffectPackageStore.makePackage(named: "My Glow", in: folder) }
        #expect(throws: (any Error).self) { try EffectPackageStore.makePackage(named: "  ", in: folder) }
    }

    @Test func aPackageIsAddedBesideThoseInstalled() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try EffectPackageStore.read(try EffectPackageStore.makePackage(named: "First", in: folder))
        let second = try EffectPackageStore.read(try EffectPackageStore.makePackage(named: "Second", in: folder))
        let unread = EffectPackageProblem(url: folder.appending(path: "Broken.amveffect"), message: "Broken.")
        let running = EffectRegistry.withBuiltIns([first], problems: [unread])

        let added = try running.adding(second)
        #expect(added.effects.compactMap(\.package?.id).suffix(2) == ["user.first", "user.second"])
        #expect(added.effects.count == running.effects.count + 1)
        // What couldn't be read stays listed, once.
        #expect(added.problems.map(\.message) == running.problems.map(\.message))
        // An ID that is taken isn't added again.
        #expect(throws: (any Error).self) { try added.adding(second) }
    }

    @Test func aLookIsCopiedAsANewPackage() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let twirl = try #require(EffectKind.twirl.definition.package)
        let url = try EffectPackageStore.copyPackage(twirl, in: folder)
        #expect(url.lastPathComponent == "Twirl Copy.amveffect")
        let copy = try EffectPackageStore.read(url)
        #expect(copy.id == "user.twirlCopy" && copy.name == "Twirl Copy" && copy.version == 1)
        // Its controls and kernel as they were.
        #expect(copy.controls.map(\.kind.savedName) == twirl.controls.map(\.kind.savedName))
        #expect(copy.controls.map(\.defaultValues) == twirl.controls.map(\.defaultValues))
        #expect(copy.kernelSource == twirl.kernelSource && copy.arguments.map(\.text) == twirl.arguments.map(\.text))
        #expect(PackageKernels.problem(for: copy) == nil)
        // The manifest is edited, not rewritten: the controls' IDs, and its
        // layout, stay.
        let manifest = try String(contentsOf: url.appending(path: "effect.json"), encoding: .utf8)
        let original = try String(contentsOf: twirl.url.appending(path: "effect.json"), encoding: .utf8)
        #expect(manifest.components(separatedBy: "\n").count == original.components(separatedBy: "\n").count)

        // A second copy takes the next name.
        let again = try EffectPackageStore.read(try EffectPackageStore.copyPackage(twirl, in: folder))
        #expect(again.id == "user.twirlCopy2" && again.name == "Twirl Copy 2")
    }

    /// A package elsewhere, as one downloaded, made under `name`.
    private func downloaded(_ name: String, renamedTo id: String? = nil) throws -> URL {
        let url = try EffectPackageStore.makePackage(named: name, in: folder.appending(path: "Downloads"))
        if let id {
            let manifest = url.appending(path: "effect.json")
            let text = try String(contentsOf: manifest, encoding: .utf8)
            try text.replacingOccurrences(of: "\"user.\(name.lowercased())\"", with: "\"\(id)\"").write(to: manifest, atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func openingAPackageInstallsItOrSaysWhatItWouldReplace() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects = folder.appending(path: "Effects")
        let glow = try downloaded("Glow")

        // New: copied in and installed.
        let (package, opening) = try EffectPackageStore.opening(glow, into: effects)
        #expect(package.id == "user.glow")
        #expect(opening == .install(destination: effects.appending(path: "Glow.amveffect", directoryHint: .isDirectory)))
        let copied = try EffectPackageStore.copyIn(glow, into: effects)
        #expect(try EffectPackageStore.read(copied).id == "user.glow")

        // Opened again: its folder name is taken.
        #expect(try EffectPackageStore.opening(glow, into: effects).1 == .replace(existing: [copied]))

        // In the Effects folder but not installed, as one put there by hand
        // while the app runs: installed from where it is.
        #expect(try EffectPackageStore.opening(copied, into: effects).1 == .install(destination: copied))

        // Installed, and opened from the Effects folder itself.
        let installed = EffectRegistry.withBuiltIns([try EffectPackageStore.read(copied)])
        try EffectRegistry.$override.withValue(installed) {
            #expect(try EffectPackageStore.opening(copied, into: effects).1 == .alreadyInstalled)
            // Another folder with the same ID replaces the installed one.
            let renamed = try downloaded("Shine", renamedTo: "user.glow")
            #expect(try EffectPackageStore.opening(renamed, into: effects).1 == .replace(existing: [copied]))
            // One whose folder name another has, and whose ID the installed
            // one has, replaces both.
            let shine = try EffectPackageStore.copyIn(renamed, into: effects)
            #expect(try EffectPackageStore.opening(renamed, into: effects).1 == .replace(existing: [shine, copied]))
        }

        // Replacing removes the old folder and copies the new one.
        try EffectPackageStore.copyIn(glow, into: effects, replacing: [copied])
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "effect.json").path))
    }

    @Test func aCopysManifestIsEditedOnlyWhereItIsSure() throws {
        let manifest = """
        { "id": "com.example.glow", "name": "Glow", "version": 3,
          "controls": [{ "id": "glow", "name": "Glow", "type": "number", "default": 1 }] }
        """
        // The package's name is a control's too: the first, the top level's,
        // is changed, but it can't be sure that is the right one.
        let shared = manifest.renamed(id: ("com.example.glow", "user.glowCopy"), name: ("Glow", "Glow Copy"))
        #expect(!shared.certain)
        #expect(shared.text.contains(#""name": "Glow Copy", "version": 1"#))
        #expect(shared.text.contains(#"{ "id": "glow", "name": "Glow", "type""#))
        // Each key once: sure.
        let alone = manifest.replacingOccurrences(of: #""name": "Glow", "type""#, with: #""name": "Shine", "type""#)
            .renamed(id: ("com.example.glow", "user.glowCopy"), name: ("Glow", "Glow Copy"))
        #expect(alone.certain && alone.text.contains(#""id": "user.glowCopy""#))
        // A key not found at all: not sure either.
        #expect(!manifest.renamed(id: ("com.example.other", "user.x"), name: ("Glow", "Glow Copy")).certain)
    }

    @Test func aCopyWhoseControlSharesItsNameIsRenamedAtTheTopLevel() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Keys sorted, so the controls come before the package's own name.
        let controls: [[String: Any]] = [["id": "glow", "name": "Glow", "type": "number", "default": 1]]
        let url = try writeEffectPackage(
            effectManifest("com.example.glow", function: "exGlow", controls: controls, arguments: ["glow"]).merging(["name": "Glow"]) { $1 },
            kernel: "extern \"C\" [[stitchable]] float4 exGlow(coreimage::sample_t s, float space, float glow) { return s; }",
            in: folder.appending(path: "Downloads"), named: "Glow.amveffect"
        )
        let copy = try EffectPackageStore.read(try EffectPackageStore.copyPackage(try EffectPackageStore.read(url), in: folder))
        #expect(copy.id == "user.glowCopy" && copy.name == "Glow Copy" && copy.version == 1)
        #expect(copy.controls.map(\.name) == ["Glow"])
    }

    @Test func aPackageCantTakeTheIDOfOneThatShips() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // The app's own IDs have no dot, which every other package's needs.
        let twirl = try downloaded("Twirl", renamedTo: "twirl")
        #expect {
            try EffectPackageStore.opening(twirl, into: folder.appending(path: "Effects"))
        } throws: { error in
            error.localizedDescription.contains("needs a dot")
        }
    }

    @Test func theAppBundleDeclaresThePackageType() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path), root.pathComponents.count > 1 {
            root = root.deletingLastPathComponent()
        }
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: root.appending(path: "Packaging/Info.plist")), format: nil)
                as? [String: Any]
        )
        let declared = try #require((plist["UTExportedTypeDeclarations"] as? [[String: Any]])?.first {
            $0["UTTypeIdentifier"] as? String == EffectPackageStore.packageTypeIdentifier
        })
        #expect((declared["UTTypeConformsTo"] as? [String])?.contains("com.apple.package") == true)
        let tags = declared["UTTypeTagSpecification"] as? [String: Any]
        #expect(tags?["public.filename-extension"] as? [String] == [EffectPackage.fileExtension])
        let documents = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        #expect(documents.contains { $0["LSItemContentTypes"] as? [String] == [EffectPackageStore.packageTypeIdentifier] })
    }
}
