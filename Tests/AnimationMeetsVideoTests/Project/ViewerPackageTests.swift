import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Reading a package's `viewer` key: the handles and guides the viewer
/// shows while the effect is selected (see docs/effect-packages.md,
/// "Viewer").
@Suite struct ViewerPackageTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-viewer-packages-\(UUID().uuidString)", directoryHint: .isDirectory)

    private let kernel = """
    extern "C" [[stitchable]] float4 exSpot(coreimage::sample_t s, float space, float2 middle, float2 size, float angle) { return s; }
    """

    private func manifest(viewer: [String: Any]) -> [String: Any] {
        effectManifest(
            "com.example.spot", function: "exSpot",
            controls: [
                ["id": "middle", "name": "Center", "type": "point"],
                ["id": "size", "name": "Size", "type": "vector", "components": ["Width", "Height"], "default": [200, 100]],
                ["id": "angle", "name": "Angle", "type": "number", "default": 0, "unit": "°"],
            ],
            arguments: ["center(middle)", "size", "rad(angle)"],
            extra: ["viewer": viewer]
        )
    }

    private var spot: [String: Any] {
        manifest(viewer: [
            "handles": [
                ["name": "Width", "x": "middle.x + size.x / 2", "y": "middle.y", "set": ["size.x": "2 * abs(x - middle.x)"]],
                ["name": "Angle", "x": "middle.x", "y": "middle.y - 80", "set": ["angle": "deg(atan2(y - middle.y, x - middle.x)) + 90"]],
            ],
            "guides": [
                ["ellipse": ["center": "middle", "size": "size", "angle": "angle"]],
                ["line": ["middle", ["middle.x", "middle.y - 80"]]],
                ["polygon": [["0", "0"], ["10", "0"], ["10", "10"]]],
                ["rectangle": ["center": ["0", "0"], "size": "size"]],
            ],
        ])
    }

    private func read(_ manifest: [String: Any]) throws -> EffectPackage {
        let url = try writeEffectPackage(manifest, kernel: kernel, in: folder, named: "Spot.amveffect")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try EffectPackageStore.read(url)
    }

    private func problem(_ viewer: [String: Any]) -> String? {
        do {
            _ = try read(manifest(viewer: viewer))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func handlesAndGuidesAreRead() throws {
        let viewer = try #require(try read(spot).viewer)
        #expect(viewer.handles.map(\.name) == ["Width", "Angle"])
        let width = viewer.handles[0]
        #expect(width.sets.count == 1 && width.sets[0].component == 0 && width.sets[0].control.savedName == "size")
        #expect(width.movesAcross && !width.movesDown)
        #expect(viewer.handles[1].sets[0].component == nil)
        #expect(viewer.guides.count == 4)
    }

    @Test func aWholeVectorIsSetAPartAtATime() {
        let message = problem(["handles": [["name": "Size", "x": "0", "y": "0", "set": ["size": "x"]]]])
        #expect(message?.contains("size.x") == true)
        #expect(problem(["handles": [["name": "Size", "x": "0", "y": "0", "set": ["size.z": "x"]]]])?.contains("no part") == true)
        #expect(problem(["handles": [["name": "Size", "x": "0", "y": "0", "set": ["angle.x": "x"]]]]) != nil)
        #expect(problem(["handles": [["name": "Size", "x": "0", "y": "0", "set": ["missing": "x"]]]]) != nil)
    }

    @Test func placesAreNumbersAndGuidesAreKnown() {
        #expect(problem(["handles": [["name": "A", "x": "size", "y": "0", "set": ["angle": "x"]]]]) != nil)
        #expect(problem(["guides": [["line": ["middle"]]]]) != nil)
        #expect(problem(["guides": [["line": ["angle", "middle"]]]]) != nil)
        #expect(problem(["guides": [["circle": ["center": "middle"]]]])?.contains("isn't a guide") == true)
        #expect(problem(["guides": [["ellipse": ["center": "middle"]]]]) != nil)
        #expect(problem(["guides": [["polygon": ["middle", "middle"], "line": ["middle", "middle"]]]]) != nil)
    }

    @Test func aHandleReadsXAndYOnlyInItsSets() {
        #expect(problem(["handles": [["name": "A", "x": "x", "y": "0", "set": ["angle": "x"]]]]) != nil)
    }

    @Test func theShippedDeclarationsLoad() {
        for id in ["spotlight", "ellipseMask", "rectangleMask", "fourPointMask", "gradientMask"] {
            let kind = EffectKind(rawValue: id)
            #expect(kind?.definition.package?.viewer != nil, "\(id)")
        }
    }
}
