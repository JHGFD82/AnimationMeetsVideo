import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// What a layer header's menu offers (docs/bar-colors.md, "Layers"): its
/// Color menu marks Default, one swatch or nothing, and Clear Layer is
/// held back with no clips or one open in the Motion Designer.
@MainActor
@Suite struct LayerHeaderMenuTests {
    private func clip(_ color: BarColor?) -> TimelineClip {
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 1, timescale: 1))
        clip.color = color
        return clip
    }

    private func header(_ clips: [TimelineClip], locked: Bool = false) -> LayerHeaderRow {
        LayerHeaderRow(
            number: 1, layer: TimelineLayer(customName: nil, kind: .video, clips: clips), displayName: "Video 1",
            height: 40, canMoveUp: false, canMoveDown: false,
            isExpanded: nil, onToggleExpanded: {},
            isAudioExpanded: nil, onToggleAudio: {}, onDetachAudio: {},
            isChannelsExpanded: nil, onToggleChannels: {},
            onRename: { _ in }, onMove: { _ in },
            onDragChanged: { _ in }, onDragEnded: { _ in }, onDragCancelled: {},
            isSelected: false, onSelect: {}, onDelete: {},
            hasLockedClip: locked
        )
    }

    @Test func theColorMenuMarksDefaultOneSwatchOrNothing() {
        let red = BarColor(0xDF6862), teal = BarColor(0x05A7A7)
        let plain = header([clip(nil), clip(nil)]).clipsColor
        #expect(plain.color == nil && !plain.isMixed)
        let shared = header([clip(red), clip(red)]).clipsColor
        #expect(shared.color == red && !shared.isMixed)
        #expect(header([clip(red), clip(teal)]).clipsColor.isMixed)
        #expect(header([clip(red), clip(nil)]).clipsColor.isMixed)
    }

    @Test func clearLayerNeedsClipsNoneOfThemLocked() {
        #expect(header([clip(nil)]).canClear)
        #expect(!header([]).canClear)
        #expect(!header([clip(nil)], locked: true).canClear)
    }
}
