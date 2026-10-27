import AppKit
import CoreMedia
import SwiftUI

/// What the Clips tab's clicks, drags and keys do to what is picked, apart
/// from the view: the selection, the clip the arrow keys move from, and the
/// range being dragged out. What else they do (skimming, adding to the
/// timeline, removing media) comes back as effects for the view to carry
/// out, so this can be tested without one. See docs/browser.md,
/// "Selecting" and "Keyboard and VoiceOver".
struct ClipsTabInteraction {
    typealias Snapshot = ClipsTabModel.Snapshot

    /// A range being dragged out: its clip, and the end that stays put.
    struct RangeDrag: Equatable {
        var item: BrowserItemID
        var anchor: Double
    }

    /// The viewer's skimming, as much of it as the keys read.
    struct Skim: Equatable {
        /// The clip skimmed, when it is one of this tab's.
        var item: BrowserItemID?
        var seconds: Double = 0
        /// Whether anything is skimmed, this tab's or not.
        var isActive = false

        static let none = Skim()

        /// Where `entry` is skimmed, in seconds into it; nil when it isn't.
        func seconds(in entry: BrowserEntry) -> Double? { item == entry.id ? seconds : nil }
    }

    enum PressEffect: Equatable {
        case none
        /// Show `entry` in the viewer at `at` seconds into it.
        case skim(BrowserEntry, at: Double)
    }

    enum KeyEffect: Equatable {
        case skim(BrowserEntry, at: Double)
        case step(frames: Int)
        case endSkim
        case addToTimeline([MediaPiece])
        /// Take the media wholly selected out of the project, or beep.
        case removeSelection
    }

    enum KeyOutcome: Equatable {
        /// Left for the rest of the app.
        case unhandled
        /// Taken, with what the view does next, in order.
        case handled([KeyEffect])
    }

    var picked = BrowserSelection<BrowserItemID>()
    /// Where the arrow keys move from: the last clip clicked or stepped to.
    var cursor: BrowserItemID?
    var rangeDrag: RangeDrag?

    // MARK: - Clicks and presses

    /// A click on a clip, on its title or its strip, `seconds` into it when
    /// known: Command adds it or takes it out, Shift selects the run from
    /// the last one clicked, and a plain click selects it alone (keeping
    /// its range when inside it).
    mutating func click(_ id: BrowserItemID, flags: NSEvent.ModifierFlags, order: [BrowserItemID], at seconds: Double? = nil) {
        cursor = id
        if flags.contains(.command) {
            picked.commandClick(id)
        } else if flags.contains(.shift) {
            picked.shiftClick(id, in: order)
        } else {
            picked.click(id, at: seconds)
        }
    }

    /// Whether a press tracks a range once it moves: on a handle, or off
    /// what is selected (with Option, anywhere). Nothing is picked until it
    /// moves, so a press let go in place is still a click.
    mutating func pressBegan(entry: BrowserEntry, layout: FilmstripLayout, point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        if let fixed = picked.handle(of: entry.id, at: point, in: layout) {
            rangeDrag = RangeDrag(item: entry.id, anchor: fixed)
            return true
        }
        // Command and Shift add to the selection, which ranges never do.
        guard flags.isDisjoint(with: [.command, .shift]) else { return false }
        let seconds = layout.seconds(at: point)
        guard flags.contains(.option) || !picked.pressDrags(entry.id, at: seconds) else { return false }
        rangeDrag = RangeDrag(item: entry.id, anchor: entry.snapped(seconds))
        return true
    }

    /// A press on a strip let go in place, moved while tracking a range, or
    /// let go after tracking one. Without `skimming`, a click shows the
    /// frame clicked.
    mutating func pressed(
        _ press: FilmstripPress, entry: BrowserEntry, layout: FilmstripLayout, order: [BrowserItemID], skimming: Bool
    ) -> PressEffect {
        switch press {
        case .click(let point, let flags):
            rangeDrag = nil
            if !flags.isDisjoint(with: [.command, .shift]) {
                click(entry.id, flags: flags, order: order)
            } else if picked.handle(of: entry.id, at: point, in: layout) == nil {
                let seconds = layout.seconds(at: point)
                click(entry.id, flags: flags, order: order, at: seconds)
                if !skimming { return .skim(entry, at: seconds) }
            } else {
                cursor = entry.id
            }
            return .none
        case .track(let point):
            guard let rangeDrag, rangeDrag.item == entry.id else { return .none }
            let seconds = layout.seconds(at: point)
            picked.setRange(of: entry.id, from: rangeDrag.anchor, to: entry.snapped(seconds), duration: entry.seconds)
            // The viewer shows the end being dragged, as skimming does.
            return .skim(entry, at: seconds)
        case .endTrack:
            rangeDrag = nil
            // A drag too short to span a frame picks the whole clip.
            if let range = picked.range, range.item == entry.id, range.end - range.start < entry.frameSeconds {
                picked.click(entry.id)
            }
            return .none
        }
    }

    // MARK: - Dragging

