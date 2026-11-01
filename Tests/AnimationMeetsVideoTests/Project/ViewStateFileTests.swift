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

    @Test func aMissingDamagedOrNewerFileStartsAfresh() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ViewStateFile.read(from: url) == ViewState())
        try Data("{ not json".utf8).write(to: ViewStateFile.url(in: url))
        #expect(ViewStateFile.read(from: url) == ViewState())
        try Data(#"{"formatVersion": 99, "timelines": {}}"#.utf8).write(to: ViewStateFile.url(in: url))
        #expect(ViewStateFile.read(from: url) == ViewState())
    }
}
