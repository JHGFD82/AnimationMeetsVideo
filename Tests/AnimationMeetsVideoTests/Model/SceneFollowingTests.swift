import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private let footage = MediaClip(
    name: "Skate", kind: .video, url: nil, duration: seconds(10),
    frameRate: 24, colorSpace: .rec709, codecName: "H.264"
)

/// A project with one clip of the footage, trimmed to 1–5 s and placed at
/// 2 s on Main; `change` sets the clip up.
private func project(_ change: (inout TimelineClip) -> Void = { _ in }) -> (EditingProject, TimelineClip) {
    var project = EditingProject.empty
    project.addMedia(footage)
    var clip = TimelineClip(source: .media(footage.id), startOffset: seconds(2), trimStart: seconds(1), trimEnd: seconds(5))
    change(&clip)
    project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
    return (project, clip)
}

private func clips(_ project: EditingProject) -> [TimelineClip] {
    project.timelines[0].layers[0].clips.sorted { $0.startOffset < $1.startOffset }
}

/// Volume keyframes at these seconds of the footage, each a step louder.
private func volume(at times: [Double]) -> AnimatedValue<Double> {
    var value = AnimatedValue(0.0)
    value.setAnimated(true, at: seconds(times[0]))
    for (index, time) in times.enumerated() { value.set(Double(index) * -3, at: seconds(time)) }
    return value
}

@Suite struct SceneCutChangeTests {
    @Test func addedAndRemovedCutsAreTheStartsThatDiffer() {
        let old = [SceneRange(start: .zero, end: seconds(2), origin: .auto), SceneRange(start: seconds(2), end: seconds(5), origin: .auto)]
        let new = [
            SceneRange(start: .zero, end: seconds(3), origin: .auto),
            SceneRange(start: seconds(3), end: seconds(4), origin: .manual),
            SceneRange(start: seconds(4), end: seconds(5), origin: .manual),
        ]
        let change = SceneCutChange(from: old, to: new)
        #expect(change.added == [seconds(3), seconds(4)])
        #expect(change.removed == [seconds(2)])
        #expect(SceneCutChange(from: old, to: old).isEmpty)
    }
}

@Suite struct SceneFollowingTests {
    @Test func aClipAcrossANewCutIsSplitThereAndPlaysAsBefore() {
        var (project, clip) = project()
        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }

