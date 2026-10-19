import AppKit
import SwiftUI

/// What is being dragged within the effects panel, noted as the drag
/// starts: a drop target can't read a drag before the drop, and the stack
/// must know before then whether to show a place among the effects or
/// among one effect's controls. Nil for drags from elsewhere (the Effects
/// Library, presets), which go among the effects.
@MainActor
final class EffectsDragSession {
    static let shared = EffectsDragSession()

    enum Dragged: Equatable {
        case effect(clipID: UUID, effectID: UUID)
        case control(clipID: UUID, effectID: UUID, controlID: UUID)
    }

    var current: Dragged?
}

/// Where each effect and control row of the stack is, in the stack's own
/// coordinates (`space`), for the drop to find the place under the
/// pointer. Not observed: it changes with every layout and redraws
/// nothing.
@MainActor
final class EffectStackLayout {
    static let space = "effectStack"
    var effects: [UUID: CGRect] = [:]
    var controls: [UUID: CGRect] = [:]
}

/// Where a drop in the stack goes.
enum EffectStackTarget: Equatable {
    /// Among the picture effects or the sound effects, before the effect
    /// at `index` (the end when it is the count); nil for an empty stack.
    case effects(isAudio: Bool, index: Int?)
    /// Among an effect's controls.
    case controls(effectID: UUID, index: Int)
}

/// Takes every drop on the effect stack: an effect or a control moved, or
/// with Option an effect copied; an effect or a preset from the library.
/// While a drag is over it, it draws a line where the drop would go and
/// scrolls the stack when the pointer nears its top or bottom.
///
/// One target for the whole stack rather than one per row: every drag
/// here travels as a URL, so a row's target would take drags meant for
/// the rows around it.
struct EffectStackDropDelegate: DropDelegate {
    let clip: TimelineClip
    let layout: EffectStackLayout
    let scroller: EdgeAutoScroll
    /// The line's height in the stack, or nil to hide it.
    let onMark: (CGFloat?) -> Void
    /// Makes the drop; `copy` when Option was held.
    let onDrop: (EffectStackTarget, ClipDropPayload, _ copy: Bool) -> Void

    private var session: EffectsDragSession { .shared }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        scroller.begin()
        mark(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        mark(info)
        scroller.dragMoved()
        // Option copies an effect; the pointer shows the plus.
        if case .effect? = session.current, NSEvent.modifierFlags.contains(.option) {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: session.current == nil ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        onMark(nil)
        scroller.end()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = target(at: info.location.y).target
        let copy = NSEvent.modifierFlags.contains(.option)
        onMark(nil)
        scroller.end()
        session.current = nil
        guard let provider = info.itemProviders(for: [.url]).first else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            if let payload = await Self.load(provider) { onDrop(target, payload, copy) }
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> ClipDropPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: ClipDropPayload.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    private func mark(_ info: DropInfo) {
        onMark(target(at: info.location.y).line)
    }

    /// Where a drop at `y` would go, and where its line is drawn.
    private func target(at y: CGFloat) -> (target: EffectStackTarget, line: CGFloat?) {
        if case .control(let clipID, let effectID, _)? = session.current, clipID == clip.id,
           let effect = clip.effect(id: effectID) {
            let frames = effect.controls.compactMap { layout.controls[$0.id] }
            let (index, line) = Self.place(y, among: frames)
            return (.controls(effectID: effectID, index: index), line)
        }
        let picture = clip.effects.compactMap { layout.effects[$0.id] }
        let sound = clip.audioEffects.compactMap { layout.effects[$0.id] }
        // A moved effect stays in its own stack; anything else goes in the
        // one nearer the pointer.
        let isAudio: Bool
        if case .effect(let clipID, let effectID)? = session.current, clipID == clip.id {
            isAudio = clip.audioEffects.contains { $0.id == effectID }
        } else {
            isAudio = Self.distance(y, to: sound) < Self.distance(y, to: picture)
        }
        let frames = isAudio ? sound : picture
        guard !frames.isEmpty else { return (.effects(isAudio: isAudio, index: nil), nil) }
        let (index, line) = Self.place(y, among: frames)
        return (.effects(isAudio: isAudio, index: index), line)
    }

    /// The place before the first row whose middle is below `y`, or after
    /// the last, and the height of the line there.
    nonisolated static func place(_ y: CGFloat, among frames: [CGRect]) -> (index: Int, line: CGFloat?) {
        guard let last = frames.last else { return (0, nil) }
        if let index = frames.firstIndex(where: { y < $0.midY }) { return (index, frames[index].minY) }
        return (frames.count, last.maxY)
    }

    private nonisolated static func distance(_ y: CGFloat, to frames: [CGRect]) -> CGFloat {
        guard let first = frames.first, let last = frames.last else { return .infinity }
        return y < first.minY ? first.minY - y : max(0, y - last.maxY)
    }
}

extension EffectMovePayload {
    /// Starts dragging an effect from its handle, noting it for the stack.
    @MainActor
    func itemProvider() -> NSItemProvider {
        EffectsDragSession.shared.current = .effect(clipID: clipID, effectID: effectID)
        return NSItemProvider(object: url as NSURL)
    }
}

extension ControlMovePayload {
    /// Starts dragging a control from its handle, noting it for the stack.
    @MainActor
    func itemProvider() -> NSItemProvider {
        EffectsDragSession.shared.current = .control(clipID: clipID, effectID: effectID, controlID: controlID)
        return NSItemProvider(object: url as NSURL)
    }
}
