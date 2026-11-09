import CoreMedia
import Foundation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

@MainActor
struct MediaReplacementBatchTests {
    /// A project of `count` videos, and requests to replace each with a
    /// file that isn't there.
    private func batch(of count: Int) -> (project: Binding<EditingProject>, requests: [MediaReplacementController.Request]) {
        var project = EditingProject.empty
        var requests: [MediaReplacementController.Request] = []
        for index in 0..<count {
            let media = MediaClip(
                name: "clip \(index)", kind: .video, url: URL(fileURLWithPath: "/missing/clip-\(index).mov"),
                duration: CMTime(seconds: 10, preferredTimescale: 600),
                frameRate: 24, colorSpace: .rec709, codecName: "ProRes 422"
            )
            _ = project.importClip(media, intoTimeline: project.rootTimelineID)
            requests.append(.init(assetID: media.id, url: URL(fileURLWithPath: "/missing/new-\(index).mov")))
        }
        var stored = project
        return (Binding(get: { stored }, set: { stored = $0 }), requests)
    }

    @Test func skippingOneFileGoesOnToTheNext() throws {
        let (project, requests) = batch(of: 3)
        let controller = MediaReplacementController()
        controller.start(requests, context: .init(project: project, analysis: AssetAnalysis(), packageURL: nil))

        let first = try #require(controller.session)
        #expect(first.assetName == "clip 0")
        #expect(first.filesAfter == 2)

        controller.skip(first)
        let second = try #require(controller.session)
        #expect(second.assetName == "clip 1")
        #expect(second.filesAfter == 1)

        // A late skip of the one before does nothing.
        controller.skip(first)
        #expect(controller.session?.id == second.id)

        controller.skip(second)
        let third = try #require(controller.session)
        #expect(third.filesAfter == 0)
        controller.skip(third)

        #expect(controller.session == nil)
        let notice = try #require(controller.notice)
        #expect(notice.message.contains("Replaced 0 of 3"))
        for name in ["clip 0", "clip 1", "clip 2"] { #expect(notice.message.contains(name)) }
    }

    @Test func cancellingAllLeavesTheRest() throws {
        let (project, requests) = batch(of: 3)
        let controller = MediaReplacementController()
        controller.start(requests, context: .init(project: project, analysis: AssetAnalysis(), packageURL: nil))
        controller.skip(try #require(controller.session))
        controller.cancel(try #require(controller.session))

        #expect(controller.session == nil)
        let notice = try #require(controller.notice)
        for name in ["clip 0", "clip 1", "clip 2"] { #expect(notice.message.contains(name)) }
    }
}
