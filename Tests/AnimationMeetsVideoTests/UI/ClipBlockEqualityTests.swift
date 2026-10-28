import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// When a row's `.equatable()` lets a clip block skip a redraw, and how a
/// block that skipped one still acts with the row's newest handlers.
@MainActor
struct ClipBlockEqualityTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    private func model(selected: Bool = false) -> ClipBlockModel {
        ClipBlockModel(
            clip: TimelineClip(source: .media(UUID()), startOffset: seconds(1), trimStart: .zero, trimEnd: seconds(3)),
            frameRate: 24, info: nil, typeColor: .blue, hasLinkedAudio: false, showsWaveform: false,
            splitsChannels: false, transitionsTaken: .none, joinedLead: nil, isSelected: selected,
            selectedTransition: nil, pixelsPerSecond: 50, height: 40, visibleX: 0...800, tool: .arrow,
            acceptsEffects: true, effectCount: 0, showsVolumeLine: false, passesThrough: false,
            hasPasteChanges: false, playsSound: false
        )
    }

    @Test func sameModelIsEqualWhateverTheHandlers() {
        let store = LiveClipHandlerStore()
        let model = model()
        let first = ClipBlockView(model: model, handlers: store.box(for: model.clip.id, holding: ClipBlockHandlers.inert()))
        let second = ClipBlockView(model: model, handlers: store.box(for: model.clip.id, holding: ClipBlockHandlers.inert()))
        #expect(first == second)
    }

    @Test func aChangedModelIsDrawnAgain() {
        let store = LiveClipHandlerStore()
        var selected = model(selected: false)
        let first = ClipBlockView(model: selected, handlers: store.box(for: selected.clip.id, holding: ClipBlockHandlers.inert()))
        selected.isSelected = true
        let second = ClipBlockView(model: selected, handlers: store.box(for: selected.clip.id, holding: ClipBlockHandlers.inert()))
        #expect(first != second)
    }

    /// Beat Match appearing changes the menu, so it is drawn again.
    @Test func anOptionalActionComingOrGoingIsDrawnAgain() {
        let store = LiveClipHandlerStore()
        let model = model()
        let without = ClipBlockView(model: model, handlers: store.box(for: model.clip.id, holding: ClipBlockHandlers.inert()))
        let with = ClipBlockView(model: model, handlers: store.box(for: model.clip.id, holding: ClipBlockHandlers.inert(onBeatMatch: {})))
        #expect(without != with)
    }

    /// A block that kept its first value (its redraw was skipped) still
    /// calls the handlers the row made last.
    @Test func aSkippedBlockActsWithTheNewestHandlers() {
        let store = LiveClipHandlerStore()
        let model = model()
        var called: [String] = []
        let kept = ClipBlockView(model: model, handlers: store.box(for: model.clip.id, holding: ClipBlockHandlers.inert(onSelect: { called.append("old") })))
        _ = store.box(for: model.clip.id, holding: ClipBlockHandlers.inert(onSelect: { called.append("new") }))
        kept.handlers.onSelect()
        #expect(called == ["new"])
    }

    @Test func boxesOfClipsGoneFromTheRowAreLetGo() {
        let store = LiveClipHandlerStore()
        let gone = UUID(), kept = UUID()
        let goneBox = store.box(for: gone, holding: ClipBlockHandlers.inert())
        let keptBox = store.box(for: kept, holding: ClipBlockHandlers.inert())
        store.keep(only: [kept])
        #expect(store.box(for: kept, holding: ClipBlockHandlers.inert()) === keptBox)
        #expect(store.box(for: gone, holding: ClipBlockHandlers.inert()) !== goneBox)
    }
}
