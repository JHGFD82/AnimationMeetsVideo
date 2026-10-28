import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Reading a package's curve controls, curve pictures and tone graph (see
/// docs/effect-packages.md, "Curves" and "Graph").
@Suite struct ToneGraphPackageTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "amv-tone-graphs-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A curve, a number and a choice; a general kernel reading only its
    /// pixel, with the curve's table; a graph with the curve and a handle.
    private var tone: [String: Any] {
        effectManifest(
            "com.example.tone", function: "exTone", type: "general",
            controls: [
                ["id": "shape", "name": "Shape", "type": "curve", "default": [[0, 0.1], [1, 0.9]], "tint": "red"],
                ["id": "level", "name": "Level", "type": "number", "default": 50, "range": [0, 100], "unit": "%"],
                [
                    "id": "mode", "name": "Mode", "type": "choice", "default": "a",
                    "options": [["id": "a", "name": "A"], ["id": "b", "name": "B"]],
                ],
            ],
            arguments: ["level / 100"],
            extra: [
                "category": "correction", "perPixel": true,
                "pictures": [["id": "table", "from": "curve", "control": "shape"]],
                "graph": [
                    "curves": ["shape"],
                    "handles": [["name": "Level", "x": "level / 100", "y": "pow(level / 100, 2)", "set": ["level": "x * 100"]]],
                ],
            ]
        )
    }

    private let kernel = """
    extern "C" [[stitchable]] float4 exTone(coreimage::sampler s, float space, coreimage::sampler table, float level) {
        float4 p = s.sample(s.coord());
        return float4(curveTone(table, p.r), p.g, p.b, p.a);
    }
    """

    private func read(_ manifest: [String: Any], kernel: String? = nil) throws -> EffectPackage {
        let url = try writeEffectPackage(manifest, kernel: kernel ?? self.kernel, in: folder, named: "Tone.amveffect")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try EffectPackageStore.read(url)
    }

    private func problem(_ manifest: [String: Any], kernel: String? = nil) -> String? {
        do {
            _ = try read(manifest, kernel: kernel)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func aCurveControlAndItsGraphAreRead() throws {
        let package = try read(tone)
        let shape = try #require(package.controls.first)
        #expect(shape.isCurve && shape.curveTint == .red)
        #expect(shape.defaultValues == [0, 0.1, 1, 0.9])
        #expect(package.pictures.first?.source == .curve)
        #expect(package.pictures.first?.control == shape.kind)
        // It reads only its own pixel, so it doesn't read beside.
        #expect(package.readsOnlyItsPixel)
        #expect(PackageKernels.problem(for: package) == nil)
        let graph = try #require(package.graph)
        #expect(graph.curves == [shape.kind])
        #expect(!graph.showsResponse)
        let handle = try #require(graph.handles.first)
        #expect(handle.name == "Level" && handle.movesAcross && !handle.movesUp)
    }

    @Test func problemsSayWhereTheyAre() {
        func changed(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var manifest = tone
            change(&manifest)
            return manifest
        }
        func control(_ key: String, _ value: Any) -> [String: Any] {
            changed {
                var controls = $0["controls"] as! [[String: Any]]
                controls[0][key] = value
                $0["controls"] = controls
            }
        }
        func handle(_ key: String, _ value: Any) -> [String: Any] {
            changed {
                var graph = $0["graph"] as! [String: Any]
                var handles = graph["handles"] as! [[String: Any]]
                handles[0][key] = value
                graph["handles"] = handles
                $0["graph"] = graph
            }
        }
        let cases: [([String: Any], String)] = [
            (control("default", [[0.5, 0], [0.2, 1]]),
             "A curve's points go from left to right, at least 0.01 apart, within 0 to 1, two or more at controls[0].default."),
            (control("default", [[0, 0, 1]]), "Expected a list of 2 numbers at controls[0].default[0]."),
            (control("tint", "purple"), "Unknown tint \"purple\" at controls[0].tint."),
            (changed { $0["arguments"] = ["shape"] }, "\"shape\" is a curve; a kernel reads it as a picture from it at arguments[0]."),
            (changed { $0["pictures"] = [["id": "table", "from": "curve"]] },
             "A curve names the curve control it is made from at pictures[0]."),
            (changed { $0["pictures"] = [["id": "table", "from": "curve", "control": "level"]] },
             "\"level\" isn't one of its curve controls at pictures[0].control."),
            (changed { $0["pictures"] = [["id": "map", "from": "input", "control": "shape"]] },
             "Only a curve is made from a control at pictures[0].control."),
            (changed { $0["graph"] = ["curves": ["level"]] }, "\"level\" isn't one of its curve controls at graph.curves[0]."),
            (handle("set", ["mode": "x"]), "\"mode\" isn't one of its number controls at graph.handles[0].set.mode."),
            (handle("set", [String: Any]()), "Expected an object naming the controls a drag sets at graph.handles[0].set."),
            (handle("x", "x * 100"), "Unknown name \"x\" at graph.handles[0].x."),
            (handle("set", ["level": "z"]), "Unknown name \"z\" at graph.handles[0].set.level."),
            (changed { $0["reach"] = "2" },
             "A kernel that reads only its own pixel reads nothing beside it, so it has no reach or input at perPixel."),
            (changed { $0["kernel"] = ["file": "kernel.metal", "function": "exTone", "type": "color"]; $0["pictures"] = nil },
             "Only a general kernel says it reads only its own pixel; a color kernel always does at perPixel."),
        ]
        for (manifest, message) in cases {
            #expect(problem(manifest) == "The package can't be used. " + message)
        }
        // Several curves may each have a table.
        #expect(problem(changed {
            var controls = $0["controls"] as! [[String: Any]]
            controls.append(["id": "other", "name": "Other", "type": "curve"])
            $0["controls"] = controls
            $0["pictures"] = [["id": "table", "from": "curve", "control": "shape"], ["id": "more", "from": "curve", "control": "other"]]
        }, kernel: kernel.replacingOccurrences(of: "coreimage::sampler table,", with: "coreimage::sampler table, coreimage::sampler more,")) == nil)
    }

    @Test func expressionsCanRaiseToAPowerAndTakeALogarithm() throws {
        struct None: EffectExpression.Values {
            func value(_ name: String) -> [Double] { [0] }
            func center(_ name: String) -> [Double] { [0, 0] }
            func index(_ name: String) -> Double { 0 }
        }
        #expect(try EffectExpression("pow(2, 10)", names: [:]).number(None()) == 1024)
        #expect(abs(try EffectExpression("log(pow(0.5, 3)) / log(0.5)", names: [:]).number(None()) - 3) < 1e-12)
        // Never a number that isn't one.
        #expect(try EffectExpression("log(0)", names: [:]).number(None()) == 0)
        #expect(try EffectExpression("pow(0 - 8, 0.5)", names: [:]).number(None()) == 0)
    }
}
