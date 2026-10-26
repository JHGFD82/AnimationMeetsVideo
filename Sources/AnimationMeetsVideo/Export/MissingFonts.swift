import Foundation

extension EditingProject {
    /// The fonts the text of a timeline, and of the timelines nested in it,
    /// is set in that aren't installed on this Mac, in the order first met:
    /// a Text effect's own font and its runs'. Effects and clips that are
    /// off are skipped, as they draw nothing.
    func missingFonts(in timelineID: UUID) -> [String] {
        var missing: [String] = []
        var seen = Set<String>()
        var visited = Set<UUID>()
        func visit(_ id: UUID) {
            guard visited.insert(id).inserted, let timeline = timeline(id: id) else { return }
            for layer in timeline.layers {
                for clip in layer.clips where clip.enabled {
                    if case .timeline(let nested) = clip.source { visit(nested) }
                    for effect in clip.effects where effect.kind == .text && effect.enabled {
                        guard let content = effect.text else { continue }
                        let names = [content.fontName] + content.runs.compactMap(\.style.fontName)
                        for name in names where seen.insert(name).inserted && !FontCatalog.isInstalled(name) {
                            missing.append(name)
                        }
                    }
                }
            }
        }
        visit(timelineID)
        return missing
    }
}
