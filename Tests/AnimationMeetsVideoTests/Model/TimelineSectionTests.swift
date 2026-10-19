import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

@Suite struct TimelineSectionTests {
    private func sections(_ project: EditingProject) -> [TimelineSection] {
        project.timeline(id: project.rootTimelineID)!.sections
    }

    @Test func sectionsGetNamesLandOnFramesAndDontOverlap() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let added1 = project.addSection(in: t, from: seconds(0), to: seconds(10.01))
        let intro = try #require(added1)
        // Starts inside the intro: refused. Starts after it but runs into the next: cut short.
        #expect(project.addSection(in: t, from: seconds(5), to: seconds(12)) == nil)
        let added2 = project.addSection(named: "Epilogue", in: t, from: seconds(20), to: seconds(30))
        _ = try #require(added2)
        let added3 = project.addSection(in: t, from: seconds(12), to: seconds(25))
        let middle = try #require(added3)

        let all = sections(project)
        #expect(all.map(\.name) == ["Section 1", "Section 3", "Epilogue"])
        #expect(all.first { $0.id == intro }?.end == seconds(10))
        #expect(all.first { $0.id == middle }?.end == seconds(20))
    }

    @Test func movingAndResizingStopAtTheNeighbors() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let added4 = project.addSection(in: t, from: seconds(0), to: seconds(4))
        let first = try #require(added4)
        let added5 = project.addSection(in: t, from: seconds(10), to: seconds(14))
        let second = try #require(added5)

        project.moveSection(second, in: t, to: seconds(2))
        #expect(sections(project).last?.start == seconds(4))
        project.setSectionEdge(first, edge: .end, in: t, to: seconds(9))
        #expect(sections(project).first?.end == seconds(4))
        project.setSectionEdge(second, edge: .end, in: t, to: seconds(30))
        #expect(sections(project).last?.end == seconds(30))
        project.setSectionEdge(second, edge: .start, in: t, to: seconds(40))
        #expect(sections(project).last?.duration == CMTime(value: 1, timescale: 24))

        project.renameSection(first, in: t, to: "Intro")
        project.deleteSection(second, in: t)
        #expect(sections(project).map(\.name) == ["Intro"])
    }

    @Test func aSectionPastTheFootageLengthensTheTimeline() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.importClip(
            MediaClip(name: "Clip", kind: .video, url: nil, duration: seconds(4), frameRate: 24, colorSpace: .rec709, codecName: "H.264"),
            intoTimeline: t
        )
        #expect(project.timeline(id: t)?.duration == seconds(4))
        project.addSection(named: "Epilogue", in: t, from: seconds(4), to: seconds(9))
        #expect(project.timeline(id: t)?.duration == seconds(9))
    }

    @Test func sectionsSurviveSavingAndAreLeftOutWhenThereAreNone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-sections-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        var project = EditingProject.empty
        try await ProjectStore.save(project, to: package)
        let plain = try String(contentsOf: package.appending(path: ProjectStore.projectFileName), encoding: .utf8)
        #expect(!plain.contains("sections"))

        let added6 = project.addSection(named: "Intro", in: project.rootTimelineID, from: .zero, to: seconds(3))
        let id = try #require(added6)
        try await ProjectStore.save(project, to: package)
        let loaded = try await ProjectStore.load(from: package)

        let section = try #require(loaded.project.timeline(id: project.rootTimelineID)?.sections.first)
        #expect(section.id == id && section.name == "Intro" && section.end == seconds(3))
    }

    @Test func aCompositionRunsToTheEndOfTheLastSection() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-sections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "gray.mov")
        try await writeMovie(to: url, segments: [(luma: 128, frames: 48)])

        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.importClip(
            MediaClip(name: "gray", kind: .video, url: url, duration: CMTime(value: 48, timescale: 24), frameRate: 24, colorSpace: .rec709, codecName: "H.264"),
            intoTimeline: t
        )
        project.addSection(named: "Black", in: t, from: seconds(2), to: seconds(5))

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true)

        #expect(composed.composition.duration == seconds(5))
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: seconds(4)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        // Past the footage, the section plays black.
        #expect(pixel[1] < 10)
    }
}
