import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Each look moving into an effect package (docs/effect-packages.md) drawn
/// against frames recorded before it moved, so the package draws what the
/// Swift did. Run with `RECORD_LOOK_REFERENCES=1` to record them again,
/// into LookReferences/ beside this file.
@Suite struct LookReferenceTests {
    static let kinds = [
        "hueCycle", "cosinePalette", "gradientMap", "solarize", "posterize", "channelMixer", "falseColor", "neonEdges",
        "grain", "staticNoise", "fractalNoise", "cells", "dither", "interference", "blockGlitch",
        "liquid", "twirl", "wave", "kaleidoscope", "mirrorTile", "chromaticAberration",
    ]

    private static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "LookReferences")
    private static let recording = ProcessInfo.processInfo.environment["RECORD_LOOK_REFERENCES"] != nil
    private static let time = CMTime(seconds: 0.75, preferredTimescale: 600)

    private struct Reference: Codable {
        /// By case: "defaults", "lastChoices" for a look with choices, and
        /// "tweaked" for one with `tweaks`.
        var cases: [String: [[Float]]]
    }

    /// A sweep of colors and brightness, so every look has something to
    /// change everywhere.
    private func harness() throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: 16, height: 8))
        try harness.addPicture(track: 1) { x, y in
            SIMD4(Float(x), Float(y), Float(1 - x * y), 1)
        }
        return harness
    }

    /// Settings, by control, sized for this small frame where a look's
    /// defaults (made for a full-size one) change little or nothing.
    private static let tweaks: [String: [String: [Double]]] = [
        "blockGlitch": ["blockSize": [4], "intensity": [100], "glitchRate": [7]],
        "channelMixer": ["mixRed": [0.2, 0.9, 0.1], "mixOffset": [0.1, 0, -0.1]],
        "mirrorTile": ["tileSize": [6]],
        "wave": ["wavelength": [6], "waveHeight": [2]],
        "twirl": ["distortRadius": [6]],
        "kaleidoscope": ["distortCenter": [3, -2]],
        "cells": ["cellSize": [4]],
        "liquid": ["noiseScale": [6], "displacement": [20]],
        "chromaticAberration": ["aberration": [10]],
        "fractalNoise": ["noiseScale": [6]],
        "interference": ["spacing": [2]],
        "neonEdges": ["edgeWidth": [1]],
        "posterize": ["levels": [3], "amount": [40]],
    ]

    /// The look's effect at its defaults, with every choice at its last
    /// option, and with its tweaks.
    private func effects(_ kind: EffectKind) -> [String: Effect] {
        let effect = Effect(kind: kind)
        var cases = ["defaults": effect]
        var last = effect
        for index in last.controls.indices where last.controls[index].kind.isChoice {
            last.controls[index].choice = last.controls[index].kind.choiceOptions.last?.id
        }
        if last != effect { cases["lastChoices"] = last }
        if let tweaks = Self.tweaks[kind.rawValue] {
            var tweaked = effect
            for index in tweaked.controls.indices {
                if let values = tweaks[tweaked.controls[index].kind.savedName] {
                    tweaked.controls[index].number = AnimatedValue(ComponentValue(values: values))
                }
            }
            cases["tweaked"] = tweaked
        }
        return cases
    }

    @Test(arguments: kinds) func aLookDrawsAsItWasRecorded(_ name: String) throws {
        let kind = try #require(EffectKind(rawValue: name))
        let h = try harness()
        var drawn: [String: [[Float]]] = [:]
        for (label, effect) in effects(kind) {
            let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size)
            drawn[label] = try h.draw([clip], at: Self.time).map { [$0.x, $0.y, $0.z, $0.w].map { ($0 * 100_000).rounded() / 100_000 } }
        }
        let url = Self.folder.appending(path: "\(name).json")
        if Self.recording {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Reference(cases: drawn)).write(to: url)
            return
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(Set(reference.cases.keys) == Set(drawn.keys))
        for (label, pixels) in reference.cases {
            let now = try #require(drawn[label])
            let worst = zip(pixels, now).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
            #expect(worst <= 0.002, "\(name) \(label) differs by \(worst)")
        }
    }
}