        let pieces = clips(project)
        #expect(result.split.count == 1 && result.embedded.isEmpty)
        #expect(pieces.count == 2)
        #expect(pieces[0].trimStart == seconds(1) && pieces[0].trimEnd == seconds(3))
        #expect(pieces[1].trimStart == seconds(3) && pieces[1].trimEnd == seconds(5))
        #expect(pieces[0].startOffset == clip.startOffset)
        #expect(pieces[1].startOffset == seconds(4))
        #expect(pieces[1].endOffset == clip.endOffset)
        #expect(project.timelines.count == 1)
    }

    @Test func clipsOutsideTheCutAndSoundOnItsOwnStayWhole() {
        var (project, _) = project()
        var sound = TimelineClip(source: .media(footage.id), startOffset: seconds(2), trimStart: seconds(1), trimEnd: seconds(5))
        sound.streams = .audio
        project.timelines[0].layers.append(TimelineLayer(customName: nil, kind: .sound, clips: [sound]))
        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(8)) }
        #expect(result == SceneFollowResult())
        project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }
        #expect(project.timelines[0].layers[1].clips == [sound])
    }

    @Test func keyframesOnOneSideOfTheCutStillSplit() {
        var (project, _) = project { $0.volume = volume(at: [1.5, 2.5]) }
        #expect(project.clipsAnimated(across: [seconds(3)], ofAsset: footage.id).isEmpty)
        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }
        #expect(result.split.count == 1)
        #expect(clips(project).count == 2)
    }

    @Test func aClipAnimatedAcrossTheCutPlaysANewTimelineSplitThere() throws {
        var (project, clip) = project { $0.volume = volume(at: [1.5, 3.5]) }
        let animated = project.clipsAnimated(across: [seconds(3)], ofAsset: footage.id)
        #expect(animated == [ClipLocation(timelineID: project.timelines[0].id, layerID: project.timelines[0].layers[0].id, clipID: clip.id)])

        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }

        #expect(result.embedded.count == 1 && result.split.isEmpty)
        let outer = try #require(clips(project).first)
        #expect(clips(project).count == 1)
        // The clip keeps its ID, place and animation, moved into the new
        // timeline's time, which starts where the trim did.
        #expect(outer.id == clip.id)
        #expect(outer.startOffset == clip.startOffset && outer.endOffset == clip.endOffset)
        #expect(outer.trimStart == .zero && outer.trimEnd == seconds(4))
        #expect(outer.volume.keyframes.map(\.time) == [seconds(0.5), seconds(2.5)])
        guard case .timeline(let nestedID) = outer.source else {
            Issue.record("The clip doesn't play a timeline")
            return
        }
        let nested = try #require(project.timeline(id: nestedID))
        #expect(nested.frameRate == project.timelines[0].frameRate)
        let inner = nested.layers[0].clips.sorted { $0.startOffset < $1.startOffset }
        #expect(inner.count == 2)
        #expect(inner[0].trimStart == seconds(1) && inner[0].trimEnd == seconds(3) && inner[0].startOffset == .zero)
        #expect(inner[1].trimStart == seconds(3) && inner[1].trimEnd == seconds(5) && inner[1].startOffset == seconds(2))
        #expect(inner.allSatisfy { !$0.volume.isAnimated && $0.effects.isEmpty })
        // A later cut inside it splits the clips in the new timeline.
        project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(4)) }
        #expect(project.timeline(id: nestedID)?.layers[0].clips.count == 3)
    }

    @Test func clipsMetAtARemovedCutAreJoinedBack() {
        var (project, clip) = project { $0.volume = volume(at: [1.5, 2.5]) }
        project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }
        #expect(clips(project).count == 2)

        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) {
            $0.removeCut(SceneCut(time: seconds(3), origin: .manual))
        }

        #expect(result.joined == 1)
        let joined = clips(project)
        #expect(joined.count == 1)
        var expected = clip
        expected.id = joined[0].id
        #expect(joined[0] == expected)
    }

    @Test func differentValuesHoldUpToTheCutAndChangeAtIt() throws {
        let (base, _) = project()
        var project = base
        var first = TimelineClip(source: .media(footage.id), startOffset: seconds(2), trimStart: seconds(1), trimEnd: seconds(3))
        first.volume = AnimatedValue(-6)
        var second = TimelineClip(source: .media(footage.id), startOffset: seconds(4), trimStart: seconds(3), trimEnd: seconds(5))
        second.volume = volume(at: [4, 4.5])
        project.timelines[0].layers[0].clips = [first, second]
        project.editScenes(ofAsset: footage.id) { $0.addCut(at: seconds(3)) }

        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) {
            $0.removeCut(SceneCut(time: seconds(3), origin: .manual))
        }

        #expect(result.joined == 1)
        let joined = try #require(clips(project).first)
        #expect(joined.trimStart == seconds(1) && joined.trimEnd == seconds(5))
        let lastFrame = CMTimeSubtract(seconds(3), CMTime(value: 1, timescale: 24))
        let held = try #require(joined.volume.keyframes.first)
        #expect(CMTimeCompare(held.time, lastFrame) == 0 && held.hold && held.value == -6)
        // Each side plays its own value, frame for frame.
        for time in [1.0, 2.5, lastFrame.seconds] { #expect(joined.volume.value(at: seconds(time)) == -6) }
        for time in [3.0, 3.5, 4.0, 4.5, 5.0] {
            #expect(joined.volume.value(at: seconds(time)) == second.volume.value(at: seconds(time)))
        }
    }

    @Test func aTransitionAtTheCutKeepsTheClipsApart() {
        var (project, _) = project()
        project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }
        project.timelines[0].layers[0].clips[1].transitionIn = ClipTransition(kind: .wipe, duration: seconds(0.5))
        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) {
            $0.removeCut(SceneCut(time: seconds(3), origin: .manual))
        }
        #expect(result.joined == 0 && result.keptApart == 1)
        #expect(clips(project).count == 2)
    }

    @Test func clipsWithAGapBetweenThemStayApart() {
        var (project, _) = project()
        project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: seconds(3)) }
        project.timelines[0].layers[0].clips[1].startOffset = seconds(6)
        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) {
            $0.removeCut(SceneCut(time: seconds(3), origin: .manual))
        }
        #expect(result == SceneFollowResult())
        #expect(clips(project).count == 2)
    }
}
