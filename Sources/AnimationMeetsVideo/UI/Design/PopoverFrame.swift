import SwiftUI

/// One shape for every popover in the editor, as `SheetFrame` is for
/// sheets.
///
/// The popovers grew up separately: four widths, three insets, and one of
/// six on the overlay surface that `Design.Surface` reserves for them.
/// `PopoverFrame` fixes the inset (the rail's), the width (one of
/// `Design.PopoverWidth`) and the surface, and stacks its content at a
/// sheet's spacing. Group headings are `SheetSection`s and rules between
/// groups `Groove()`s, as in a sheet.
struct PopoverFrame<Content: View>: View {
    var width: CGFloat = Design.PopoverWidth.standard
    var spacing: CGFloat = Design.Space.group + 2
    @ViewBuilder let content: () -> Content

    init(
        width: CGFloat = Design.PopoverWidth.standard,
        spacing: CGFloat = Design.Space.group + 2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(Design.Space.rail)
        .frame(width: width, alignment: .leading)
        .background(Design.Surface.overlay.color)
        // The arrow too, so it doesn't show the system's material.
        .presentationBackground(Design.Surface.overlay.color)
    }
}

extension Design {
    /// Widths popovers are allowed to be.
    enum PopoverWidth {
        /// A short list to pick from: the new shape's kinds.
        static let compact: CGFloat = 200
        /// Settings: view options, recording, the tick, ease handles.
        static let standard: CGFloat = 300
    }
}
