import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct PackageLookTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-package-looks-\(UUID().uuidString)", directoryHint: .isDirectory)

    private let gain: [String: Any] = ["id": "gain", "name": "Gain", "type": "number", "default": 1, "range": [0, 4]]

    private func package(_ manifest: [String: Any], kernel: String) throws -> EffectPackage {
        let name = (manifest["id"] as! String) + ".amveffect"
        return try EffectPackageStore.read(try writeEffectPackage(manifest, kernel: kernel, in: folder, named: name))
    }

    /// `package`'s look at `settings` (by saved name) drawn on `picture`,
    /// a frame `size` wide, as each pixel's color.
    private func draw(
        _ package: EffectPackage, _ settings: [String: [Double]] = [:], on picture: CIImage, size: CGSize, at seconds: Double = 0
    ) throws -> [SIMD4<Float>] {
        try EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
            var effect = Effect(kind: package.kind)
            for index in effect.controls.indices {
                if let values = settings[effect.controls[index].kind.savedName] {
                    effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
                }
            }
            let step = try #require(LookStep(effect, at: CMTime(seconds: seconds, preferredTimescale: 600)))
            let frame = CGRect(origin: .zero, size: size)
            let drawn = LookRenderer.apply(step, to: picture, over: frame, canvas: frame, frame: frame, scale: 1, space: .rec709)
            var pixels = [SIMD4<Float>](repeating: .zero, count: Int(size.width * size.height))
            CIContext().render(
                drawn, toBitmap: &pixels, rowBytes: Int(size.width) * 16, bounds: frame, format: .RGBAf, colorSpace: nil
            )
            return pixels
        }
    }

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: CGFloat = 4) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: width, height: 1))
    }

    @Test func theLooksThatShipArePackagesThatCompile() {
        #expect(EffectRegistry.builtInPackages.problems.isEmpty)
        #expect(EffectKind.posterize.definition.package != nil)
        for package in EffectRegistry.builtInPackages.packages {
            #expect(PackageKernels.problem(for: package) == nil, "\(package.id)")
        }
        // In the library where it was before it was a package.
        let recolor = EffectKind.all.filter { $0.category == .recolor }.map(\.rawValue)
        #expect(recolor.firstIndex(of: "posterize") == recolor.firstIndex(of: "solarize")! + 1)
    }

    @Test func aColorKernelTakesItsArgumentsAndAmount() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tint: [String: Any] = ["id": "tint", "name": "Tint", "type": "color", "default": [0, 0.5, 1]]
        let look = try package(
            effectManifest("com.example.tint", function: "exTint", controls: [tint, gain], arguments: ["tint", "gain / 2"], extra: ["amount": true]),
            kernel: """
            extern "C" [[stitchable]] float4 exTint(coreimage::sample_t s, float space, float4 tint, float scaled, float amount) {
                return mix(s, float4(tint.rgb * scaled, 1.0), amount);
            }
            """
        )
        let full = try draw(look, ["gain": [2]], on: solid(1, 0, 0), size: CGSize(width: 4, height: 1))
        #expect(close(full[0], SIMD4(0, 0.5, 1, 1)))
        // Amount mixes it in; Amount is the shared control.
        let half = try draw(look, ["gain": [2], "amount": [50]], on: solid(1, 0, 0), size: CGSize(width: 4, height: 1))
        #expect(close(half[0], SIMD4(0.5, 0.25, 0.5, 1)))
    }

    @Test func aGeneralKernelReadsBesideEachPixelWithItsEdgesRepeating() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let shift: [String: Any] = ["id": "shift", "name": "Shift", "type": "number", "default": 1, "unit": "px"]
        let look = try package(
            effectManifest(
                "com.example.shift", function: "exShift", type: "general", controls: [shift], arguments: ["shift * scale"],
                extra: ["reach": "shift * scale", "input": "clamped"]
            ),
            kernel: """
            extern "C" [[stitchable]] float4 exShift(coreimage::sampler s, float space, float dx, coreimage::destination dest) {
                return s.sample(s.transform(dest.coord() + float2(dx, 0.0)));
            }
            """
        )
        let picture = solid(0, 0, 0, width: 2).composited(over: solid(1, 1, 1))
        let drawn = try draw(look, on: picture, size: CGSize(width: 4, height: 1))
        // Each pixel takes the one to its right; the last repeats itself.
        #expect(drawn.map { $0.x.rounded() } == [0, 1, 1, 1])
    }

    @Test func aWarpMovesWherePixelsAreReadFrom() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let look = try package(
            effectManifest("com.example.flip", function: "exFlip", type: "warp", arguments: ["frameWidth"]),
            kernel: """
            extern "C" [[stitchable]] float2 exFlip(float width, coreimage::destination dest) {
                float2 c = dest.coord();
                return float2(width - c.x, c.y);
            }
            """
        )
        let picture = solid(0, 0, 0, width: 1).composited(over: solid(1, 1, 1))
        #expect(try draw(look, on: picture, size: CGSize(width: 4, height: 1)).map { $0.x.rounded() } == [1, 1, 1, 0])
    }

    @Test func aFilterAfterTheKernelIsAppliedWhileItsConditionHolds() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let look = try package(
            effectManifest(
                "com.example.invert", function: "exSame", controls: [gain],
                extra: ["after": [["filter": "CIColorInvert", "when": "gain > 1"]]]
            ),
            kernel: """
            extern "C" [[stitchable]] float4 exSame(coreimage::sample_t s, float space) { return s; }
            """
        )
        #expect(try draw(look, on: solid(1, 0, 0), size: CGSize(width: 4, height: 1))[0].x.rounded() == 1)
        #expect(try draw(look, ["gain": [2]], on: solid(1, 0, 0), size: CGSize(width: 4, height: 1))[0].x.rounded() == 0)
    }

    @Test func aFilterCanReadThePictureWithItsEdgesRepeating() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        func blur(_ extra: [String: Any]) throws -> EffectPackage {
            let filter: [String: Any] = ["filter": "CIBoxBlur", "parameters": ["inputRadius": "3"]].merging(extra) { $1 }
            return try package(
                effectManifest("com.example.box\(extra.isEmpty ? "" : "Clamped")", function: "exSame", extra: ["after": [filter]]),
                kernel: "extern \"C\" [[stitchable]] float4 exSame(coreimage::sample_t s, float space) { return s; }"
            )
        }
        // Read as transparent past them, the edges fade; repeating, they
        // stay as they were.
        let faded = try draw(blur([:]), on: solid(1, 0, 0, width: 8), size: CGSize(width: 8, height: 1))
        #expect(faded[0].w < 0.9)
        let repeated = try draw(blur(["input": "clamped"]), on: solid(1, 0, 0, width: 8), size: CGSize(width: 8, height: 1))
        #expect(close(repeated[0], SIMD4(1, 0, 0, 1)))
    }

    @Test func aKernelThatDoesNotCompileLeavesThePictureAndSaysWhy() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = try package(
            effectManifest("com.example.broken", function: "exBroken"),
            kernel: "extern \"C\" [[stitchable]] float4 exBroken(coreimage::sample_t s, float space) { return nope; }"
        )
        // Not compiled until something asks for the kernel; a view asking
        // only reads what is known.
        #expect(PackageKernels.knownProblem(for: broken) == nil)
        // The compiler's own words, at the line in the package's file.
        let problem = try #require(PackageKernels.problem(for: broken))
        #expect(problem.hasPrefix("kernel.metal:1:"))
        #expect(problem.contains("use of undeclared identifier 'nope'"))
        #expect(PackageKernels.knownProblem(for: broken) == problem)
        #expect(try draw(broken, on: solid(1, 0, 0), size: CGSize(width: 4, height: 1))[0] == SIMD4(1, 0, 0, 1))

        let mislabeled = try package(
            effectManifest("com.example.mislabeled", function: "exWarp", type: "color"),
            kernel: "extern \"C\" [[stitchable]] float2 exWarp(coreimage::destination dest) { return dest.coord(); }"
        )
        #expect(PackageKernels.problem(for: mislabeled) == "exWarp is a warp kernel, not the color kernel effect.json says.")
    }

    @Test func aChangedPackageDrawsUnderANewRenderKey() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = effectManifest("com.example.same", function: "exSame")
        let first = try package(manifest, kernel: "extern \"C\" [[stitchable]] float4 exSame(coreimage::sample_t s, float space) { return s; }")
        let second = try package(manifest, kernel: "extern \"C\" [[stitchable]] float4 exSame(coreimage::sample_t s, float space) { return s.gbra; }")
        #expect(first.contentHash != second.contentHash)
        func key(_ package: EffectPackage) throws -> String {
            try EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([package])) {
                try #require(LookStep(Effect(kind: package.kind), at: .zero)).keyText
            }
        }
        #expect(try key(first) != key(second))
        #expect(try key(first).hasPrefix("com.example.same@1#\(first.contentHash) "))
    }

    @Test func aPackageLookMovesOnItsOwnWhileARateIsNotZero() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let speed: [String: Any] = ["id": "speed", "name": "Speed", "type": "number", "default": 0, "unit": "/s", "rate": true]
        let kernel = "extern \"C\" [[stitchable]] float4 exSame(coreimage::sample_t s, float space, float t) { return s; }"
        let moving = try package(effectManifest("com.example.moving", function: "exSame", controls: [speed], arguments: ["speed * seconds"]), kernel: kernel)
        let grainy = try package(
            effectManifest("com.example.grainy", function: "exSame", arguments: ["frame"], extra: ["changesEveryFrame": true]), kernel: kernel
        )
        EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([moving, grainy])) {
            var effect = Effect(kind: moving.kind)
            #expect(!effect.changesOnItsOwn)
            effect.controls[0].number = AnimatedValue(ComponentValue(values: [0.5]))
            #expect(effect.changesOnItsOwn)
            effect.controls[0].enabled = false
            #expect(!effect.changesOnItsOwn)
            #expect(Effect(kind: grainy.kind).changesOnItsOwn)
        }
    }

    @Test func theLibraryHearsWhichKernelsDontCompile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = try package(
            effectManifest("com.example.fine", function: "exFine"),
            kernel: "extern \"C\" [[stitchable]] float4 exFine(coreimage::sample_t s, float space) { return s; }"
        )
        let broken = try package(
            effectManifest("com.example.unfinished", function: "exUnfinished"),
            kernel: "extern \"C\" [[stitchable]] float4 exUnfinished(coreimage::sample_t s, float space) {\n    return s\n}"
        )
        let status = await EffectPackageStatus()
        await status.compileKernels(of: [good, broken])
        let problems = await status.kernelProblems
        #expect(problems.keys.sorted() == ["com.example.unfinished"])
        #expect(problems["com.example.unfinished"]?.hasPrefix("kernel.metal:2:") == true)

        // The effects panel says so under the effect.
        try EffectRegistry.$override.withValue(EffectRegistry.withBuiltIns([good, broken])) {
            var project = EditingProject.empty
            let created = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
            let shape = try #require(created)
            project.editClip(shape.clipID, in: project.rootTimelineID) { $0.effects.append(Effect(kind: broken.kind)) }
            let (clip, layer) = try #require(project.clipAndLayer(shape.clipID, in: project.rootTimelineID))
            let timeline = try #require(project.timelines.first)
            let note = project.note(forEffectAt: clip.effects.count - 1, in: clip, on: layer, of: timeline)
            #expect(note?.dims == true)
            #expect(note?.text.hasPrefix("Its kernel doesn't compile, so it leaves the picture as it is. kernel.metal:2:") == true)
        }
    }
}
