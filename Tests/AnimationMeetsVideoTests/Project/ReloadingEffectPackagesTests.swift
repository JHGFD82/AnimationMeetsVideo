import CoreImage
import Foundation
import Synchronization
import Testing
@testable import AnimationMeetsVideo

/// Reading a package in the Effects folder again while the app runs, as
/// the folder's watcher does when one changes (see docs/effect-packages.md,
/// "Changing one while the app runs").
@Suite struct ReloadingEffectPackagesTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-reloading-packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    private let tint: [[String: Any]] = [["id": "strength", "name": "Strength", "type": "number", "default": 1]]

    private func kernel(_ body: String = "return s;") -> String {
        "extern \"C\" [[stitchable]] float4 exTint(coreimage::sample_t s, float space, float strength) { \(body) }"
    }

    @discardableResult
    private func write(
        controls: [[String: Any]]? = nil, arguments: [String] = ["strength"], kernel: String? = nil, id: String = "com.example.tint"
    ) throws -> URL {
        let manifest = effectManifest(id, function: "exTint", controls: controls ?? tint, arguments: arguments)
        return try writeEffectPackage(manifest, kernel: kernel ?? self.kernel(), in: folder, named: "Tint.amveffect")
    }

    private func read(_ url: URL) -> Result<EffectPackage, any Error> {
        Result { try EffectPackageStore.read(url) }
    }

    @Test func aChangedKernelReplacesTheOneInstalled() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let running = EffectRegistry.withBuiltIns([try EffectPackageStore.read(url)])
        try write(kernel: kernel("return s * strength;"))

        let (reloaded, changed) = running.reloading(url, as: read(url))
        #expect(changed?.kernelSource == kernel("return s * strength;"))
        #expect(reloaded.effect(named: "com.example.tint")?.package?.contentHash == changed?.contentHash)
        #expect(reloaded.effects.count == running.effects.count && reloaded.problems.isEmpty)
        // Read again unchanged, nothing changes.
        #expect(reloaded.reloading(url, as: read(url)).changed == nil)
    }

    @Test func aPackageWhoseControlsChangedReplacesTheOneInstalled() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let installed = try EffectPackageStore.read(url)
        let running = EffectRegistry.withBuiltIns([installed])
        let strength = ControlKind(package: "com.example.tint", control: "strength")
        var project = EditingProject.empty
        let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
        let shape = try #require(created)

        // Strength gives way to Glow.
        let glow: [[String: Any]] = [["id": "glow", "name": "Glow", "type": "number", "default": 0.5]]
        try write(controls: glow, arguments: ["glow"], kernel: kernel().replacingOccurrences(of: "strength", with: "glow"))
        let (reloaded, changed) = running.reloading(url, as: read(url))
        #expect(changed?.controls.map(\.name) == ["Glow"] && reloaded.problems.isEmpty)

        EffectRegistry.$override.withValue(running) {
            project.editClip(shape.clipID, in: project.rootTimelineID) { $0.effects.append(Effect(kind: installed.kind)) }
        }
        try EffectRegistry.$override.withValue(reloaded) {
            // Before it is fitted, Strength is still looked up as it was.
            let stale = try #require(project.clipAndLayer(shape.clipID, in: project.rootTimelineID)?.clip.effects.last)
            #expect(stale.controls.map(\.kind) == [strength] && strength.name == "Strength")
            #expect(!reloaded.addable.contains(where: { $0.rawValue == strength.rawValue }))

            // Fitted, as an open project is: Strength is held, and Glow,
            // which the package gained, added at its default.
            let fitted = project.fitPackageEffects(newSince: ["com.example.tint": installed])
            #expect(fitted)
            let effect = try #require(project.clipAndLayer(shape.clipID, in: project.rootTimelineID)?.clip.effects.last)
            #expect(effect.controls.map(\.kind.savedName) == ["glow"] && effect.controls[0].values(at: .zero) == [0.5])
            #expect(effect.packageChanges.held.keys.sorted() == ["strength"])
            #expect(effect.packageChanges.note == "Saved with a control this package no longer has: `strength`; saving leaves it out.")
            // Saved, Strength is left out.
            #expect(ProjectFile.EffectEntry(effect).controls.map(\.kind) == ["glow"])
            // Fitted again (as undo does), nothing more changes.
            let again = project.fitPackageEffects()
            #expect(!again)
        }
    }

    @Test func aNumberThatBecomesTwoIsResetInOpenProjects() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let installed = try EffectPackageStore.read(url)
        let running = EffectRegistry.withBuiltIns([installed])
        let strength = ControlKind(package: "com.example.tint", control: "strength")
        var project = EditingProject.empty
        let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
        let shape = try #require(created)
        EffectRegistry.$override.withValue(running) {
            var effect = Effect(kind: installed.kind)
            effect.changeControl(strength) { $0.setComponent(0, to: 0.25, at: .zero) }
            project.editClip(shape.clipID, in: project.rootTimelineID) { $0.effects.append(effect) }
        }

        // Strength becomes two numbers, while the project uses it.
        let pair: [[String: Any]] = [["id": "strength", "name": "Strength", "type": "vector", "components": ["A", "B"], "default": [1, 2]]]
        try write(controls: pair, kernel: kernel().replacingOccurrences(of: "float strength", with: "float2 strength"))
        let (reloaded, changed) = running.reloading(url, as: read(url))
        #expect(changed != nil && reloaded.problems.isEmpty)

        try EffectRegistry.$override.withValue(reloaded) {
            let fitted = project.fitPackageEffects(newSince: ["com.example.tint": installed])
            #expect(fitted)
            let clip = try #require(project.clipAndLayer(shape.clipID, in: project.rootTimelineID)?.clip)
            let effect = try #require(clip.effects.last)
            #expect(effect.control(strength)?.values(at: .zero) == [1, 2])
            #expect(effect.packageChanges.note == "`strength` was reset: it is now 2 numbers.")
            // And it draws, its value read at the new count.
            let step = try #require(LookStep(effect, at: .zero))
            #expect(step.numbers[strength] == [1, 2])
            let frame = CGRect(x: 0, y: 0, width: 4, height: 4)
            _ = LookRenderer.apply(step, to: CIImage(color: .red).cropped(to: frame), over: frame, canvas: frame, frame: frame, scale: 1, space: .rec709)
        }
    }

    @Test func aChoiceKeepsAnOptionStillOffered() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        func choice(_ options: [String], default value: String) -> [[String: Any]] {
            [["id": "mode", "name": "Mode", "type": "choice", "default": value, "options": options.map { ["id": $0, "name": $0] }]]
        }
        let choiceKernel = kernel().replacingOccurrences(of: "float strength", with: "float mode")
        let url = try write(controls: choice(["soft", "hard", "wild"], default: "soft"), arguments: ["index(mode)"], kernel: choiceKernel)
        let installed = try EffectPackageStore.read(url)
        let mode = ControlKind(package: "com.example.tint", control: "mode")
        var effects = try EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([installed])) {
            try ["hard", "wild"].map { picked in
                var effect = Effect(kind: installed.kind)
                effect.changeControl(mode) { $0.choice = picked }
                return try #require(Optional(effect))
            }
        }
        // Wild is no longer offered.
        try write(controls: choice(["soft", "hard"], default: "soft"), arguments: ["index(mode)"], kernel: choiceKernel)
        let reloaded = EffectRegistry.withBuiltIns([try EffectPackageStore.read(url)])
        EffectRegistry.$override.withValue(reloaded) {
            for index in effects.indices { effects[index].fitToPackage(newSince: installed) }
        }
        #expect(effects.map { $0.control(mode)?.choice } == ["hard", "soft"])
        #expect(effects[0].packageChanges.isEmpty)
        #expect(effects[1].packageChanges.note == "`mode` was reset: \"wild\" isn't one of its options now.")
    }

    @Test func aNewPackageIsAddedAndABrokenOneListed() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let running = EffectRegistry.withBuiltIns()
        let url = try write()
        let (added, changed) = running.reloading(url, as: read(url))
        #expect(changed?.id == "com.example.tint")
        #expect(added.effects.count == running.effects.count + 1)

        // One that can no longer be read is listed, the one installed
        // staying in use.
        try Data("{".utf8).write(to: url.appending(path: "effect.json"))
        let (broken, none) = added.reloading(url, as: read(url))
        #expect(none == nil && broken.effect(named: "com.example.tint") != nil)
        #expect(broken.problems.map(\.url) == [url.standardizedFileURL])

        // One removed is no longer listed, and its problem goes; an effect
        // of it already made still finds its definition.
        let removed = broken.reloading(url, as: nil).registry
        let kind = EffectKind(package: "com.example.tint")
        #expect(removed.effect(named: kind.rawValue) == nil && removed.problems.isEmpty)
        #expect(removed.isRetired(kind) && removed.definition(of: kind).package?.id == "com.example.tint")
        #expect(!removed.addable.contains(kind))
        // Put back, it is listed again.
        try write()
        let back = removed.reloading(url, as: read(url)).registry
        #expect(back.effect(named: kind.rawValue) != nil && !back.isRetired(kind))
    }

    @Test func aPackageCantTakeAnInstalledID() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write(id: "com.example.tint")
        let elsewhere = try writeEffectPackage(
            effectManifest("com.example.tint", function: "exTint", controls: tint, arguments: ["strength"]),
            kernel: kernel(), in: folder, named: "Other.amveffect"
        )
        let running = EffectRegistry.withBuiltIns([try EffectPackageStore.read(url)])
        let (reloaded, changed) = running.reloading(elsewhere, as: read(elsewhere))
        #expect(changed == nil)
        #expect(reloaded.problems.map(\.message) == ["An effect called \"com.example.tint\" is already installed."])
    }

    @Test func theWatcherNamesThePackagesChanged() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write()
        let watcher = EffectFolderWatcher(folder: folder) { _ in }
        let base = folder.resolvingSymlinksInPath().path
        let packages = watcher.packages(changedAt: [
            base + "/Tint.amveffect/kernel.metal", base + "/Tint.amveffect/effect.json", base + "/New.amveffect",
            base + "/.DS_Store", base + "/Notes.txt", "/elsewhere/Tint.amveffect",
        ])
        #expect(packages.map(\.lastPathComponent) == ["Tint.amveffect", "New.amveffect"])
        // The folder itself, every package in it.
        #expect(watcher.packages(changedAt: [base]).map(\.lastPathComponent) == ["Tint.amveffect"])
        // A folder not made yet, as the Effects folder before the first
        // package, is made to be watched.
        let missing = folder.appending(path: "Effects", directoryHint: .isDirectory)
        withExtendedLifetime(EffectFolderWatcher(folder: missing) { _ in }) {
            #expect(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    @Test @MainActor func theWatcherHearsAKernelSaved() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let heard = AsyncStream<[URL]>.makeStream()
        let watcher = EffectFolderWatcher(folder: folder, latency: 0.05) { heard.continuation.yield($0) }
        try await Task.sleep(for: .milliseconds(200))
        try kernel("return s * strength;").write(to: url.appending(path: "kernel.metal"), atomically: true, encoding: .utf8)
        let first = await withTaskGroup(of: [URL]?.self) { group in
            group.addTask { await heard.stream.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        withExtendedLifetime(watcher) {}
        #expect(first?.map(\.lastPathComponent) == ["Tint.amveffect"])
    }

    @Test @MainActor func aKernelEditedOnDiskIsReloadedAndCompiled() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let registry = RegistryBox(EffectRegistry.withBuiltIns([try EffectPackageStore.read(url)]))
        let status = EffectPackageStatus(reloadingInto: { url, read in registry.reload(url, as: read) })

        try kernel("return s * strength").write(to: url.appending(path: "kernel.metal"), atomically: true, encoding: .utf8)
        await status.reload(url)
        #expect(status.revision == 1)
        #expect(status.kernelProblems["com.example.tint"]?.hasPrefix("kernel.metal:1:") == true)
        #expect(registry.current.effect(named: "com.example.tint")?.package?.kernelSource == kernel("return s * strength"))

        try kernel("return s * strength;").write(to: url.appending(path: "kernel.metal"), atomically: true, encoding: .utf8)
        await status.reload(url)
        #expect(status.revision == 2 && status.kernelProblems["com.example.tint"] == nil)
        // Nothing changed since: nothing is read again.
        await status.reload(url)
        #expect(status.revision == 2)
    }

    @Test @MainActor func aNewerCompileWinsWhicheverFinishesFirst() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = try EffectPackageStore.read(try writeEffectPackage(
            effectManifest("com.example.other", function: "exOther"),
            kernel: "extern \"C\" [[stitchable]] float4 exOther(coreimage::sample_t s, float space) { return s }",
            in: folder, named: "Other.amveffect"
        ))
        let broken = try EffectPackageStore.read(try write(kernel: kernel("return s")))
        let fixed = try EffectPackageStore.read(try write())
        let status = EffectPackageStatus()
        // The launch's compile of every package, then the fixed one
        // installed or reloaded while it runs.
        let launch = Task { await status.compileKernels(of: [other, broken]) }
        await Task.yield()
        await status.compileKernels(of: [fixed])
        await launch.value
        #expect(status.kernelProblems.keys.sorted() == ["com.example.other"])
    }

    @Test func aChangedPackageChangesTheCompositionsKey() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write()
        let before = EffectRegistry.withBuiltIns([try EffectPackageStore.read(url)])
        try write(kernel: kernel("return s * strength;"))
        let after = before.reloading(url, as: read(url)).registry
        var project = EditingProject.empty
        let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
        let shape = try #require(created)
        let keys = [before, after].map { registry in
            EffectRegistry.$override.withValue(registry) {
                var project = project
                project.editClip(shape.clipID, in: project.rootTimelineID) { $0.effects.append(Effect(kind: EffectKind(package: "com.example.tint"))) }
                return StructureKey(composition: CompositionKey(project: project))
            }
        }
        #expect(keys[0] != keys[1])
        _ = project
    }

    @Test func compilingSomePackagesKeepsTheOthersProblems() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fine = try EffectPackageStore.read(try write())
        let status = await EffectPackageStatus(kernelProblems: ["com.example.other": "Broken.", "com.example.tint": "Old."])
        await status.compileKernels(of: [fine])
        #expect(await status.kernelProblems == ["com.example.other": "Broken."])
    }
}

/// A registry of a test's own, changed as `EffectRegistry.reload` changes
/// the one in use.
private final class RegistryBox: Sendable {
    private let registry: Synchronization.Mutex<EffectRegistry>

    init(_ registry: EffectRegistry) { self.registry = Synchronization.Mutex(registry) }

    var current: EffectRegistry { registry.withLock { $0 } }

    func reload(_ url: URL, as read: Result<EffectPackage, any Error>?) -> EffectRegistry.Reload {
        registry.withLock { registry in
            let reloaded = registry.reloading(url, as: read)
            let replaced = reloaded.changed.flatMap { registry.effect(named: $0.id)?.package }
            registry = reloaded.registry
            return EffectRegistry.Reload(changed: reloaded.changed, replaced: replaced)
        }
    }
}
