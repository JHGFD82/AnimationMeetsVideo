import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// Keyframes a Keyframe Designer method made, which the project's state
/// keeps from being changed by hand until they are baked
/// (`ProjectState.Refusal.drivenKeyframes`).
@MainActor
struct DrivenKeyframesRefusalTests {
    /// A four-second clip whose Transform's Position an Oscillator drives.
    @MainActor private struct Fixture {
        let state: ProjectState
        let timelineID: UUID
        let clipID: UUID
        let transformID: UUID
        let driverID: UUID
        let refusals: () -> [ProjectState.Refusal]

        init() throws {
            var project = EditingProject.empty
            let media = MediaClip(
                name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
                colorSpace: .rec709, codecName: "H.264"
            )
            let timelineID = project.rootTimelineID
            let imported = project.importClip(media, intoTimeline: timelineID)
            let clipID = try #require(imported).clipID
            project.editClip(clipID, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
            let added = project.addEffect(.transform, toClip: clipID, in: timelineID)
            let transformID = try #require(added)
            let position = try #require(project.clipAndLayer(clipID, in: timelineID)?.clip.effect(id: transformID)?.control(.position))
            let made = project.setKeyframing(
                .oscillator, driving: .control(effectID: transformID, controlID: position.id), onClip: clipID, in: timelineID
            )
            driverID = try #require(made)
            let state = ProjectState(project)
            var refused: [ProjectState.Refusal] = []
            state.onRefused = { refused.append($0) }
            refusals = { refused }
            self.state = state
            self.timelineID = timelineID
            self.clipID = clipID
            self.transformID = transformID
        }

        var position: AnimatedValue<ComponentValue>? {
            state.value.clipAndLayer(clipID, in: timelineID)?.clip.effect(id: transformID)?.control(.position)?.number
        }

        /// Sets a keyframe on the driven Position, as a field or the
        /// graph would.
        func keyByHand() {
            let transformID = transformID
            state.value.editClip(clipID, in: timelineID) { clip in
                guard let e = clip.effects.index(of: transformID),
                      let c = clip.effects[e].controls.firstIndex(where: { $0.kind == .position })
                else { return }
                clip.effects[e].controls[c].setComponent(0, to: 500, at: seconds(1))
            }
        }
    }

    @Test func aHandEditOfADrivenControlIsRefusedAndSaysWhich() throws {
        let f = try Fixture()
        let made = f.state.value
        f.keyByHand()
        #expect(f.state.value == made)
        let refusals = f.refusals()
        #expect(refusals.count == 1)
        guard case .drivenKeyframes(let edit)? = refusals.first else {
            Issue.record("Refused for another reason: \(refusals)")
            return
        }
        #expect(edit.effectID == f.driverID)
        #expect(edit.clipID == f.clipID)
        #expect(edit.methodName == EffectKind.oscillator.name)
    }

    @Test func theMethodsSettingsAndTheRestOfTheProjectStayEditable() throws {
        let f = try Fixture()
        let made = f.position
        f.state.value.editEffect(f.driverID, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.changeControl(.amplitude) { $0.setComponent(0, to: 20, at: .zero) }
        }
        #expect(f.position != made)
        f.state.value.name = "Renamed"
        f.state.value.editClip(f.clipID, in: f.timelineID) { $0.startOffset = seconds(1) }
        #expect(f.state.value.name == "Renamed")
        #expect(f.refusals().isEmpty)
    }

    @Test func bakedKeyframesAreEditedByHand() throws {
        let f = try Fixture()
        f.state.value.bakeKeyframing(f.driverID, ofClip: f.clipID, in: f.timelineID)
        let baked = f.position
        f.keyByHand()
        #expect(f.position != baked)
        #expect(f.refusals().isEmpty)
    }

    @Test func takingTheMethodAwayFreesTheControlToo() throws {
        let f = try Fixture()
        let position = try #require(f.state.value.clipAndLayer(f.clipID, in: f.timelineID)?.clip.effect(id: f.transformID)?.control(.position))
        f.state.value.setKeyframing(
            nil, driving: .control(effectID: f.transformID, controlID: position.id), onClip: f.clipID, in: f.timelineID
        )
        let own = f.position
        f.keyByHand()
        #expect(f.position != own)
        #expect(f.refusals().isEmpty)
    }

    @Test func undoAndWhatFollowsFromAnEditAreTaken() throws {
        let f = try Fixture()
        let made = f.position
        // A step put back by undo or redo was made before.
        f.state.writeRestored { f.keyByHand() }
        let restored = f.position
        #expect(restored != made)
        f.state.writeDerived {
            f.state.value.editClip(f.clipID, in: f.timelineID) { $0.shiftKeyframes(by: seconds(0.25)) }
        }
        #expect(f.position != restored)
        #expect(f.refusals().isEmpty)
    }

    @Test func aHeldDragOfADrivenKeyframeIsRefusedToo() throws {
        let f = try Fixture()
        f.state.beginHold()
        f.state.hold { f.keyByHand() }
        #expect(f.state.held == nil)
        #expect(f.refusals().count == 1)
    }
}
