import AppKit
import SwiftUI

/// What the Clips tab's rows do when pressed, dragged, hovered or acted on
/// by VoiceOver. The tab keeps one and points it at its state as it is at
/// each redraw. The rows are Equatable and keep this object, so a row that
/// isn't drawn again never acts on an old copy of the tab: the rows of a
/// clip that didn't change would otherwise still hold the clip order, or
/// the active timeline, from when they were last drawn.
@MainActor
final class ClipRowActions {
    enum Action {
        /// VoiceOver's default action: a plain click.
        case select
        /// A press on the title, with the keys held as the event has them.
        case mouseDown
        case addToTimeline
        case skimForward
        case skimBack
        case setRangeStart
        case setRangeEnd
        case rename
        case removeFromProject
        case findAll
        case setRenaming(Bool)
        case commitName(String)
    }

    var perform: (Action, BrowserEntry) -> Void = { _, _ in }
    /// Whether the asset's name is being edited.
    var isRenaming: (UUID) -> Bool = { _ in false }
    var pressBegan: (BrowserEntry, FilmstripLayout, CGPoint, NSEvent.ModifierFlags) -> Bool = { _, _, _, _ in false }
    var pressed: (FilmstripPress, BrowserEntry, FilmstripLayout) -> Void = { _, _, _ in }
    var dragText: (BrowserEntry, FilmstripLayout, CGPoint) -> (text: String, image: NSImage)? = { _, _, _ in nil }
    var isOnHandle: (BrowserEntry, FilmstripLayout, CGPoint) -> Bool = { _, _, _ in false }
    var hover: (BrowserEntry, FilmstripLayout, CGPoint?) -> Void = { _, _, _ in }
}

/// A clip's title in the Clips tab: a scene's number, or an asset's name
/// (renamed in place), with what it is doing under it. Only the drawing and
/// the press: the tab puts its menu and what VoiceOver reads of the clip
/// around it, in that order, since those follow the whole selection.
/// Equatable, so it is drawn again only when the clip or whether it is
/// selected changes.
struct ClipTitleRow: View, Equatable {
    let entry: BrowserEntry
    let isSelected: Bool
    /// Selected whole with no range picked anywhere, so a click on an
    /// asset's name renames it, as in the Finder.
    let nameIsSelected: Bool
    let isRenaming: Bool
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let actions: ClipRowActions

    nonisolated static func == (lhs: ClipTitleRow, rhs: ClipTitleRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.entry == rhs.entry && lhs.isSelected == rhs.isSelected
                && lhs.nameIsSelected == rhs.nameIsSelected && lhs.isRenaming == rhs.isRenaming
                && lhs.analysis === rhs.analysis && lhs.replacement === rhs.replacement && lhs.actions === rhs.actions
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Space.tight) {
                    if let number = entry.sceneNumber {
                        Text("Scene \(number)")
                            .font(Design.Typeface.label)
                            .foregroundStyle(isSelected ? Design.accent : Design.textPrimary)
                            .lineLimit(1)
                    } else {
                        // A whole asset's name renames it, as in the Finder: a
                        // click on it once it is selected.
                        assetName
                            .font(Design.Typeface.label)
                            .foregroundStyle(isSelected ? Design.accent : Design.textPrimary)
                    }
                    if entry.setByHand {
                        Image(systemName: "hand.point.up.left")
                            .font(Design.Typeface.micro)
                            .foregroundStyle(Design.textTertiary)
                            .help("Boundary set by hand")
                            .accessibilityLabel("set by hand")
                    }
                }
                if case .asset = entry.id {
                    // Detection shows its progress across the strip instead.
                    AssetStatusLine(analysis: analysis, replacement: replacement, clip: entry.clip, stripShowsDetection: true)
                }
            }
        }
        // On the press, with the keys held, as a strip takes it: a tap
        // gesture lost Command and Shift, and quick clicks.
        .onMouseDown { _ in actions.perform(.mouseDown, entry) }
    }

    /// The asset's name, edited in place while it is being renamed.
    private var assetName: some View {
        let clipID = entry.clip.id
        return InlineNameField(
            name: entry.clip.name,
            isEditing: Binding(
                get: { [actions] in actions.isRenaming(clipID) },
                set: { [actions, entry] editing in actions.perform(.setRenaming(editing), entry) }
            ),
            isSelected: nameIsSelected,
            onCommit: { [actions, entry] in actions.perform(.commitName($0), entry) }
        )
    }
}
