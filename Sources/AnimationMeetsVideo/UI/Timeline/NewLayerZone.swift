import SwiftUI
import UniformTypeIdentifiers

/// What the layer names column offers while something is dragged over it:
/// a new video layer for pictures, or for sound a choice of a new sound or
/// music layer, split top and bottom the way the areas are stacked.
struct NewLayerHover: Equatable {
    /// The kinds on offer, top to bottom.
    var kinds: [LayerKind]
    /// The one under the pointer.
    var hovered: LayerKind?

    /// The offer for a clip or asset that is sound alone, or not, with the
    /// pointer at `pointerY` over `column`.
    init(audio: Bool, pointerY: CGFloat, in column: CGRect) {
        self.init(hovering: audio ? (pointerY < column.midY ? .sound : .music) : .video)
    }

    /// The offer that includes `kind`, with the pointer over it.
    init(hovering kind: LayerKind) {
        kinds = kind.isAudio ? [.sound, .music] : [.video]
        hovered = kind
    }
}

/// Hued, translucent shapes over the layer names column saying what a drop
/// there makes: "New Video Layer", or "New Sound Layer" over "New Music
/// Layer". Drawn only; the drag that shows it decides what happens.
struct NewLayerZone: View {
    let hover: NewLayerHover

    var body: some View {
        VStack(spacing: Design.Space.tight) {
            ForEach(hover.kinds) { kind in
                let isHovered = hover.hovered == kind
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(kind.tone.opacity(isHovered ? 0.42 : 0.2))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .strokeBorder(kind.tone.opacity(isHovered ? 1 : 0.6), style: StrokeStyle(lineWidth: isHovered ? 1.5 : 1, dash: [5, 3]))
                    }
                    .overlay {
                        Label("New \(kind.name) Layer", systemImage: "plus.rectangle.on.rectangle")
                            .font(Design.Typeface.bodyEmphasis)
                            .foregroundStyle(Design.textOnColor.opacity(isHovered ? 1 : 0.7))
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    }
            }
        }
        .padding(Design.Space.tight)
        .editorAnimation(Design.Motion.select, value: hover)
        .allowsHitTesting(false)
    }
}

/// Takes media dragged from the library onto the layer names column and
/// puts it on a new layer of the kind under the pointer.
///
/// What is being dragged can't be read until it is dropped, so whether to
/// offer video or sound comes from `MediaDragPayload.draggedAssetID`, which
/// the browser sets as a drag begins.
struct NewLayerDropDelegate: DropDelegate {
    let column: () -> CGRect
    /// Where the delegate's view is, in window coordinates, to place the
    /// pointer within the whole column.
    let viewFrame: () -> CGRect
    let isAudio: (UUID) -> Bool
    let onHover: (NewLayerHover?) -> Void
    let onDrop: ([MediaDragPayload], LayerKind) -> Void

    private func hover(_ info: DropInfo) -> NewLayerHover? {
        guard let assetID = MediaDragPayload.draggedAssetID else { return nil }
        let y = viewFrame().minY + info.location.y
        return NewLayerHover(audio: isAudio(assetID), pointerY: y, in: column())
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        onHover(hover(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(hover(info))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let kind = hover(info)?.hovered
        onHover(nil)
        guard let kind else { return false }
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            var payloads: [MediaDragPayload] = []
            for provider in providers {
                if let payload = await Self.load(provider) { payloads.append(payload) }
            }
            if !payloads.isEmpty { onDrop(payloads, kind) }
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> MediaDragPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: MediaDragPayload.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
