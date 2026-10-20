import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct LassoTests {
    @Test func aLassoIsTheRectangleBetweenWhereItBeganAndWhereItIs() {
        let drag = LassoDrag(start: CGPoint(x: 100, y: 50), current: CGPoint(x: 40, y: 80), kept: [])
        #expect(drag.rect == CGRect(x: 40, y: 50, width: 60, height: 30))
        #expect(!drag.isClick)
    }

    @Test func aPressThatBarelyMovesIsAClick() {
        #expect(LassoDrag(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 12, y: 11), kept: []).isClick)
    }

    @Test func aNestedTimelineIsNamedAfterTheOnesInUse() {
        var project = EditingProject.empty
        #expect(project.newNestedTimelineName() == "Nested 1")
        project.addTimeline(name: "Nested 1", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        #expect(project.newNestedTimelineName() == "Nested 2")
    }

    @MainActor @Test func aGroupOnTheClipboardIsReplacedByWhatIsCopiedAfterIt() throws {
        let clipboard = EditorClipboard()
        #expect(!clipboard.hasClips)
        let group = ClipGroupBundle(bundles: [], start: .zero, end: .zero)
        clipboard.copy(group: group)
        #expect(clipboard.hasClips)
        #expect(clipboard.group == group)
        clipboard.copy(effects: nil)
        #expect(!clipboard.hasClips)
    }
}
