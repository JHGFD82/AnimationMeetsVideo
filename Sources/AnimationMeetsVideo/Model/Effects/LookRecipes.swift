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
            liquid, effect(.cosinePalette, choices: [.palette: PaletteLook.acid.rawValue]), effect(.hueCycle),
            blend(.softLight, against: liquid),
        ]
    }

    private static var infiniteTunnel: [Effect] {
        [
            effect(.kaleidoscope, [.segments: [8]]),
            effect(.feedback, [.copies: [12], .copyScale: [103], .copyRotation: [4], .hueStep: [15]]),
            effect(.chromaticAberration), effect(.grain),
        ]
    }

    private static var lavaLamp: [Effect] {
        [
            effect(.fractalNoise, choices: [.noiseType: NoiseType.smooth.rawValue]), effect(.liquid),
            effect(.gradientMap, [.scrollSpeed: [0.05]]),
        ]
    }

    private static var noiseMelt: [Effect] {
        let noise = effect(.fractalNoise, choices: [.noiseType: NoiseType.turbulent.rawValue])
        var displace = effect(.displace, [.displacement: [4]])
        displace.against = noise.id
        return [noise, displace, effect(.hueCycle), effect(.grain)]
    }

    private static var electricCells: [Effect] {
        let cells = effect(.cells, choices: [.cellOutput: CellOutput.edges.rawValue])
        return [cells, effect(.neonEdges), effect(.hueCycle, [.hueSpread: [120]]), blend(.screen, against: cells)]
    }

    private static var brokenSignal: [Effect] {
        let interference = effect(.interference)
        return [
            effect(.blockGlitch), effect(.chromaticAberration, choices: [.aberrationMode: AberrationMode.linear.rawValue]),
            interference, blend(.overlay, against: interference), effect(.staticNoise, [.amount: [15]]),
        ]
    }

    private static var meltingRainbow: [Effect] {
        [
            effect(.flowSmear), effect(.solarize, [.folds: [3]]), effect(.hueCycle),
            effect(.feedback, [.copies: [6], .copyScale: [100], .copyRotation: [0], .hueStep: [30]]),
        ]
    }

    private static var oilSlick: [Effect] {
        let wave = effect(.wave, choices: [.waveDirection: WaveDirection.radial.rawValue])
        return [
            wave, effect(.twirl, choices: [.twirlShape: TwirlShape.vortex.rawValue]),
            effect(.cosinePalette, choices: [.palette: PaletteLook.oilSlick.rawValue]), blend(.luminosity, against: wave),
        ]
    }

    private static var thermalDream: [Effect] {
        [
            effect(.falseColor, choices: [.falseColorLook: FalseColorLook.thermal.rawValue]),
            effect(.slitScan, choices: [.slitDirection: SlitDirection.rows.rawValue]), effect(.posterize, [.levels: [5]]),
            effect(.grain),
        ]
    }

    private static var eightfoldMandala: [Effect] {
        [
            effect(.mirrorTile, choices: [.tilePattern: TilePattern.eightfold.rawValue]), effect(.kaleidoscope, [.segments: [12]]),
            // Each channel from the next: red from green, green from blue,
            // blue from red.
            effect(.channelMixer, [.mixRed: [0, 1, 0], .mixGreen: [0, 0, 1], .mixBlue: [1, 0, 0]]),
            effect(.dither, choices: [.ditherPattern: DitherPattern.bayer4.rawValue]),
        ]
    }

    private static var moireBreathing: [Effect] {
        [
            effect(.interference),
            effect(.twirl, choices: [.twirlShape: TwirlShape.pinch.rawValue], keyframes: [.twirlAmount: [(0, [0]), (2, [100]), (4, [0])]]),
            effect(.gradientMap), effect(.feedback),
        ]
    }
}
