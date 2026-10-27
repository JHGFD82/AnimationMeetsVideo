import CoreMedia
import SwiftUI
@testable import AnimationMeetsVideo

extension ClipBlockHandlers {
    /// Handlers that do nothing, but for those given.
    static func inert(
        onSelect: @escaping () -> Void = {},
        onMove: @escaping (CMTime, UUID?) -> Void = { _, _ in },
        onBeatMatch: (() -> Void)? = nil
    ) -> ClipBlockHandlers {
        ClipBlockHandlers(
            onToggleInGroup: {}, onOpenNested: nil, resolveMove: { _, _ in nil },
            resolveTrimStart: { _ in nil }, resolveTrimEnd: { _ in nil }, onSelect: onSelect,
            onMove: onMove, onMoveToNewLayer: { _, _ in }, onDragging: { _ in },
            onMovePreview: { _ in }, onTrimStart: { _ in }, onTrimEnd: { _ in }, onTrimPreview: { _, _ in },
            onSetTransition: { _, _ in }, onRemoveTransition: { _ in }, onSelectTransition: { _ in },
            onSetTransitionCurve: { _, _ in }, onDetachAudio: {}, snap: { $0 }, onBlade: { _ in },
            resolveSlip: { _ in nil }, onSlip: { _ in }, onSlipDraft: { _, _ in }, snapTime: { _ in nil },
            snapSpan: { _, _ in nil }, onSnapIndicator: { _ in }, onSetTransitionDuration: { _, _ in },
            onAddEffect: { _ in }, onApplyPreset: { _ in }, onPasteEffects: {}, onClipboard: { _ in },
            onCopy: { _, _, _ in }, onDropFiles: { _, _ in }, onDropGenerator: { _, _ in },
            onSetPassThrough: { _ in }, onEditTime: { _ in }, onEditClip: { _ in },
            onBeatMatch: onBeatMatch
        )
    }
}

extension ClipBlockModel {
    /// A clip block on a 40-point layer at 50 points a second.
    static func sample(
        _ clip: TimelineClip, info: ResolvedClipInfo? = nil, color: Color = Design.ClipTone.video.color,
        selected: Bool = false, height: CGFloat = 40, showsVolumeLine: Bool = false, tool: TimelineTool = .arrow
    ) -> ClipBlockModel {
        ClipBlockModel(
            clip: clip, frameRate: 24, info: info, typeColor: color, hasLinkedAudio: false, showsWaveform: false,
            splitsChannels: false, transitionsTaken: .none, joinedLead: nil, isSelected: selected,
            selectedTransition: nil, pixelsPerSecond: 50, height: height, visibleX: 0...2000, tool: tool,
            acceptsEffects: true, effectCount: 0, showsVolumeLine: showsVolumeLine, passesThrough: false,
            hasPasteChanges: false, playsSound: showsVolumeLine
        )
    }
}
