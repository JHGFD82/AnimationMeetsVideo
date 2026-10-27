import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// What the viewer's item is built again for (`StructureKey`), and what it
/// draws as it is, with the values patched in (`LiveValues`).
@Suite struct StructureKeyTests {
    private func project() -> (EditingProject, UUID, UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: URL(fileURLWithPath: "/tmp/none.mov"), duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)!
        return (project, project.rootTimelineID, placed.clipID)
    }

    @Test func effectValuesAndTheAnchorPointKeepTheKey() throws {
        let (before, tl, clip) = project()
        var after = before
        after.editClip(clip, in: tl) { clip in
            clip.anchorPoint = AnimatedValue(Vector2(x: 10, y: -4))
            for effect in clip.effects.indices {
                for index in clip.effects[effect].controls.indices where clip.effects[effect].controls[index].kind == .opacity {
                    clip.effects[effect].controls[index].number = AnimatedValue(ComponentValue(values: [25]))
                }
            }
        }
        #expect(after != before)
        #expect(StructureKey(project: after) == StructureKey(project: before))
        #expect(CompositionKey(project: after) != CompositionKey(project: before))
    }

    @Test func movingRetimingOrRemovingAnEffectChangesIt() throws {
        let (before, tl, clip) = project()
        var moved = before
        moved.editClip(clip, in: tl) { $0.startOffset = CMTime(value: 1, timescale: 1) }
        #expect(StructureKey(project: moved) != StructureKey(project: before))

        var retimed = before
        retimed.editClip(clip, in: tl) { $0.time.speed = AnimatedValue(50) }
        #expect(StructureKey(project: retimed) != StructureKey(project: before))
        #expect(StructureKey(project: retimed).differsOnlyInSpeed(from: StructureKey(project: before)))

        var bare = before
        bare.editClip(clip, in: tl) { $0.effects.removeAll() }
        if bare != before { #expect(StructureKey(project: bare) != StructureKey(project: before)) }
    }

    /// Mono sound panned off center plays from a stereo copy, which the item
    /// is built with; the pan's amount is heard as it plays.
    @Test func aPanOffCenterChangesItAndItsAmountDoesNot() {
        let (before, tl, clip) = project()
        var left = before
        left.editClip(clip, in: tl) { $0.pan = AnimatedValue(-0.5) }
        var further = before
        further.editClip(clip, in: tl) { $0.pan = AnimatedValue(-0.9) }
        #expect(StructureKey(project: left) != StructureKey(project: before))
        #expect(StructureKey(project: left) == StructureKey(project: further))
    }
}
