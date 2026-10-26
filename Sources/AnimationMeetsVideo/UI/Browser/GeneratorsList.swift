import AppKit
import SwiftUI

/// A generator (text or a shape) being dragged from the browser onto the
/// timeline, where it makes a clip of its own. It travels as an
/// `amv-generator:` URL, like the app's other drags, so the drop targets
/// that take effects never mistake it for one: a generator isn't an
/// effect and goes into no footage clip's stack.
struct GeneratorDragPayload: Transferable {
    private static let scheme = "amv-generator"

    var kind: EffectKind

    init(kind: EffectKind) {
        self.kind = kind
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let kind = EffectKind(rawValue: String(url.absoluteString.dropFirst(Self.scheme.count + 1))),
              kind.drawsShape
        else { return nil }
        self.kind = kind
    }

    var url: URL { URL(string: "\(Self.scheme):\(kind.rawValue)")! }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.url }, importing: { url in
            guard let payload = GeneratorDragPayload(url: url) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

extension ClipDropPayload {
    var generator: GeneratorDragPayload? { GeneratorDragPayload(url: url) }
}

/// The browser's Generators tab: text and the shapes, which aren't
/// effects but clips of their own (see docs/graphic-layers.md). One
/// dragged onto the timeline makes a clip where it lands; double-clicked,
/// it makes a new layer at the playhead. Dropped on a text or shape clip,
/// or added to the selected one from its menu, it joins that clip, below
/// what is there, so text can follow the path of a shape above it.
struct GeneratorsList: View {
    /// Makes a new layer at the playhead holding one, and selects it.
    let onAdd: (EffectKind) -> Void
    /// Adds one to the selected text or shape clip; nil when none is
    /// selected.
    let onAddToSelected: ((EffectKind) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Design.Space.step) {
                    ForEach(EffectKind.generators) { kind in
                        // The double-click goes inside the drag: on the
                        // outside its tap gesture takes the mouse down
                        // first, and the tile never starts a drag.
                        GeneratorTile(kind: kind)
                            .onTapGesture(count: 2) { onAdd(kind) }
                            .draggable(GeneratorDragPayload(kind: kind)) { GeneratorTile(kind: kind) }
                            .contextMenu {
                                Button("Add at the Playhead") { onAdd(kind) }
                                Button("Add to the Selected Clip") { onAddToSelected?(kind) }
                                    .disabled(onAddToSelected == nil)
                            }
                            .accessibilityAction { onAdd(kind) }
                            .accessibilityAction(named: "Add at the playhead") { onAdd(kind) }
                            .accessibilityAction(named: "Add to the selected clip") {
                                if let onAddToSelected { onAddToSelected(kind) } else { NSSound.beep() }
                            }
                    }
                }
                .padding(Design.Space.group)
            }
            .sunken(.sunken)

            Text("Drag one onto the timeline to make a clip there, or double-click it to add a layer at the playhead. Dropped on a text or shape clip, it joins that clip.")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
                .padding(.horizontal, Design.Space.group)
                .padding(.vertical, Design.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Surface.base.color)
                .overlay(alignment: .top) { Groove() }
        }
    }
}

/// One generator in the tab: its glyph and name.
private struct GeneratorTile: View {
    let kind: EffectKind

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: Design.Space.close) {
            Image(systemName: kind.systemImage)
                .font(Design.Typeface.glyphLarge)
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
        .help(kind == .text
              ? "Text: drag onto the timeline, or double-click to add a text layer at the playhead; type its words in the inspector"
              : "\(kind.name): drag onto the timeline, or double-click to add a shape layer at the playhead")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.name)
        .accessibilityHint("Makes a \(kind == .text ? "text" : "shape") clip. Drag onto the timeline, or double-click to add a layer at the playhead.")
        .accessibilityAddTraits(.isButton)
    }
}
