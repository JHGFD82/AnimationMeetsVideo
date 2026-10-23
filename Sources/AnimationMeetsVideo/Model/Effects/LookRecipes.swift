import CoreMedia
import Foundation

/// The starting stacks of docs/psychedelic-effects.md ("Recipes"), installed
/// once into the Presets folder (`PresetStore.installRecipes`), where they
/// are presets like any other. Each works on footage, or over a black clip
/// as generated footage. Blending and Displace steps read the effects they
/// name by ID within the stack, which a paste keeps.
enum LookRecipes {
    /// Bumped when the recipes change, so an update installs the new ones.
    static let version = 1

    static var all: [(name: String, bundle: EffectBundle)] {
        [
            ("Liquid Acid", liquidAcid), ("Infinite Tunnel", infiniteTunnel), ("Lava Lamp", lavaLamp),
            ("Noise Melt", noiseMelt), ("Electric Cells", electricCells), ("Broken Signal", brokenSignal),
            ("Melting Rainbow", meltingRainbow), ("Oil Slick", oilSlick), ("Thermal Dream", thermalDream),
            ("Eightfold Mandala", eightfoldMandala), ("Moiré Breathing", moireBreathing),
        ].map { ($0.0, EffectBundle(effects: $0.1.map { EffectBundle.Effect(effect: $0) }, origin: .zero)) }
    }

    // MARK: Building

    /// A new effect of `kind` with some controls set: numbers, choices, or
    /// keyframes as (seconds, values) pairs.
    private static func effect(
        _ kind: EffectKind, _ numbers: [ControlKind: [Double]] = [:], choices: [ControlKind: String] = [:],
        keyframes: [ControlKind: [(Double, [Double])]] = [:]
    ) -> Effect {
        var effect = Effect(kind: kind)
        for index in effect.controls.indices {
            let control = effect.controls[index].kind
            if let values = numbers[control] { effect.controls[index].number = AnimatedValue(ComponentValue(values: values)) }
            if let choice = choices[control] { effect.controls[index].choice = choice }
            if let frames = keyframes[control] {
                effect.controls[index].number = AnimatedValue(
                    ComponentValue(values: frames[0].1),
                    keyframes: frames.map {
                        Keyframe(time: CMTime(seconds: $0.0, preferredTimescale: 600), value: ComponentValue(values: $0.1), easeIn: .easy, easeOut: .easy)
                    }
                )
            }
        }
        return effect
    }

    /// A new effect of `kind` with controls set by the names they are saved
    /// under, for a look from a package, whose controls have no Swift names.
    private static func look(
        _ kind: EffectKind, _ numbers: [String: [Double]] = [:], choices: [String: String] = [:],
        keyframes: [String: [(Double, [Double])]] = [:]
    ) -> Effect {
        func byKind<Value>(_ named: [String: Value]) -> [ControlKind: Value] {
            Dictionary(uniqueKeysWithValues: named.compactMap { name, value in kind.controlKind(savedAs: name).map { ($0, value) } })
        }
        return effect(kind, byKind(numbers), choices: byKind(choices), keyframes: byKind(keyframes))
    }

    /// Blending in `mode` against the picture before `earlier`.
    private static func blend(_ mode: BlendMode, against earlier: Effect) -> Effect {
        var blending = effect(.blending, choices: [.mode: mode.rawValue])
        blending.against = earlier.id
        return blending
    }

    // MARK: Recipes

    private static var liquidAcid: [Effect] {
        let liquid = effect(.liquid)
        return [
            liquid, look(.cosinePalette, choices: ["palette": "acid"]), effect(.hueCycle),
            blend(.softLight, against: liquid),
        ]
    }

    private static var infiniteTunnel: [Effect] {
        [
            look(.kaleidoscope, ["segments": [8]]),
            effect(.feedback, [.copies: [12], .copyScale: [103], .copyRotation: [4], .hueStep: [15]]),
            effect(.chromaticAberration), effect(.grain),
        ]
    }

    private static var lavaLamp: [Effect] {
        [
            look(.fractalNoise, choices: ["noiseType": "smooth"]), effect(.liquid),
            look(.gradientMap, ["scrollSpeed": [0.05]]),
        ]
    }

    private static var noiseMelt: [Effect] {
        let noise = look(.fractalNoise, choices: ["noiseType": "turbulent"])
        var displace = look(.displace, ["displacement": [4]])
        displace.against = noise.id
        return [noise, displace, effect(.hueCycle), effect(.grain)]
    }

    private static var electricCells: [Effect] {
        let cells = look(.cells, choices: ["cellOutput": "edges"])
        return [cells, effect(.neonEdges), look(.hueCycle, ["hueSpread": [120]]), blend(.screen, against: cells)]
    }

    private static var brokenSignal: [Effect] {
        let interference = effect(.interference)
        return [
            effect(.blockGlitch), look(.chromaticAberration, choices: ["aberrationMode": "linear"]),
            interference, blend(.overlay, against: interference), look(.staticNoise, ["amount": [15]]),
        ]
    }

    private static var meltingRainbow: [Effect] {
        [
            effect(.flowSmear), look(.solarize, ["folds": [3]]), effect(.hueCycle),
            effect(.feedback, [.copies: [6], .copyScale: [100], .copyRotation: [0], .hueStep: [30]]),
        ]
    }

    private static var oilSlick: [Effect] {
        let wave = look(.wave, choices: ["waveDirection": "radial"])
        return [
            wave, look(.twirl, choices: ["twirlShape": "vortex"]),
            look(.cosinePalette, choices: ["palette": "oilSlick"]), blend(.luminosity, against: wave),
        ]
    }

    private static var thermalDream: [Effect] {
        [
            look(.falseColor, choices: ["falseColorLook": "thermal"]),
            effect(.slitScan, choices: [.slitDirection: SlitDirection.rows.rawValue]), look(.posterize, ["levels": [5]]),
            effect(.grain),
        ]
    }

    private static var eightfoldMandala: [Effect] {
        [
            look(.mirrorTile, choices: ["tilePattern": "eightfold"]), look(.kaleidoscope, ["segments": [12]]),
            // Each channel from the next: red from green, green from blue,
            // blue from red.
            look(.channelMixer, ["mixRed": [0, 1, 0], "mixGreen": [0, 0, 1], "mixBlue": [1, 0, 0]]),
            look(.dither, choices: ["ditherPattern": "bayer4"]),
        ]
    }

    private static var moireBreathing: [Effect] {
        [
            effect(.interference),
            look(.twirl, choices: ["twirlShape": "pinch"], keyframes: ["twirlAmount": [(0, [0]), (2, [100]), (4, [0])]]),
            effect(.gradientMap), effect(.feedback),
        ]
    }
}
