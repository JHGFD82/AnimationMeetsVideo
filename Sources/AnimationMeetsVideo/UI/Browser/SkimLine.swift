import SwiftUI

/// The thin line on a filmstrip row at the frame the viewer shows while the
/// clip is skimmed. A view of its own, reading the skim position, so only
/// it redraws as the pointer moves.
struct SkimLine: View {
    let skim: BrowserSkim
    let item: BrowserItemID
    let layout: FilmstripLayout
    let row: Int

    var body: some View {
        if skim.target?.item == AnyHashable(item) {
            let position = layout.position(atSeconds: skim.seconds)
            if position.row == row {
                Rectangle()
                    .fill(Design.skim)
                    .frame(width: 2, height: layout.cellSize.height)
                    .offset(x: position.x - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
