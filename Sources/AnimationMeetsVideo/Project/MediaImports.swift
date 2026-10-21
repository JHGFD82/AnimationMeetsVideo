import Foundation
import Observation

/// Files being imported into the library, which the Clips tab shows until
/// each arrives. Most take a moment, but a long Matroska file takes
/// seconds to index and make its reference movie for (see
/// docs/matroska.md), and without them listed the clip would appear
/// unannounced.
@MainActor
@Observable
final class MediaImports {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        /// How far along it is, 0...1, when the import can tell (Matroska
        /// files); nil until then.
        var fraction: Double?
    }

    private(set) var items: [Item] = []

    /// Lists the files at `urls` as importing, and returns their IDs in order.
    func begin(_ urls: [URL]) -> [Item.ID] {
        let added = urls.map { Item(name: $0.deletingPathExtension().lastPathComponent) }
        items.append(contentsOf: added)
        return added.map(\.id)
    }

    /// Moves an import's progress forward. Reports come from the importer's
    /// thread and may arrive out of order or after the import ends, and
    /// steps under a half percent aren't worth redrawing for.
    func update(_ id: Item.ID, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let fraction = min(max(fraction, 0), 1)
        if let current = items[index].fraction, fraction < current + 0.005 { return }
        items[index].fraction = fraction
    }

    func end(_ id: Item.ID) {
        items.removeAll { $0.id == id }
    }

    /// A reporter for the importer to call from any thread.
    nonisolated func reporter(for id: Item.ID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in self?.update(id, fraction: fraction) }
        }
    }
}
