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
}
