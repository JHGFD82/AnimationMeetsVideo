import SwiftUI

/// A transition being dragged from the panel onto a clip. It travels as an
/// `amv-transition:` URL: like scene drags it needs no registered content
/// type (this app runs unbundled), and being a URL rather than text keeps a
/// clip's transition drop target from catching scenes dropped on the
/// timeline.
struct TransitionDragPayload: Transferable {
    private static let scheme = "amv-transition"

    var kind: TransitionKind

    init(kind: TransitionKind) {
        self.kind = kind
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let kind = TransitionKind(rawValue: String(url.absoluteString.dropFirst(Self.scheme.count + 1)))
        else { return nil }
        self.kind = kind
    }

    var url: URL { URL(string: "\(Self.scheme):\(kind.rawValue)")! }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.url }, importing: { url in
            guard let payload = TransitionDragPayload(url: url) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

/// The transitions that can be dragged onto either end of a clip, shown to
/// the right of the timeline, grouped by what they do to the pictures.
struct TransitionsPanel: View {
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transitions")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close transitions")
                .accessibilityLabel("Close transitions")
            }
            .padding(.horizontal, Design.Space.group)
            .padding(.vertical, Design.Space.step)
            .rail(.raised)

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.group) {
                    ForEach(TransitionCategory.allCases) { category in
                        VStack(alignment: .leading, spacing: Design.Space.close) {
                            Text(category.name)
                                .font(Design.Typeface.groupTitle)
                                .foregroundStyle(Design.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, spacing: Design.Space.step) {
                                ForEach(TransitionKind.allCases.filter { $0.category == category }) { kind in
                                    TransitionTile(kind: kind)
                                        .draggable(TransitionDragPayload(kind: kind)) {
                                            TransitionTile(kind: kind)
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(Design.Space.group)
            }
            .sunken(.sunken)

            Text("Drag one onto the start or end of a clip.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .padding(.horizontal, Design.Space.group)
                .padding(.vertical, Design.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Surface.base.color)
                .overlay(alignment: .top) { Groove() }
        }
        .panelSurface(.base)
    }
}

private struct TransitionTile: View {
    let kind: TransitionKind

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: Design.Space.close) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(isHovering ? Design.textPrimary : Design.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .beveledChip(
                    fill: isHovering ? Design.Surface.floating.color : Design.Surface.overlay.color,
                    radius: Design.Radius.control
                )
            Text(kind.name)
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
        }
        .padding(Design.Space.tight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .editorAnimation(Design.Motion.select, value: isHovering)
        .help("\(kind.name): drag onto the start or end of a clip")
        .accessibilityElement(children: .combine)
    }
}
