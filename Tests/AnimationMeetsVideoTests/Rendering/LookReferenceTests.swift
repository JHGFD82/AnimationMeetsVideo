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
        /// By case: "defaults", "choice:<control>=<option>" for each option
        /// of each choice but its default, and "tweaked" for a look with
        /// `tweaks`.
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

    /// Looks whose pixels near the frame's edges hang on what is past
    /// them, which Core Image doesn't draw alike on every macOS (Neon
    /// Edges' clamped input and its glow differed on macOS 27 at the
    /// edges only). Each is drawn on a larger frame of colored blocks, so
    /// it has edges to find, and compared only `margin` pixels in from the
    /// edges: further than changing the outermost pixels from black to
    /// white moves any pixel by more than 0.0001 at its defaults.
    private static let framed: [String: (size: CGSize, margin: Int)] = [
        "neonEdges": (CGSize(width: 96, height: 80), 32),
    ]

    private func harness(for name: String) throws -> CompositorHarness {
        guard let framed = Self.framed[name] else { return try harness() }
        var harness = CompositorHarness(size: framed.size)
        try harness.addPicture(track: 1) { x, y in
            SIMD4(Int(x * 12) % 2 == 0 ? 0.15 : 0.85, Int(y * 10) % 2 == 0 ? 0.25 : 0.75, Float((x * 4).truncatingRemainder(dividingBy: 1)), 1)
        }
        return harness
    }

    /// The pixels of `frame`, `size` across, at least `margin` in from
    /// every edge, read from the top.
    private static func inside(_ frame: [SIMD4<Float>], size: CGSize, margin: Int) -> [SIMD4<Float>] {
        let width = Int(size.width), height = Int(size.height)
        return (margin..<(height - margin)).flatMap { y in (margin..<(width - margin)).map { x in frame[y * width + x] } }
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

    /// The look's effect at its defaults, with each option of each choice
    /// (which checks how a choice becomes a kernel argument), and with its
    /// tweaks.
    private func effects(_ kind: EffectKind) -> [String: Effect] {
        let effect = Effect(kind: kind)
        var cases = ["defaults": effect]
        for index in effect.controls.indices where effect.controls[index].kind.isChoice {
            let control = effect.controls[index]
            for option in control.kind.choiceOptions where option.id != control.choice {
                var chosen = effect
                chosen.controls[index].choice = option.id
                cases["choice:\(control.kind.savedName)=\(option.id)"] = chosen
            }
        }
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
        let h = try harness(for: name)
        let framed = Self.framed[name]
        var drawn: [String: [SIMD4<Float>]] = [:]
        for (label, effect) in effects(kind) {
            let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size)
            let frame = try h.draw([clip], at: Self.time)
            drawn[label] = framed.map { Self.inside(frame, size: $0.size, margin: $0.margin) } ?? frame
        }
        let width = framed.map { Int($0.size.width) - 2 * $0.margin } ?? 16
        try Self.check(name, drawn, width: width)
    }

    /// Records `drawn` as look `name`'s references, or compares it with
    /// them.
    static func check(_ name: String, _ frames: [String: [SIMD4<Float>]], width: Int = 16) throws {
        let drawn = frames.mapValues { $0.map { [$0.x, $0.y, $0.z, $0.w].map { ($0 * 100_000).rounded() / 100_000 } } }
        let url = folder.appending(path: "\(name).json")
        if recording {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Reference(cases: drawn)).write(to: url)
            return
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(Set(reference.cases.keys) == Set(drawn.keys))
        for (label, pixels) in reference.cases {
            let now = try #require(drawn[label])
            let differences = zip(pixels, now).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }
            let worst = differences.max() ?? 0
            // Where, and what each held, to tell a GPU's rounding from a
            // real change: `width` pixels across, read from the top.
            let at = differences.firstIndex(of: worst) ?? 0
            let place = "pixel \(at % width), \(at / width): recorded \(pixels.indices.contains(at) ? pixels[at] : []), drawn \(now.indices.contains(at) ? now[at] : [])"
            #expect(worst <= 0.002, "\(name) \(label) differs by \(worst) at \(place)")
        }
    }
}

/// The looks drawn from pictures besides the one reaching them, which
/// docs/effect-packages.md ("Pictures besides the clip's") moves into
/// packages: Displace from a map or an earlier step's picture, Feedback
/// and Slit-Scan from earlier moments, Flow Smear from a frame ahead. Each
/// picture differs, so a moment or a role taken for another shows.
@Suite struct PicturedLookReferenceTests {
    private static let size = CGSize(width: 32, height: 16)
    private static let frame = CMTime(value: 1, timescale: 24)
    private static let time = CMTime(value: 1, timescale: 1)
    /// The earlier moments there are pictures for, in frames: enough for
    /// Slit-Scan's default bands, half a second across.
    private static let earliest = 12
    private static let aheadTrack = CMPersistentTrackID(earliest + 2)
    private static let mapTrack = CMPersistentTrackID(earliest + 3)

