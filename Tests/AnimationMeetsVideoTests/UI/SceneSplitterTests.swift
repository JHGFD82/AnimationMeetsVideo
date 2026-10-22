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

    @Test func splittingKeepsTheStretchShownAndUndoBringsItBack() {
        let harness = Harness(cuts: [2, 5])
        defer { harness.splitter.skim.end() }
        harness.open(from: 2, to: 5)
        #expect(harness.starts == [2])
        let before = harness.project

        harness.splitter.skim(toSeconds: 1.5)
        harness.splitter.split()

        #expect(harness.starts == [2, 3.5])
        #expect(harness.splitter.number(of: harness.splitter.scenes[1]) == 3)
        harness.splitter.update(project: before)
        #expect(harness.starts == [2])
    }

    @Test func mergingAcrossTheStretchsEdgeWidensIt() {
        let harness = Harness(cuts: [2, 5])
        defer { harness.splitter.skim.end() }
        harness.open(from: 2, to: 5)
        #expect(harness.splitter.cut(toMerge: .previous) != nil)

        harness.splitter.merge(.previous)

        #expect(harness.starts == [0])
        #expect(harness.splitter.span?.end == seconds(5))
        // The first scene of the file has nothing before it to join.
        #expect(harness.splitter.cut(toMerge: .previous) == nil)
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

        harness.splitter.skim(toSeconds: 3)
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
