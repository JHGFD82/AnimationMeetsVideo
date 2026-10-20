import CoreGraphics
import Foundation

/// A window-coordinate frame a view keeps up to date, in a box so that
/// recording it doesn't redraw the view.
@MainActor
final class FrameBox {
    var frame: CGRect = .zero
}

/// Where a clip dropped on another layer was let go (where its start was
/// drawn, in window coordinates), for the block that shows it there to
/// arrive from. The block that was dragged belongs to the layer the clip
/// left, and is gone once the edit lands, so the new one takes up the
/// motion from where the old one was.
@MainActor
final class ClipFlights {
    static let shared = ClipFlights()

    /// How long after a drop a clip's new block still arrives from it.
    private static let lifetime: TimeInterval = 1.5

    private var departed: [UUID: (start: CGPoint, at: Date)] = [:]

    func depart(_ clipID: UUID, from start: CGPoint) {
        departed[clipID] = (start, Date())
    }

    /// Where the clip was let go, once; nil if it wasn't, or long ago.
    func arrive(_ clipID: UUID) -> CGPoint? {
        guard let flight = departed.removeValue(forKey: clipID) else { return nil }
        return Date().timeIntervalSince(flight.at) < Self.lifetime ? flight.start : nil
    }
}