    /// The footage at `x` across and `y` down: a sweep with a checker of
    /// 4-pixel squares in blue, the texture Flow Smear's motion is found in.
    private static func footage(_ x: Double, _ y: Double, dim: Double = 1) -> SIMD4<Float> {
        let checker = (Int((x * size.width / 4).rounded(.down)) + Int((y * size.height / 4).rounded(.down))) % 2
        return SIMD4(Float(x), Float(y * dim), Float(0.2 + 0.6 * Double(checker)), 1)
    }

    /// Track 1 the footage now, 2 on the footage `k` frames earlier, each
    /// moved and dimmed a little more; then a frame ahead, moved 2 pixels
    /// right; then a map for Displace.
    private func harness() throws -> CompositorHarness {
        var h = CompositorHarness(size: Self.size)
        try h.addPicture(track: 1) { x, y in Self.footage(x, y) }
        for k in 1...Self.earliest {
            let shift = 0.03 * Double(k), dim = 1 - 0.04 * Double(k)
            try h.addPicture(track: CMPersistentTrackID(k + 1)) { x, y in
                Self.footage((x + shift).truncatingRemainder(dividingBy: 1), y, dim: dim)
            }
        }
        try h.addPicture(track: Self.aheadTrack) { x, y in Self.footage(x - 2 / Self.size.width, y) }
        try h.addPicture(track: Self.mapTrack) { x, y in
            SIMD4(Float(0.5 + 0.4 * sin(4 * .pi * x)), Float(0.5 + 0.4 * cos(4 * .pi * y)), 0.5, 1)
        }
        return h
    }

    private func copy(_ track: CMPersistentTrackID, delay: CMTime = .zero) -> TrackCopy {
        TrackCopy(trackID: track, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), strength: 1, delay: delay)
    }

    /// The footage with `effects`, its earlier moments, the frame ahead,
    /// and the map as the input of any effect that takes one.
    private func clip(_ effects: [Effect]) -> DrawClip {
        var media = MediaDraw(
            trackID: 1, base: .identity, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero,
            frameDuration: Self.frame
        )
        media.moments = (1...Self.earliest).map { copy(CMPersistentTrackID($0 + 1), delay: CMTimeMultiply(Self.frame, multiplier: Int32($0))) }
        media.ahead = copy(Self.aheadTrack)
        var timelineClip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        timelineClip.effects = effects
        let center = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2)
        let stack = ClipStack(clip: timelineClip, center: center, shift: .zero, frameDuration: Self.frame)
        var clip = DrawClip(content: .media(media), stack: stack, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), owner: UUID())
        for effect in effects where effect.input != nil {
            clip.inputs[effect.id] = .track(copy(Self.mapTrack), base: .identity)
        }
        return clip
    }

    private func draw(_ effects: [Effect], playing: Bool = false) throws -> [SIMD4<Float>] {
        let options = DrawingOptions()
        options.update(isPlaying: playing)
        return try harness().draw([clip(effects)], at: Self.time, options: options)
    }

    private func withMap(_ effect: Effect) -> Effect {
        var effect = effect
        effect.input = EffectInput(source: .asset(UUID()))
        return effect
    }

    @Test func displaceDrawsAsItWasRecorded() throws {
        // Against an earlier step: the picture before it moved by the one
        // after it.
        let brighter = look(.color, ["exposure": [1]])
        var against = look(.displace, ["displacement": [20]])
        against.against = brighter.id
        try LookReferenceTests.check("displace", [
            "defaults": try draw([withMap(look(.displace))]),
            "tweaked": try draw([withMap(look(.displace, ["displacement": [20]]))]),
            "choice:mapCenter=black": try draw([withMap(look(.displace, ["displacement": [20]], choices: ["mapCenter": "black"]))]),
            "against": try draw([brighter, against]),
        ])
    }

    @Test func feedbackDrawsAsItWasRecorded() throws {
        let tweaked = look(.feedback, [
            "copies": [3], "feedbackDelay": [2], "copyScale": [90], "copyRotation": [-10], "hueStep": [60], "copyDecay": [50],
        ])
        try LookReferenceTests.check("feedback", [
            "defaults": try draw([look(.feedback)]),
            "playing": try draw([look(.feedback)], playing: true),
            "tweaked": try draw([tweaked]),
            "tweaked:playing": try draw([tweaked], playing: true),
        ])
    }

    @Test func slitScanDrawsAsItWasRecorded() throws {
        let tweaked = look(.slitScan, ["bands": [4], "timeSpread": [0.125]])
        try LookReferenceTests.check("slitScan", [
            "defaults": try draw([look(.slitScan)]),
            "playing": try draw([look(.slitScan)], playing: true),
            "choice:slitDirection=columns": try draw([look(.slitScan, choices: ["slitDirection": "columns"])]),
            "choice:slitDirection=rings": try draw([look(.slitScan, choices: ["slitDirection": "rings"])]),
            "tweaked": try draw([tweaked]),
        ])
    }

    @Test func flowSmearDrawsAsItWasRecorded() throws {
        try LookReferenceTests.check("flowSmear", [
            "defaults": try draw([look(.flowSmear)]),
            "playing": try draw([look(.flowSmear)], playing: true),
            "tweaked": try draw([look(.flowSmear, ["smear": [300]])]),
        ])
    }
}
