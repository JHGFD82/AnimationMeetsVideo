import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// `view-state.json`: where each timeline was left, kept in the package.
struct ViewStateFileTests {
    private func package() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-viewstate-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func roundTripsEveryTimelinesPlace() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let main = UUID(), other = UUID()
        let selection = TimelineSelection(timelineID: other, layerID: UUID(), timelineClipID: UUID(), transitionEdge: .trailing)
        var state = ViewState(openTimelineID: other)
        state.timelines[main] = ViewState.Timeline(
            time: CMTime(value: 1001, timescale: 24000), zoomedPixelsPerSecond: 240.5, scrollX: 812, areaOffsets: [.video: 64, .music: 0]
        )
        state.timelines[other] = ViewState.Timeline(time: CMTime(value: 7, timescale: 1), selection: selection, scrollX: 0)

        try ViewStateFile.write(state, to: url)
        #expect(ViewStateFile.read(from: url) == state)
        let text = try String(contentsOf: ViewStateFile.url(in: url), encoding: .utf8)
        #expect(text.contains("\"1001/24000s\""))
    }

    /// A project made before the view state was kept has a `.gitignore`
    /// without it: writing the view state, or preparing the package as a
    /// save does, adds it once, after the person's own lines.
    @Test func anOlderGitignoreComesToListIt() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let ignore = url.appending(path: ".gitignore")
        try "Cache/\nBackups/\n.lock\nmy-notes.txt".write(to: ignore, atomically: true, encoding: .utf8)

        try ViewStateFile.write(ViewState(), to: url)
        try ProjectStore.preparePackage(at: url)
        try ViewStateFile.write(ViewState(), to: url)
        #expect(try String(contentsOf: ignore, encoding: .utf8) == "Cache/\nBackups/\n.lock\nmy-notes.txt\nview-state.json\n")

        // Listed already, with a leading slash: left as it is.
        try "/view-state.json\n".write(to: ignore, atomically: true, encoding: .utf8)
        try ViewStateFile.write(ViewState(), to: url)
        #expect(try String(contentsOf: ignore, encoding: .utf8) == "/view-state.json\n")
    }

    @Test func aPackageWithoutAGitignoreIsLeftWithout() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        try ViewStateFile.write(ViewState(), to: url)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: ".gitignore").path))
    }

    @Test func aMissingDamagedOrNewerFileStartsAfresh() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ViewStateFile.read(from: url) == ViewState())
        try Data("{ not json".utf8).write(to: ViewStateFile.url(in: url))
        #expect(ViewStateFile.read(from: url) == ViewState())
        try Data(#"{"formatVersion": 99, "timelines": {}}"#.utf8).write(to: ViewStateFile.url(in: url))
        #expect(ViewStateFile.read(from: url) == ViewState())
    }

    /// A loop region is kept with its timeline's place (docs/loop-region.md,
    /// "Saving"), on or off, its times exact.
    @Test func roundTripsALoopRegion() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let main = UUID(), other = UUID()
        var state = ViewState(openTimelineID: main)
        state.timelines[main] = ViewState.Timeline(
            loop: LoopRegion(start: CMTime(value: 12 * 1001, timescale: 24000), end: CMTime(value: 16, timescale: 1))
        )
        state.timelines[other] = ViewState.Timeline(
            loop: LoopRegion(start: .zero, end: CMTime(value: 3, timescale: 1), isOn: false, color: BarColor(0xB897F0))
        )

        try ViewStateFile.write(state, to: url)
        #expect(ViewStateFile.read(from: url) == state)
        let text = try String(contentsOf: ViewStateFile.url(in: url), encoding: .utf8)
        #expect(text.contains("\"12012/24000s\""))
        // The loop's own color is kept with it; the default is left out.
        #expect(text.contains("\"#B897F0\""))
        #expect(text.components(separatedBy: "\"color\"").count == 2)
    }

    /// A file from before loop regions reads as none; a damaged region is
    /// dropped, and the rest of the file still reads.
    @Test func aMissingOrDamagedLoopReadsAsNone() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let ids = (0..<6).map { _ in UUID().uuidString }
        let place = #""playhead": "2s", "scroll": 0, "areaScroll": {}"#
        let json = """
        {"formatVersion": 1, "openTimeline": "\(ids[0])", "timelines": {
          "\(ids[0])": {\(place)},
          "\(ids[1])": {\(place), "loop": {"start": "8s", "end": "4s", "on": true}},
          "\(ids[2])": {\(place), "loop": {"start": "soon", "end": "4s"}},
          "\(ids[3])": {\(place), "loop": 5},
          "\(ids[4])": {\(place), "loop": {"start": "1/2s", "end": "4s"}},
          "\(ids[5])": {\(place), "loop": null}
        }}
        """
        try Data(json.utf8).write(to: ViewStateFile.url(in: url))
        let state = ViewStateFile.read(from: url)
        #expect(state.timelines.count == 6)
        for (index, text) in ids.enumerated() {
            let id = try #require(UUID(uuidString: text))
            let kept = try #require(state.timelines[id])
            #expect(kept.time == CMTime(value: 2, timescale: 1))
            if index == 4 {
                // Read whole, and on when the file doesn't say.
                #expect(kept.loop == LoopRegion(start: CMTime(value: 1, timescale: 2), end: CMTime(value: 4, timescale: 1)))
            } else {
                #expect(kept.loop == nil)
            }
        }
    }

    @Test func roundTripsWhatTheBrowserRemembers() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = UUID(), timeline = UUID()
        var state = ViewState()
        state.browser.clipRanges = [
            .asset(asset): SecondsSpan(start: 1.5, end: 3),
            .scene(asset: asset, scene: "1001/24000"): SecondsSpan(start: 0, end: 0.5),
        ]
        state.browser.timelineRanges = [timeline: SecondsSpan(start: 2, end: 4)]
        state.browser.collapsedTimelines = [timeline]

        try ViewStateFile.write(state, to: url)
        #expect(ViewStateFile.read(from: url) == state)
    }

    /// A file written before the browser remembered anything reads as
    /// remembering nothing; with nothing to remember, none is written.
    @Test func aFileWithoutTheBrowsersPartStillReads() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let main = UUID()
        var state = ViewState()
        state.timelines[main] = ViewState.Timeline(scrollX: 40)
        try ViewStateFile.write(state, to: url)
        let text = try String(contentsOf: ViewStateFile.url(in: url), encoding: .utf8)
        #expect(!text.contains("browser"))
        let read = ViewStateFile.read(from: url)
        #expect(read.timelines[main]?.scrollX == 40)
        #expect(read.browser == ViewState.Browser())
    }

    @Test func damagedRangesAreLeftOut() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let assetID = UUID(), asset = assetID.uuidString
        let scene = BrowserItemID.scene(asset: assetID, scene: "600/600")
        let file = """
            {"formatVersion": 1, "timelines": {}, "browser": {"clipRanges": {
            "\(asset)": {"start": 4, "end": 2}, "nonsense": {"start": 0, "end": 1}, "\(asset)#600/600": {"start": 0, "end": 1}}}}
            """
        try Data(file.utf8).write(to: ViewStateFile.url(in: url))
        let read = ViewStateFile.read(from: url)
        #expect(read.browser.clipRanges.count == 1)
        #expect(read.browser.clipRanges[scene] == SecondsSpan(start: 0, end: 1))
    }
}
