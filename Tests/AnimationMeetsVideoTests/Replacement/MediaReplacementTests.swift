import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ReplaceMediaTests {
    private func makeProject() -> (project: EditingProject, assetID: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: URL(fileURLWithPath: "/proxy/m.mov"),
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "ProRes Proxy"
        )
        let ids = project.importClip(media, intoTimeline: project.rootTimelineID)!
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        let l = project.timelines[t].layers.firstIndex { $0.id == ids.layerID }!
        project.timelines[t].layers[l].clips[0].trimStart = CMTime(seconds: 2, preferredTimescale: 600)
        project.timelines[t].layers[l].clips[0].trimEnd = CMTime(seconds: 5, preferredTimescale: 600)
        return (project, media.id)
    }

    private func replacement(_ path: String, codec: String = "ProRes 422") -> MediaClip {
        MediaClip(
            name: "ignored", kind: .video, url: URL(fileURLWithPath: path),
            duration: CMTime(seconds: 10.5, preferredTimescale: 600),
            frameRate: 25, colorSpace: .rec709, codecName: codec, hasAudio: true
        )
    }

    @Test func usedRangesComeFromEveryClipOfTheAsset() {
        var (project, assetID) = makeProject()
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        let extra = TimelineClip(
            source: .media(assetID), startOffset: CMTime(seconds: 9, preferredTimescale: 600),
            trimStart: CMTime(seconds: 7, preferredTimescale: 600), trimEnd: CMTime(seconds: 8, preferredTimescale: 600)
        )
        project.timelines[t].layers[0].clips.append(extra)

        let ranges = project.usedRanges(ofMedia: assetID)

        #expect(ranges.count == 2)
        #expect(ranges.contains(CMTimeRange(start: CMTime(seconds: 7, preferredTimescale: 600), end: CMTime(seconds: 8, preferredTimescale: 600))))
        #expect(project.usedRanges(ofMedia: UUID()).isEmpty)
    }

    @Test func replacingKeepsTheAssetIDAndEverythingThatUsesIt() {
        var (project, assetID) = makeProject()
        let before = project.timelines

        project.replaceMedia(id: assetID, with: replacement("/full/m.mov"), offset: CMTime(value: 1, timescale: 24))

        let asset = project.mediaClip(id: assetID)
        #expect(asset?.url?.path == "/full/m.mov")
        #expect(asset?.codecName == "ProRes 422")
        #expect(asset?.name == "m")
        #expect(asset?.alignmentOffset == CMTime(value: 1, timescale: 24))
        #expect(asset?.previousPaths == ["/proxy/m.mov"])
        #expect(project.timelines == before)
    }

    @Test func goingBackToAnEarlierFileSwapsThePaths() {
        var (project, assetID) = makeProject()
        project.replaceMedia(id: assetID, with: replacement("/full/m.mov"), offset: .zero)
        project.replaceMedia(id: assetID, with: replacement("/proxy/m.mov"), offset: .zero)

        let asset = project.mediaClip(id: assetID)
        #expect(asset?.url?.path == "/proxy/m.mov")
        #expect(asset?.previousPaths == ["/full/m.mov"])
    }

    @Test func replacingWithTheSameFileAddsNoHistory() {
        var (project, assetID) = makeProject()
        project.replaceMedia(id: assetID, with: replacement("/proxy/m.mov"), offset: .zero)
        #expect(project.mediaClip(id: assetID)?.previousPaths == [])
    }

    @Test func anUnknownAssetIsIgnored() {
        var (project, _) = makeProject()
        let before = project
        project.replaceMedia(id: UUID(), with: replacement("/full/m.mov"), offset: .zero)
        #expect(project == before)
    }
}

@Suite struct BulkReplacementMatcherTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func matchesByNameIgnoringCase() {
        let a = UUID()
        let result = BulkReplacementMatcher.matches(
            for: [(a, ["Interview.mov"])],
            among: [url("/full/INTERVIEW.MOV"), url("/full/other.mov")]
        )
        #expect(result == [.init(assetID: a, url: url("/full/INTERVIEW.MOV"))])
    }

    @Test func fallsBackToTheOriginalFileName() {
        let a = UUID()
        let result = BulkReplacementMatcher.matches(
            for: [(a, ["proxy_a.mov", "a.mov"])],
            among: [url("/full/a.mov")]
        )
        #expect(result.map(\.url) == [url("/full/a.mov")])
    }

    @Test func acceptsADifferentExtensionWhenItIsUnique() {
        let a = UUID()
        let result = BulkReplacementMatcher.matches(for: [(a, ["clip.mp4"])], among: [url("/full/clip.mov")])
        #expect(result.map(\.url) == [url("/full/clip.mov")])
    }

    @Test func ambiguousNamesAreLeftOut() {
        let a = UUID()
        let twoFolders = BulkReplacementMatcher.matches(
            for: [(a, ["clip.mov"])],
            among: [url("/one/clip.mov"), url("/two/clip.mov")]
        )
        #expect(twoFolders.isEmpty)
        let twoExtensions = BulkReplacementMatcher.matches(
            for: [(a, ["clip.mp4"])],
            among: [url("/full/clip.mov"), url("/full/clip.mxf")]
        )
        #expect(twoExtensions.isEmpty)
    }

    @Test func oneFileIsNotGivenToTwoAssets() {
        let a = UUID(), b = UUID()
        let result = BulkReplacementMatcher.matches(
            for: [(a, ["clip.mov"]), (b, ["clip.mp4"])],
            among: [url("/full/clip.mov")]
        )
        #expect(result.map(\.assetID) == [a])
    }

    @Test func assetsWithNoMatchAreSkipped() {
        let result = BulkReplacementMatcher.matches(for: [(UUID(), ["missing.mov"])], among: [url("/full/clip.mov")])
        #expect(result.isEmpty)
    }
}