    /// Settles what a drag from `point` carries before it is worked out: a
    /// clip not selected is picked alone, unless the drag starts inside its
    /// range. Only a press with Command or Shift gets this far on a clip
    /// not selected, since any other press on one picks a range instead
    /// (`pressBegan`).
    mutating func pickForDrag(entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint) {
        if let range = picked.range, range.item == entry.id, range.contains(layout.seconds(at: point)) { return }
        if !picked.contains(entry.id) { picked.click(entry.id) }
    }

    /// What a drag from `point` carries: the range when it starts inside
    /// the clip's range, otherwise the clip, or every selected clip when it
    /// is one of them.
    func draggedPieces(entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint, snapshot: Snapshot) -> [MediaPiece] {
        if let range = picked.range, range.item == entry.id, range.contains(layout.seconds(at: point)) {
            return [entry.piece(from: range.start, to: range.end)]
        }
        return ClipsTabModel.dragPieces(for: picked.dragged(from: entry.id, in: snapshot.order), snapshot: snapshot)
    }

    // MARK: - Keys

    /// The clip the keyboard skims: the one last stepped to or clicked
    /// while it is selected, otherwise the first selected.
    func keyboardEntry(_ snapshot: Snapshot) -> BrowserEntry? {
        let id = cursor.flatMap { picked.contains($0) ? $0 : nil } ?? picked.ordered(in: snapshot.order).first
        return id.flatMap { snapshot.byID[$0] }
    }

    /// Sets the start or end of `entry`'s range where it is skimmed, keeping
    /// the other end (or the clip's own); false when it isn't skimmed.
    @discardableResult
    mutating func setRangeEnd(_ end: BrowserSelection<BrowserItemID>.RangeEnd, of entry: BrowserEntry, skim: Skim) -> Bool {
        guard let at = skim.seconds(in: entry) else { return false }
        picked.setRangeEnd(end, of: entry.id, at: at, duration: entry.seconds)
        cursor = entry.id
        return true
    }

    /// Up and down move the selection (Shift extends it); Return adds the
    /// selection to the timeline, and Delete (or Command-Delete) takes the
    /// media wholly selected out of the project. Option-Left and
    /// Option-Right skim the selected clip a frame at a time (ten with
    /// Shift), I and O set its range's ends where it is skimmed, and Escape
    /// stops skimming.
    mutating func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers, snapshot: Snapshot, skim: Skim) -> KeyOutcome {
        switch key {
        case .leftArrow, .rightArrow:
            guard modifiers.contains(.option), let entry = keyboardEntry(snapshot) else { return .unhandled }
            let frames = (modifiers.contains(.shift) ? 10 : 1) * (key == .leftArrow ? -1 : 1)
            var effects: [KeyEffect] = []
            if skim.seconds(in: entry) == nil {
                effects.append(.skim(entry, at: picked.range?.item == entry.id ? picked.range?.start ?? 0 : 0))
            }
            return .handled(effects + [.step(frames: frames)])
        case "i", "o":
            guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
                  let entry = skim.item.flatMap({ snapshot.byID[$0] }) ?? keyboardEntry(snapshot),
                  setRangeEnd(key == "i" ? .start : .end, of: entry, skim: skim)
            else { return .unhandled }
            return .handled([])
        case .escape:
            return skim.isActive ? .handled([.endSkim]) : .unhandled
        case .return:
            guard let first = picked.range?.item ?? picked.ordered(in: snapshot.order).first else { return .unhandled }
            return .handled([.addToTimeline(ClipsTabModel.piecesToAdd(from: first, snapshot: snapshot, picked: picked))])
        case .delete, .deleteForward:
            // Command-Delete removes too, as in the Finder.
            guard modifiers.isDisjoint(with: [.control, .option, .shift]), !picked.items.isEmpty else { return .unhandled }
            return .handled([.removeSelection])
        case .upArrow, .downArrow:
            guard let next = picked.step(
                key == .upArrow ? -1 : 1, from: cursor, extending: modifiers.contains(.shift), in: snapshot.order
            ) else { return .unhandled }
            cursor = next
            return .handled([.endSkim])
        default:
            return .unhandled
        }
    }

    // MARK: - Show in Clips Browser

    /// Picks the footage a timeline clip plays: the part of the scene (or
    /// clip) it plays as a range, the whole of it when it plays all of it,
    /// or every scene it plays across. Returns the first of them, to scroll
    /// to; nil when the asset isn't listed.
    mutating func revealSelection(for piece: MediaPiece, snapshot: Snapshot) -> BrowserItemID? {
        let entries = snapshot.entriesByAsset[piece.assetID] ?? []
        let covered = entries.filter { $0.start < piece.end && CMTimeAdd($0.start, $0.duration) > piece.start }
        guard let first = covered.first ?? entries.first else { return nil }
        if let last = covered.last, covered.count > 1 {
            picked.click(first.id)
            picked.shiftClick(last.id, in: snapshot.order)
        } else {
            let from = CMTimeSubtract(piece.start, first.start).seconds
            let to = CMTimeSubtract(piece.end, first.start).seconds
            let slack = first.frameSeconds / 2
            if from <= slack, to >= first.seconds - slack {
                picked.click(first.id)
            } else {
                picked.setRange(of: first.id, from: from, to: to, duration: first.seconds)
            }
        }
        cursor = first.id
        return first.id
    }
}
