import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The note that says why something wasn't done (`RefusalNotice`), and the
/// words it gives for an effect a clip can't take (`RefusalReason`).
@MainActor
struct RefusalNoticeTests {
    @Test func aNoteShowsUntilDismissed() {
        let notice = RefusalNotice()
        notice.tell("Nothing is selected to copy.")
        #expect(notice.note?.message == "Nothing is selected to copy.")
        notice.dismiss()
        #expect(notice.note == nil)
    }

    @Test func theSameMessageKeepsItsNote() {
        let notice = RefusalNotice()
        notice.tell("Nothing is selected to copy.")
        let first = notice.note
        notice.tell("Nothing is selected to copy.")
        #expect(notice.note == first)
        notice.tell("Nothing is selected to cut.")
        #expect(notice.note?.id != first?.id)
    }

    /// The fallback after an edit already refused for a sharper reason
    /// leaves that reason up.
    @Test func aFallbackLeavesAReasonJustGiven() {
        let notice = RefusalNotice()
        notice.tell(ClipLockRefusal.message)
        notice.tellUnlessJustTold(RefusalReason.paste)
        #expect(notice.note?.message == ClipLockRefusal.message)
    }

    @Test func addingAnEffectWithNoClipAsksForOne() throws {
        let project = EditingProject.empty
        let kind = try #require(EffectKind.all.first { !$0.isAudio && !$0.drawsShape && !$0.isKeyframing })
        let message = RefusalReason.addingEffect(kind, toClip: nil, in: project.rootTimelineID, of: project)
        #expect(message == "Select a clip on the timeline to add \(kind.name) to.")
    }
}
