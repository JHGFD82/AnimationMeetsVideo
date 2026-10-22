import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// A splitter open (without a panel) on a ten-second video with hand cuts
/// at `cuts`, editing `project` in place as the editor does.
@MainActor
private final class Harness {
    var project = EditingProject.empty
    let footage: MediaClip
    let splitter = SceneSplitter()

    init(cuts: [Double] = [], clip: ((MediaClip) -> TimelineClip)? = nil) {
        var footage = MediaClip(
            name: "Skate", kind: .video, url: URL(fileURLWithPath: "/nonexistent/skate.mov"), duration: seconds(10),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        footage.sceneEdits.manualCuts = cuts.map(seconds)
        self.footage = footage
        project.addMedia(footage)
        if let clip {
            project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip(footage)])]
        }
        splitter.onEdit = { [unowned self] change in
            change(&project)
            splitter.update(project: project)
        }
        splitter.update(project: project)
    }

    func open(from start: Double, to end: Double) {
        splitter.openWithoutPanel(SceneSplitter.Focus(assetID: footage.id, start: seconds(start), end: seconds(end)))
    }

    var starts: [Double] { splitter.scenes.map(\.start.seconds) }
}

@MainActor
@Suite struct SceneSplitterTests {
    @Test func picksCountButDroppingWhatIsGoneDoesNot() {
        var selection = BrowserSelection<Int>()
        selection.click(1)
        selection.shiftClick(3, in: [1, 2, 3])
        #expect(selection.revision == 2)
        selection.keep(only: [1, 2])
        #expect(selection.revision == 2)
        selection.clear()
        #expect(selection.revision == 3)
    }

    @Test func splittingAtTheMarkerKeepsTheStretchShownAndUndoBringsItBack() {
        let harness = Harness(cuts: [2, 5])
        defer { harness.splitter.skim.end() }
        harness.open(from: 2, to: 5)
        #expect(harness.starts == [2])
        let before = harness.project

        harness.splitter.click(atSeconds: 1.5)
        harness.splitter.split()

        #expect(harness.starts == [2, 3.5])
        #expect(harness.splitter.number(of: harness.splitter.scenes[1]) == 3)
        harness.splitter.update(project: before)
        #expect(harness.starts == [2])
    }

    @Test func skimmingShowsFramesButOnlyAClickOrAStepMovesTheMarker() throws {
        let harness = Harness(cuts: [2, 5])
        defer { harness.splitter.skim.end() }
        harness.open(from: 0, to: 10)
        let splitter = harness.splitter
        #expect(splitter.markerSeconds == 0)

        splitter.hover(atSeconds: 4)
        #expect(splitter.markerSeconds == 0 && splitter.shownSeconds == 4)
        splitter.hover(atSeconds: nil)
        #expect(splitter.shownSeconds == 0)

        splitter.click(atSeconds: 3)
        #expect(splitter.markerSeconds == 3)
        #expect(splitter.selection.items == [seconds(2).sceneID])
        splitter.step(frames: 1)
        let marker = try #require(splitter.markerSeconds)
        #expect(abs(marker - (3 + 1.0 / 24)) < 1e-3)
        splitter.jumpToCut(.next)
        #expect(splitter.markerSeconds == 5)
    }

    @Test func mergeJoinsOnlyScenesSideBySide() {
        let harness = Harness(cuts: [2, 5, 7])
        defer { harness.splitter.skim.end() }
        harness.open(from: 0, to: 10)
        let splitter = harness.splitter

        splitter.click(atSeconds: 1)
        splitter.click(atSeconds: 6, modifiers: .command)
        #expect(splitter.selection.items.count == 2 && splitter.mergeable == nil)
        splitter.merge()
        #expect(harness.starts == [0, 2, 5, 7])

        splitter.click(atSeconds: 3, modifiers: .shift)
        #expect(splitter.mergeable?.map(\.start.seconds) == [2, 5])
        splitter.merge()
        #expect(harness.starts == [0, 2, 7])
        #expect(splitter.selection.items == [seconds(2).sceneID])
    }

    @Test func picksFromTheBrowserSeedTheSelection() {
        let harness = Harness(cuts: [2, 5])
        defer { harness.splitter.skim.end() }
        harness.splitter.openWithoutPanel(
            SceneSplitter.Focus(assetID: harness.footage.id, start: .zero, end: seconds(5)),
            selecting: [CMTime.zero.sceneID, seconds(2).sceneID]
        )
        #expect(harness.splitter.mergeable?.count == 2)
    }

    @Test func splittingAnAnimatedClipWaitsToBeAgreedTo() throws {
        let harness = Harness { footage in
            var clip = TimelineClip(source: .media(footage.id), startOffset: .zero, trimStart: seconds(1), trimEnd: seconds(6))
            clip.volume.setAnimated(true, at: seconds(2))
            clip.volume.set(-12, at: seconds(5))
            return clip
        }
        defer { harness.splitter.skim.end() }
        harness.open(from: 0, to: 10)
        let before = harness.project

        harness.splitter.placeMarker(atSeconds: 3)
        harness.splitter.split()
        let pending = try #require(harness.splitter.pendingEdit)
        #expect(pending.clipCount == 1)
        #expect(harness.project == before)

        harness.splitter.cancelPendingEdit()
        #expect(harness.splitter.pendingEdit == nil && harness.project == before)

        harness.splitter.split()
        harness.splitter.confirmPendingEdit()
        #expect(harness.starts == [0, 3])
        #expect(harness.project.timelines.count == 2)
        guard case .timeline = harness.project.timelines[0].layers[0].clips[0].source else {
            Issue.record("The animated clip wasn't embedded")
            return
        }
    }
}

private extension CMTime {
    /// The ID of the scene starting here.
    var sceneID: String { SceneRange(start: self, end: self, origin: .auto).id }
}
