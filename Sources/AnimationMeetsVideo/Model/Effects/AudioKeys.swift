import CoreMedia
import Foundation

// Audio Keys (see docs/keyframing-effects.md, "Audio Keys in detail"):
// what it listens to, the sound as heard from the files' spectrograms, and
// the steps from a frequency range's level to the value it writes.

/// How Audio Keys maps how loud its range is (0...1 between the box's
/// bottom and top) to its output.
enum KeyCurve: String, CaseIterable, Identifiable, Sendable {
    case linear
    /// Slow in and out, so quiet and loud moments read apart.
    case ease
    /// All or nothing, at halfway: a trigger.
    case threshold

    var id: Self { self }

    var name: String {
        switch self {
        case .linear: "Linear"
        case .ease: "Ease"
        case .threshold: "Threshold"
        }
    }
}

/// What an Audio Keys effect listens to, in its clip's timeline.
enum AudioKeysSource: Hashable, Sendable {
    /// Everything that plays sound.
    case mix
    /// One Sound or Music layer.
    case layer(UUID)
    /// One clip.
    case clip(UUID)
}

/// One clip an Audio Keys effect hears, with the layer it is on and the
/// file it plays.
struct HeardClip {
    var clip: TimelineClip
    var layer: TimelineLayer
    var asset: MediaClip
    /// Where the file is.
    var url: URL
}

extension EditingProject {
    /// The clips with sound from files that `source` takes in, in its
    /// timeline. A nested timeline's sound isn't heard, nor a missing
    /// file's.
    func heardClips(_ source: AudioKeysSource, in timeline: Timeline) -> [HeardClip] {
        timeline.layers.flatMap { layer -> [HeardClip] in
            switch source {
            case .mix: break
            case .layer(let id): guard layer.id == id else { return [] }
            case .clip: break
            }
            return layer.clips.compactMap { clip in
                if case .clip(let id) = source, clip.id != id { return nil }
                guard playsAudio(clip), case .media(let assetID) = clip.source, let asset = mediaClip(id: assetID),
                      let url = asset.url
                else { return nil }
                return HeardClip(clip: clip, layer: layer, asset: asset, url: url)
            }
        }
    }

    /// Each band's level in decibels, as heard, at each of `times` in the
    /// timeline: every clip's spectrogram where it plays, through its
    /// volume and EQ and its layer's, summed as power. Nil while a file's
    /// spectrogram is still being read.
    func heardBands(_ source: AudioKeysSource, in timeline: Timeline, at times: [CMTime]) -> [[Double]]? {
        let clips = heardClips(source, in: timeline)
        var spectrograms: [Spectrogram] = []
        for heard in clips {
            guard let spectrogram = SpectrogramStore.shared.spectrogram(for: heard.url) else { return nil }
            spectrograms.append(spectrogram)
        }
        var shaping = clips.map { _ in EqualizerShaping() }
        return times.map { time in
            var power = [Double](repeating: 0, count: Spectrogram.bandCount)
            for (index, heard) in clips.enumerated() {
                let clip = heard.clip
                guard time >= clip.startOffset, time < clip.endOffset else { continue }
                let source = clip.sourceTime(atTimelineTime: time)
                var gain = clip.volume.value(at: source)
                if heard.layer.kind.isAudio { gain += heard.layer.volume.value(at: time) }
                guard gain > AudioLevel.silence else { continue }
                let bands = spectrograms[index].decibels(atSeconds: heard.asset.fileTime(forSourceTime: source).seconds)
                let eq = shaping[index].response(clip: clip.audioEffects, at: source, layer: heard.layer.audioEffects, layerTime: time)
                for band in bands.indices where bands[band] > Spectrogram.floor {
                    power[band] += pow(10, (bands[band] + gain + eq[band]) / 10)
                }
            }
            return power.map { $0 > 0 ? max(10 * log10($0), Spectrogram.floor) : Spectrogram.floor }
        }
    }

