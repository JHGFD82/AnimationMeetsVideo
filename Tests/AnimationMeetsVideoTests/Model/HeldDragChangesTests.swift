import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A drag's changes put onto the clip as it is now
/// (`TimelineClip.applyingDrag`, code-review-notes.md F26).
@Suite struct HeldDragChangesTests {
    private func clip() throws -> TimelineClip {
        var project = EditingProject.empty
        let made = project.addShapeLayer(.rectangle, to: project.rootTimelineID)
        let placed = try #require(made)
        return try #require(project.clipAndLayer(placed.clipID, in: project.rootTimelineID)?.clip)
    }

    /// A script changes the clip's shape while a handle drag moves it:
    /// both changes are kept, where putting the drag's copy back undid the
    /// script's.
    @Test func aChangeMadeDuringTheDragIsKept() throws {
        let start = try clip()
        var edited = start
        let transform = Effect(kind: .transform)
        edited.effects.append(transform)

        var current = start
        current.enabled = false
        let shapeID = try #require(current.effects.first?.id)
        current.effects[0].name = "Renamed by a script"

        let result = current.applyingDrag(from: start, to: edited)
        #expect(result.enabled == false)
        #expect(result.effect(id: shapeID)?.name == "Renamed by a script")
        #expect(result.effect(id: transform.id) != nil)
    }

    @Test func whatTheDragChangedWins() throws {
        let start = try clip()
        let shapeID = try #require(start.effects.first?.id)
        var edited = start
        edited.effects[0].name = "Dragged"
        let result = start.applyingDrag(from: start, to: edited)
        #expect(result == edited)
        #expect(result.effect(id: shapeID)?.name == "Dragged")
    }
}
