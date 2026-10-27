import SwiftUI

/// One row of a clip's filmstrip in the Clips tab, with the skim line over
/// it and the mouse handling that picks, ranges and drags it (see
/// `FilmstripMouseView`); the tab puts its menu around it, and hides it
/// from VoiceOver. Equatable, so it is drawn again only when the
/// clip, its layout or how it is picked changes; what the mouse does goes
/// through `actions`, which always acts on the tab as it is now.
struct ClipStripRow: View, Equatable {
    let entry: BrowserEntry
    let layout: FilmstripLayout
    let row: Int
    /// Selected whole, with no range of it picked.
    let isSelected: Bool
    let range: SecondsSpan?
    let used: [SecondsSpan]
    /// For the first row of a video shown whole (see `FilmstripRow`).
    let detection: AssetAnalysis?
    let skim: BrowserSkim?
    let actions: ClipRowActions

    nonisolated static func == (lhs: ClipStripRow, rhs: ClipStripRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.entry == rhs.entry && lhs.layout == rhs.layout && lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
                && lhs.range == rhs.range && lhs.used == rhs.used && lhs.detection === rhs.detection
                && lhs.skim === rhs.skim && lhs.actions === rhs.actions
        }
    }

    var body: some View {
        FilmstripRow(
            entry: entry, layout: layout, row: row, isSelected: isSelected, range: range, used: used,
            durationText: row == 0 ? ClipsTabModel.durationText(entry) : nil,
            detection: detection
        )
        .equatable()
        .overlay(alignment: .topLeading) {
            if let skim {
                SkimLine(skim: skim, item: entry.id, layout: layout, row: row)
            }
        }
        .overlay {
            FilmstripMouseView(
                rowOffset: CGFloat(row) * layout.rowPitch,
                onDown: { [actions, entry, layout] point, flags in actions.pressBegan(entry, layout, point, flags) },
                onPress: { [actions, entry, layout] press in actions.pressed(press, entry, layout) },
                dragText: { [actions, entry, layout] point in actions.dragText(entry, layout, point) },
                isOnHandle: { [actions, entry, layout] point in actions.isOnHandle(entry, layout, point) },
                onHover: { [actions, entry, layout] point in actions.hover(entry, layout, point) }
            )
        }
    }
}