    /// Fingerprints what an Audio Keys effect hears, so a change to any of
    /// it shows the effect is out of date.
    func addHeard(_ source: AudioKeysSource, in timeline: Timeline, to fingerprint: inout KeyframingPrint) {
        func add(_ effects: [Effect]) {
            for effect in effects where effect.kind == .equalizer {
                fingerprint.add(UInt64(effect.enabled ? 1 : 0))
                for control in effect.controls {
                    fingerprint.add(UInt64(control.enabled ? 1 : 0))
                    fingerprint.add(control.number) { $0.values }
                    fingerprint.add(control.choice)
                }
            }
        }
        for heard in heardClips(source, in: timeline) {
            fingerprint.add(heard.asset.id)
            fingerprint.add(SpectrogramStore.shared.spectrogram(for: heard.url)?.fingerprint ?? 1)
            fingerprint.add(heard.asset.alignmentOffset)
            for time in [heard.clip.startOffset, heard.clip.trimStart, heard.clip.trimEnd] { fingerprint.add(time) }
            fingerprint.add(heard.clip.time.speed) { [$0] }
            fingerprint.add(heard.clip.volume) { [$0] }
            add(heard.clip.audioEffects)
            if heard.layer.kind.isAudio {
                fingerprint.add(heard.layer.volume) { [$0] }
                add(heard.layer.audioEffects)
            }
        }
    }
}

/// The EQs on a clip and its layer as a gain for each band, at the band's
/// center, worked out again only when their settings change.
private struct EqualizerShaping {
    private var settings: [Equalizer.Settings] = []
    private var response = [Double](repeating: 0, count: Spectrogram.bandCount)

    mutating func response(clip: [Effect], at source: CMTime, layer: [Effect], layerTime: CMTime) -> [Double] {
        let now = clip.filter { $0.kind == .equalizer && $0.enabled }.map { Equalizer.settings(of: $0, at: source) }
            + layer.filter { $0.kind == .equalizer && $0.enabled }.map { Equalizer.settings(of: $0, at: layerTime) }
        if now != settings {
            settings = now
            response = (0..<Spectrogram.bandCount).map { band in
                now.reduce(0) { $0 + Equalizer.response(of: $1, at: Spectrogram.center(band)) }
            }
        }
        return response
    }
}

enum AudioKeysMath {
    /// The level in decibels of the part of the spectrum from `low` to
    /// `high` Hz: the bands' power summed, each by how much of it (on a
    /// log scale) the range covers.
    static func level(of bands: [Double], from low: Double, to high: Double) -> Double {
        let lower = max(min(low, high), Spectrogram.lowestFrequency)
        let upper = min(max(low, high), Spectrogram.highestFrequency)
        var power = 0.0
        for band in bands.indices {
            let a = Spectrogram.edge(band), b = Spectrogram.edge(band + 1)
            let overlap = log(min(b, upper)) - log(max(a, lower))
            guard overlap > 0, bands[band] > Spectrogram.floor else { continue }
            power += pow(10, bands[band] / 10) * overlap / log(b / a)
        }
        return power > 0 ? max(10 * log10(power), Spectrogram.floor) : Spectrogram.floor
    }

    /// 0 below `floor`, 1 above `ceiling`, linear in decibels between.
    static func normalized(_ level: Double, floor: Double, ceiling: Double) -> Double {
        guard ceiling > floor else { return level >= ceiling ? 1 : 0 }
        return min(max((level - floor) / (ceiling - floor), 0), 1)
    }

    /// `values` followed with a rise and a fall time constant (seconds),
    /// so a hit comes in fast and lingers. 0 follows at once.
    static func envelope(_ values: [Double], elapsed: [Double], attack: (Int) -> Double, release: (Int) -> Double) -> [Double] {
        var level = 0.0
        return values.indices.map { k in
            let dt = k > 0 ? elapsed[k] - elapsed[k - 1] : 0
            let constant = values[k] > level ? attack(k) : release(k)
            level += (values[k] - level) * (constant > 0 && k > 0 ? 1 - exp(-dt / constant) : 1)
            return level
        }
    }

    static func shaped(_ value: Double, _ curve: KeyCurve) -> Double {
        switch curve {
        case .linear: value
        case .ease: value * value * (3 - 2 * value)
        case .threshold: value >= 0.5 ? 1 : 0
        }
    }
}
