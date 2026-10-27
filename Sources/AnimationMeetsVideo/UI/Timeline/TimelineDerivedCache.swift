import CoreMedia
import Foundation

/// What the timeline works out from the whole project, kept until the
/// project is edited (`EditingProject.editCount`) rather than worked out
/// again on every redraw: the project's structure for the rows to compare,
/// and what edges snap to. Each walks every clip.
///
/// A project never stamped (count 0, as in previews and tests) is worked
/// out every time, since its count says nothing about what it holds.
@MainActor
@Observable
final class TimelineDerivedCache {
    private struct StructureKey: Equatable {
        var editCount: UInt64
        var timelineID: UUID
    }

    private struct SnapKey: Equatable {
        var editCount: UInt64
        var timelineID: UUID
        /// The zoom, which thins the beat markers drawn.
        var pixelsPerSecond: CGFloat
        /// Which beat markers there are, which another beat layer changes
        /// without an edit.
        var markersVersion: UInt64
    }

    // Written as bodies read them, so not watched: a write would ask for
    // the redraw that is under way.
    @ObservationIgnored private var structureKey: StructureKey?
    @ObservationIgnored private var structure: EditingProject?
    @ObservationIgnored private var snapKey: SnapKey?
    @ObservationIgnored private var snapTargets: SnapTargets?

    func structure(of project: EditingProject, withoutClipsIn timelineID: UUID) -> EditingProject {
        let key = StructureKey(editCount: project.editCount, timelineID: timelineID)
        if project.editCount != 0, key == structureKey, let structure { return structure }
        let built = project.structure(withoutClipsIn: timelineID)
        structureKey = key
        structure = built
        return built
    }

    /// `markers` are the beat markers drawn at `pixelsPerSecond`, and
    /// `markersVersion` says which markers they were drawn from: the same
    /// version and zoom are taken to give the same markers.
    func snapTargets(
        of project: EditingProject,
        in timelineID: UUID,
        live: LivePlayhead,
        markers: @autoclosure () -> [CMTime],
        markersVersion: UInt64,
        pixelsPerSecond: CGFloat
    ) -> SnapTargets {
        let key = SnapKey(
            editCount: project.editCount, timelineID: timelineID, pixelsPerSecond: pixelsPerSecond, markersVersion: markersVersion
        )
        if project.editCount != 0, key == snapKey, let snapTargets, snapTargets.playhead === live { return snapTargets }
        let built = project.snapTargets(in: timelineID, playhead: nil, live: live, markers: markers())
        snapKey = key
        snapTargets = built
        return built
    }

    func invalidate() {
        structureKey = nil
        structure = nil
        snapKey = nil
        snapTargets = nil
    }
}
