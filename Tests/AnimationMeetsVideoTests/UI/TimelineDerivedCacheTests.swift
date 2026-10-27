import CoreMedia
import Testing
@testable import AnimationMeetsVideo

@MainActor
struct TimelineDerivedCacheTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    /// A stamped project with a section, so there is something to snap to.
    private func project() -> ProjectState {
        let state = ProjectState(.empty)
        _ = state.value.addSection(in: state.value.rootTimelineID, from: seconds(1), to: seconds(3))
        return state
    }

    @Test func theSameEditGivesBackTheStructureItKept() {
        let state = project()
        let cache = TimelineDerivedCache()
        let id = state.value.rootTimelineID
        let first = cache.structure(of: state.value, withoutClipsIn: id)
        // A different project with the same stamp would be handed the kept
        // one: the count, not the contents, decides.
        var sameStamp = state.value
        sameStamp.name = "Not compared"
        #expect(cache.structure(of: sameStamp, withoutClipsIn: id).name == first.name)
    }

    @Test func anEditBuildsTheStructureAgain() {
        let state = project()
        let cache = TimelineDerivedCache()
        let id = state.value.rootTimelineID
        _ = cache.structure(of: state.value, withoutClipsIn: id)
        state.value.name = "Renamed"
        #expect(cache.structure(of: state.value, withoutClipsIn: id).name == "Renamed")
    }

    @Test func anUnstampedProjectIsNeverKept() {
        let cache = TimelineDerivedCache()
        var plain = EditingProject.empty
        let id = plain.rootTimelineID
        _ = cache.structure(of: plain, withoutClipsIn: id)
        plain.name = "Changed"
        #expect(cache.structure(of: plain, withoutClipsIn: id).name == "Changed")
    }

    @Test func snapTargetsAreKeptUntilAnEditTheZoomOrTheMarkersChange() throws {
        let state = project()
        let cache = TimelineDerivedCache()
        let live = LivePlayhead()
        let id = state.value.rootTimelineID
        let first = cache.snapTargets(of: state.value, in: id, live: live, markers: [], markersVersion: 1, pixelsPerSecond: 10)
        #expect(first.targets.map(\.time).contains(seconds(3)))

        // Kept: the same stamp, markers version and zoom get the targets
        // already built, whatever the project or markers handed in.
        var sameStamp = state.value
        sameStamp.timelines[0].sections = []
        let kept = cache.snapTargets(of: sameStamp, in: id, live: live, markers: [seconds(9)], markersVersion: 1, pixelsPerSecond: 10)
        #expect(kept == first)

        // Built again for new markers, a new zoom and a new edit.
        let marked = cache.snapTargets(of: state.value, in: id, live: live, markers: [seconds(5)], markersVersion: 2, pixelsPerSecond: 10)
        #expect(marked.targets.map(\.time).contains(seconds(5)))
        let zoomed = cache.snapTargets(of: sameStamp, in: id, live: live, markers: [seconds(5)], markersVersion: 2, pixelsPerSecond: 20)
        #expect(!zoomed.targets.map(\.time).contains(seconds(3)))
        let sectionID = try #require(state.value.timelines[0].sections.first?.id)
        state.value.deleteSection(sectionID, in: id)
        let edited = cache.snapTargets(of: state.value, in: id, live: live, markers: [seconds(5)], markersVersion: 2, pixelsPerSecond: 20)
        #expect(!edited.targets.map(\.time).contains(seconds(3)))
    }

    @Test func keptSnapTargetsDontWorkOutTheMarkers() {
        let state = project()
        let cache = TimelineDerivedCache()
        let live = LivePlayhead()
        let id = state.value.rootTimelineID
        var drawn = 0
        func markers() -> [CMTime] {
            drawn += 1
            return []
        }
        _ = cache.snapTargets(of: state.value, in: id, live: live, markers: markers(), markersVersion: 1, pixelsPerSecond: 10)
        _ = cache.snapTargets(of: state.value, in: id, live: live, markers: markers(), markersVersion: 1, pixelsPerSecond: 10)
        #expect(drawn == 1)
    }

    @Test func invalidatingDropsWhatWasKept() {
        let state = project()
        let cache = TimelineDerivedCache()
        let id = state.value.rootTimelineID
        _ = cache.structure(of: state.value, withoutClipsIn: id)
        cache.invalidate()
        var sameStamp = state.value
        sameStamp.name = "After invalidating"
        #expect(cache.structure(of: sameStamp, withoutClipsIn: id).name == "After invalidating")
    }
}
