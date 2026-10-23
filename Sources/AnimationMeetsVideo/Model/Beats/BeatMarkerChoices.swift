import Foundation

/// Which Music layer's beats each timeline shows, remembered between
/// launches (`Preferences.beatMarkerLayers`), so markers turned on stay on
/// when the app opens again.
///
/// Kept by timeline ID, since a layer ID only means something on its own
/// timeline; a timeline with no entry shows none. A layer that has since
/// gone, or lost its beats, simply isn't offered, and the markers stay off
/// until it comes back or another is picked.
struct BeatMarkerChoices: Equatable {
    private(set) var layers: [UUID: UUID] = [:]

    init() {}

    func layer(for timeline: UUID) -> UUID? { layers[timeline] }

    /// Shows `layer`'s beats on `timeline`, or none when nil.
    mutating func choose(_ layer: UUID?, for timeline: UUID) {
        layers[timeline] = layer
    }
}

extension BeatMarkerChoices: RawRepresentable {
    // A [String: String] in JSON: UUID keys would encode as an array of
    // pairs, and Codable here would go through rawValue (see
    // `TimelineAreaLayout`).
    init?(rawValue: String) {
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: Data(rawValue.utf8)) else { return nil }
        for (timeline, layer) in decoded {
            guard let timeline = UUID(uuidString: timeline), let layer = UUID(uuidString: layer) else { continue }
            layers[timeline] = layer
        }
    }

    var rawValue: String {
        let strings = Dictionary(uniqueKeysWithValues: layers.map { ($0.key.uuidString, $0.value.uuidString) })
        guard let data = try? JSONEncoder().encode(strings) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
