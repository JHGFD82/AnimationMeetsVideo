import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Making an effect package from the app, and installing it while the app
/// runs (see docs/effect-packages.md, "Starting one from the app").
@Suite struct MakingEffectPackagesTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-making-packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func aPackagesIDIsItsNameInCamelCase() {
        #expect(EffectPackageStore.userID(for: "My Glow") == "user.myGlow")
        #expect(EffectPackageStore.userID(for: "  neon   edges 2 ") == "user.neonEdges2")
        #expect(EffectPackageStore.userID(for: "Rainbow-Smear!") == "user.rainbowSmear")
        #expect(EffectPackageStore.userID(for: "2 Fast") == nil)
        #expect(EffectPackageStore.userID(for: "…") == nil)
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
        #expect(throws: (any Error).self) { try EffectPackageStore.makePackage(named: "2 Fast", in: folder) }
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

        // Installed, and opened from the Effects folder itself.
        let installed = EffectRegistry.withBuiltIns([try EffectPackageStore.read(copied)])
        try EffectRegistry.$override.withValue(installed) {
            #expect(try EffectPackageStore.opening(copied, into: effects).1 == .alreadyInstalled)
            // Another folder with the same ID replaces the installed one.
            let renamed = try downloaded("Shine", renamedTo: "user.glow")
            #expect(try EffectPackageStore.opening(renamed, into: effects).1 == .replace(existing: [copied]))
        }

        // Replacing removes the old folder and copies the new one.
        try EffectPackageStore.copyIn(glow, into: effects, replacing: [copied])
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "effect.json").path))
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
