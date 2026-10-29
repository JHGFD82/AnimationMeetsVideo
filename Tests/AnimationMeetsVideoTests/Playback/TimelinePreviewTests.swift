import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The browser's previews of timelines: made again only when what a
/// timeline draws changes, with frames from its own composition, and
/// skimmed as clips are.
@MainActor
@Suite struct TimelinePreviewTests {
    @Test func aPreviewIsKeptUntilWhatItDrawsChanges() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let size = fixture.project.timelines[0].frameSize
        let inner = fixture.project.addTimeline(name: "Inner", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let other = fixture.project.addTimeline(name: "Other", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let clip = try await fixture.addClip(luma: 60, to: inner)
        _ = try await fixture.addClip(luma: 60, to: other)
        _ = fixture.project.embedTimeline(inner, intoTimeline: fixture.timelineID)
        let ids = [fixture.timelineID, inner, other]

        let previews = TimelinePreviews(settleDelay: .milliseconds(40))
        defer { previews.releaseAll() }
        // Waits for the rebuilds themselves: a fixed sleep lost the race
        // whenever the main actor was busy, as it is with the whole suite
        // running.
        func settle() async { await previews.settle() }
        let first = previews.previews(of: ids, in: fixture.project)
        #expect(first.count == 3)

        // A value edit to Other (which the browser isn't redrawn for) comes
        // from the editor; once it settles, Other is built again and Main
        // and Inner are left as they were.
        let otherClip = try #require(fixture.project.timeline(id: other)?.layers.first?.clips.first?.id)
        fixture.setTransform([(.opacity, [50])], ofClip: otherClip, in: other)
        // The browser's older project doesn't replace anything by itself.
        #expect(previews.previews(of: ids, in: fixture.project)[other] === first[other])
        previews.projectChanged(fixture.project)
        #expect(previews.previews(of: ids, in: fixture.project)[other] === first[other])
        await settle()
        let second = previews.previews(of: ids, in: fixture.project)
        #expect(second[other] !== first[other])
        #expect(second[fixture.timelineID] === first[fixture.timelineID])
        #expect(second[inner] === first[inner])

        // A run of edits inside Inner builds Inner, and Main which draws
        // it, once each.
        let before = previews.revision
        fixture.setTransform([(.opacity, [40])], ofClip: clip.clipID, in: inner)
        previews.projectChanged(fixture.project)
        fixture.setTransform([(.opacity, [30])], ofClip: clip.clipID, in: inner)
        previews.projectChanged(fixture.project)
        await settle()
        #expect(previews.revision == before + 2)
        let third = previews.previews(of: ids, in: fixture.project)
        #expect(third[fixture.timelineID] !== second[fixture.timelineID])
        #expect(third[inner] !== second[inner])
        #expect(third[inner]?.key == TimelinePreview.key(of: inner, in: fixture.project))

        // An edit undone before it settles builds nothing; renaming changes
        // nothing drawn.
        let undone = fixture.project
        fixture.setTransform([(.opacity, [20])], ofClip: clip.clipID, in: inner)
        previews.projectChanged(fixture.project)
        fixture.project = undone
        fixture.project.renameTimeline(inner, to: "Renamed")
        previews.projectChanged(fixture.project)
        await settle()
        #expect(previews.revision == before + 2)
        #expect(previews.previews(of: ids, in: fixture.project)[inner] === third[inner])
    }

    /// The editor's previews, for nested clips, are asked for one at a
    /// time: asking for one keeps the others, and an edit inside one builds
    /// only that one again.
    @Test func nestedClipPreviewsAreMadeOneAtATime() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let size = fixture.project.timelines[0].frameSize
        let inner = fixture.project.addTimeline(name: "Inner", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let other = fixture.project.addTimeline(name: "Other", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let clip = try await fixture.addClip(luma: 60, to: inner)
        _ = try await fixture.addClip(luma: 60, to: other)

        let nested = NestedTimelinePreviews(settleDelay: .milliseconds(40))
        // Nothing to build from before the editor hands it a project.
        #expect(nested.preview(of: inner) == nil)
        nested.projectChanged(fixture.project)
        let first = try #require(nested.preview(of: inner))
        let second = try #require(nested.preview(of: other))
        #expect(nested.preview(of: inner) === first)
        #expect(nested.preview(of: UUID()) == nil)

        fixture.setTransform([(.opacity, [50])], ofClip: clip.clipID, in: inner)
        nested.projectChanged(fixture.project)
        await nested.settle()
        #expect(nested.preview(of: inner) !== first)
        #expect(nested.preview(of: other) === second)
    }

    @Test func framesComeFromTheTimeline() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "two.mov")
        try await writeMovie(to: url, segments: [(luma: 40, frames: 24), (luma: 220, frames: 24)])
        let media = MediaClip(
            name: "two", kind: .video, url: url, duration: CMTime(value: 48, timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        _ = fixture.project.importClip(media, intoTimeline: fixture.timelineID)
        let preview = TimelinePreview(timelineID: fixture.timelineID, project: fixture.project)

        func luma(at seconds: Double) async throws -> Double {
            let image = try #require(await preview.image(at: CMTime(seconds: seconds, preferredTimescale: 600), height: 36))
            let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            return Double(color.brightnessComponent) * 255
        }
        let dark = try await luma(at: 0.5)
        let bright = try await luma(at: 1.5)
        #expect(bright > dark + 100)
        #expect(preview.cachedImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), height: 36) != nil)
    }

    @Test func aTimelineIsSkimmedFromItsPreview() throws {
        var project = EditingProject.empty
        _ = project.importClip(
            MediaClip(name: "Clip", kind: .video, url: nil, duration: CMTime(value: 5, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "Stub"),
            intoTimeline: project.rootTimelineID
        )
        let timeline = try #require(project.timeline(id: project.rootTimelineID))
        let preview = TimelinePreview(timelineID: timeline.id, project: project)
        let target = BrowserSkim.Target(
            item: TimelineStripID(timelineID: timeline.id),
            source: .timeline(preview, name: timeline.name, frameRate: timeline.frameRate),
            start: .zero, duration: timeline.duration
        )
        #expect(BrowserSkim.canSkim(target))
        #expect(target.clip == nil && target.hasPictures && target.name == "Main" && target.frameRate == 24)

        let skim = BrowserSkim()
        defer { skim.end() }
        skim.skim(target, at: 9, audible: false)
        #expect(skim.target == target)
        #expect(skim.seconds == 5)
        #expect(skim.sourceTime == CMTime(value: 5, timescale: 1))
        skim.end()
        #expect(skim.target == nil)

        let empty = BrowserSkim.Target(
            item: "empty", source: .timeline(preview, name: "Empty", frameRate: 24), start: .zero, duration: .zero
        )
        #expect(!BrowserSkim.canSkim(empty))
    }
}
