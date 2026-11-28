import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// ProRes viewer copies (docs/rendering.md, "ProRes viewer copies"): a
/// copy keeps the original's frame times, the stretches wanted are those
/// clips use plus handles, the viewer's build draws from a copy that
/// holds what it plays, and the project keeps the setting.
@MainActor
@Suite(.serialized) struct ViewerCopiesTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    // F96: a record's range was rebuilt from seconds on one timescale, and
    // with ends whose timescales share no multiple that fits (13/24 s, and
    // an end in nanoseconds from a retimed clip), it came back inside the
    // stretch wanted, which then never counted as held and was copied
    // again and again.
    @Test func aRecordHoldsExactlyTheStretchItWasMadeFor() throws {
        let wanted = CMTimeRange(
            start: CMTime(value: 13_000, timescale: 24_000), end: CMTime(value: 25_145_288_549, timescale: 1_000_000_000)
        )
        func record(exact: Bool) throws -> ViewerCopies.Record {
            var fields = """
            "file": "a.mov", "original": "/a.mov", "stamp": {"byteCount": 1},
            "start": \(wanted.start.seconds), "end": \(wanted.end.seconds), "timescale": 1000000000,
            "offsetValue": 0, "offsetTimescale": 600
            """
            if exact {
                fields += ", \"startValue\": 13000, \"startTimescale\": 24000, \"endValue\": 25145288549, \"endTimescale\": 1000000000"
            }
            return try JSONDecoder().decode(ViewerCopies.Record.self, from: Data("{\(fields)}".utf8))
        }
        let made = try record(exact: true)
        #expect(made.isSound)
        #expect(made.range.containsTimeRange(wanted))
        // An index written before still reads, by its seconds, which is
        // where the stretch came back short.
        let older = try record(exact: false)
        #expect(older.isSound)
        #expect(!older.range.containsTimeRange(wanted))
    }

    @Test func aCopyIsProResAtTheOriginalsFrameTimes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-copies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "original.mov")
        try await writeMovie(to: original, segments: [(luma: 40, frames: 24), (luma: 200, frames: 24)])
        let copy = folder.appending(path: "copy.mov")
        let offset = try await ViewerCopies.copy(original, range: CMTimeRange(start: seconds(0.5), end: seconds(1.5)), to: copy) { _ in }
        #expect(abs(offset.seconds - 0.5) < 1e-6)
        let times = try await ViewerCopies.frameTimes(of: copy)
        let originals = try await ViewerCopies.frameTimes(of: original).filter { $0 >= seconds(0.5) && $0 < seconds(1.5) }
        #expect(times.count == 24)
        #expect(zip(times, originals).allSatisfy { abs(CMTimeAdd($0, offset).seconds - $1.seconds) < 1e-6 })
        let track = try #require(try await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422)
    }

    @Test func theStretchesWantedAreThoseUsedWithHandles() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let clip = try await fixture.addClip(luma: 100, frames: 240)
        fixture.project.editClip(clip.clipID, in: fixture.timelineID) { $0.trimStart = self.seconds(4); $0.trimEnd = self.seconds(5) }
        let wanted = ViewerCopies.stretches(in: fixture.project)
        #expect(wanted.count == 1)
        #expect(abs((wanted.first?.range.start.seconds ?? 0) - 1) < 1e-6)
        #expect(abs((wanted.first?.range.end.seconds ?? 0) - 8) < 1e-6)
        // Two overlapping uses are one stretch; ProRes footage is left be.
        #expect(ViewerCopies.merged([
            CMTimeRange(start: seconds(0), end: seconds(2)), CMTimeRange(start: seconds(1), end: seconds(4)),
        ]).count == 1)
        #expect(!ViewerCopies.needsCopy(codec: "ProRes 422"))
    }

    @Test func theViewersBuildDrawsFromACopyHoldingWhatItPlays() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 150, frames: 48)
        let original = try #require(fixture.project.clips.first?.url)
        let copy = fixture.directory.appending(path: "copy.mov")
        let offset = try await ViewerCopies.copy(original, range: CMTimeRange(start: .zero, end: seconds(2)), to: copy) { _ in }
        var index = ViewerCopyIndex()
        index.copies[original.standardizedFileURL] = [.init(range: CMTimeRange(start: .zero, end: seconds(2)), url: copy, offset: offset)]

        let viewer = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, viewerCopies: index
        )
        let source = viewer.composition.tracks(withMediaType: .video).first?.segments.first { !$0.isEmpty }?.sourceURL
        #expect(source?.standardizedFileURL == copy.standardizedFileURL)
        // The same picture as from the original.
        let level = try await grayLevel(of: viewer, at: seconds(1))
        let plain = try await grayLevel(of: try await fixture.build(forPreview: true), at: seconds(1))
        #expect(abs(level - plain) <= 3)
        // Export never draws from one.
        let export = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, viewerCopies: index
        )
        let exported = export.composition.tracks(withMediaType: .video).first?.segments.first { !$0.isEmpty }?.sourceURL
        #expect(exported?.standardizedFileURL == original.standardizedFileURL)
    }

    /// A copy starting partway into the file: the build reads it shifted
    /// by its offset, so each moment shows the same frame as from the
    /// original, dark before the cut at 1 s and light after.
    @Test func aCopyStartingLaterShowsTheSameFrames() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "cut.mov")
        try await writeMovie(to: url, segments: [(luma: 40, frames: 24), (luma: 210, frames: 24)])
        let media = MediaClip(
            name: "cut.mov", kind: .video, url: url, duration: seconds(2), frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = fixture.project.importClip(media, intoTimeline: fixture.timelineID)
        let placed = try #require(imported)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.trimStart = self.seconds(0.5); $0.trimEnd = self.seconds(2) }
        let copy = fixture.directory.appending(path: "copy.mov")
        let range = CMTimeRange(start: seconds(0.5), end: seconds(2))
        let offset = try await ViewerCopies.copy(url, range: range, to: copy) { _ in }
        var index = ViewerCopyIndex()
        index.copies[url.standardizedFileURL] = [.init(range: range, url: copy, offset: offset)]
        let viewer = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, viewerCopies: index
        )
        let plain = try await fixture.build(forPreview: true)
        for moment in [0.25, 0.45, 0.55, 1.2] {
            let fromCopy = try await grayLevel(of: viewer, at: seconds(moment))
            let fromOriginal = try await grayLevel(of: plain, at: seconds(moment))
            #expect(abs(fromCopy - fromOriginal) <= 3, "at \(moment) s")
        }
    }

    @Test func theProjectsCopiesAreMadeAndCanBeDeleted() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 90, frames: 48)
        fixture.project.makesViewerCopies = true
        let copies = ViewerCopies()
        copies.waitsForFreeMachine = false
        copies.packageURL = fixture.directory
        copies.update(project: fixture.project)
        try await waitUntil("a copy to be made", limit: .seconds(20), every: .milliseconds(20)) { !copies.index.isEmpty }
        #expect(copies.bytesOnDisk > 0)
        #expect(ViewerCopies.bytes(in: fixture.directory) > 0)
        // A second window's manager on the project only reads them.
        let second = ViewerCopies()
        second.waitsForFreeMachine = false
        second.packageURL = fixture.directory
        second.update(project: fixture.project)
        #expect(second.index == copies.index)
        second.deleteAll()
        #expect(copies.bytesOnDisk > 0 && ViewerCopies.bytes(in: fixture.directory) > 0)
        // Turned off, the viewer stops drawing from them.
        fixture.project.makesViewerCopies = false
        copies.update(project: fixture.project)
        #expect(copies.index.isEmpty)
        // Project Settings asks the manager making them to delete them.
        NotificationCenter.default.post(name: ViewerCopies.deleteRequested, object: fixture.directory)
        #expect(copies.bytesOnDisk == 0)
        #expect(ViewerCopies.bytes(in: fixture.directory) == 0)
        withExtendedLifetime(second) {}
    }

    /// The index is a file in the package anyone can edit. A record naming
    /// "../../.." as its copy deleted the folder the project is in once
    /// the copy counted as unused; one with times no CMTime holds trapped.
    @Test func anEditedIndexDeletesNothingOutsideItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-copies-\(UUID().uuidString)", directoryHint: .isDirectory)
        let package = root.appending(path: "Cut.amv", directoryHint: .isDirectory)
        let folder = ViewerCopies.folder(in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let beside = root.appending(path: "Beside the project.txt")
        try Data("Keep me".utf8).write(to: beside)
        let record = { (file: String, start: Double) in
            #"{"file":"\#(file)","original":"/nonexistent","stamp":{"byteCount":0},"start":\#(start),"end":1,"timescale":600,"offsetValue":0,"offsetTimescale":600}"#
        }
        let index = "[" + [record("../../..", 0), record("..", 0), record("/tmp", 0), record("big.mov", 1e300)].joined(separator: ",") + "]"
        try Data(index.utf8).write(to: folder.appending(path: "index.json"))

        let copies = ViewerCopies()
        copies.waitsForFreeMachine = false
        copies.packageURL = package
        copies.update(project: .empty)
        #expect(FileManager.default.fileExists(atPath: beside.path))
        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(copies.index.isEmpty)
    }

    @Test func theProjectKeepsTheSetting() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        fixture.project.makesViewerCopies = true
        let package = fixture.directory.appending(path: "Copies.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        #expect(try await ProjectStore.load(from: package).project.makesViewerCopies)
    }
}
