import CoreMedia
import Foundation

/// The timeline's owner, which carries out what it asks for. One object
/// rather than a closure for each action: the timeline compares it by
/// identity, where closures made anew at each redraw of the owner can't
/// be compared at all.
@MainActor
protocol TimelineHost: AnyObject {
    func dispatch(_ action: TimelineAction)
    /// Scenes dropped on a layer at a time, or with no layer, onto a new
    /// layer of the given kind (the asset's default kind when nil).
    /// Returns whether they were placed.
    func dropScenes(_ payloads: [MediaDragPayload], onLayer: UUID?, at: CMTime, kind: LayerKind?) -> Bool
    /// Files dragged in from the Finder: imported, then placed as media
    /// dropped there would be, onto the layer if given, else onto a new
    /// layer of the kind.
    func dropFiles(_ urls: [URL], onLayer: UUID?, at: CMTime, kind: LayerKind?)
    /// The assets' scene scores (`AssetAnalysis.tracks`), read as a trim is
    /// dragged so its edge stops at a cut.
    func sceneTracks() -> [UUID: ChangeScoreTrack]
    /// The project as it is now, for what runs later than the redraw that
    /// made it: the Edit menu keeps its commands while what they act on
    /// is unchanged, and `project` in them would be as it was then.
    func readProject() -> EditingProject
}
