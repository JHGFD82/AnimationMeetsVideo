import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
struct ProjectDialogsTests {
    @Test func theProjectsOwnWindowShowsDialogsToBeginWith() {
        let session = ProjectSession()
        #expect(session.dialogWindow == nil)
    }

    @Test func aTimelineWindowInFrontShowsThemUntilItCloses() {
        let session = ProjectSession()
        let timelineWindow = UUID()
        session.showDialogs(in: timelineWindow)
        #expect(session.dialogWindow == timelineWindow)
        session.windowClosed(timelineWindow)
        #expect(session.dialogWindow == nil)
    }

    @Test func aDialogUpStaysOnItsWindow() {
        let session = ProjectSession()
        let timelineWindow = UUID()
        session.showDialogs(in: timelineWindow)
        session.showsProjectSettings = true
        session.showDialogs(in: nil)
        #expect(session.dialogWindow == timelineWindow)
        session.showsProjectSettings = false
        session.showDialogs(in: nil)
        #expect(session.dialogWindow == nil)
    }

    @Test func aNoticeUpStaysOnItsWindow() {
        let session = ProjectSession()
        let timelineWindow = UUID()
        session.showDialogs(in: timelineWindow)
        session.replacement.notice = .init(title: "Media Replaced", message: "")
        #expect(session.replacement.isPresenting)
        session.showDialogs(in: nil)
        #expect(session.dialogWindow == timelineWindow)
    }

    @Test func anotherWindowClosingLeavesTheHostAlone() {
        let session = ProjectSession()
        let timelineWindow = UUID()
        session.showDialogs(in: timelineWindow)
        session.windowClosed(UUID())
        #expect(session.dialogWindow == timelineWindow)
    }
}
