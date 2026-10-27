import AppKit
import CoreMedia
import Foundation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

@Suite struct ClipsTabInteractionTests {
    private typealias F = ClipsTabFixtures

    private let video = ClipsTabFixtures.clip("Video", seconds: 20, frameRate: 24)
    private let song = ClipsTabFixtures.clip("Song", .audio, seconds: 30, frameRate: 0)

    /// The video as two scenes, 0–10 s and 10–20 s, then the song.
    private var snapshot: ClipsTabModel.Snapshot {
        F.snapshot([video, song], found: [video.id: F.coverage(cuts: [0, 10], end: 20)])
    }

    private func entry(_ index: Int) -> BrowserEntry { snapshot.entries[index] }

    // MARK: - Keys

    @Test func returnWithNothingPickedIsLeftAlone() {
        var interaction = ClipsTabInteraction()
        let outcome = interaction.handleKey(.return, modifiers: [], snapshot: snapshot, skim: .none)
        #expect(outcome == .unhandled)
    }

    @Test func returnAddsWhatIsPicked() {
        var interaction = ClipsTabInteraction()
        interaction.picked.click(.asset(song.id))
        let outcome = interaction.handleKey(.return, modifiers: [], snapshot: snapshot, skim: .none)
        #expect(outcome == .handled([.addToTimeline([entry(2).piece()])]))
    }

    @Test func deleteWithOptionIsLeftAloneButCommandDeleteRemoves() {
        var interaction = ClipsTabInteraction()
        interaction.picked.click(.asset(song.id))
        let withOption = interaction.handleKey(.delete, modifiers: .option, snapshot: snapshot, skim: .none)
        #expect(withOption == .unhandled)
        let withCommand = interaction.handleKey(.delete, modifiers: .command, snapshot: snapshot, skim: .none)
        #expect(withCommand == .handled([.removeSelection]))
        let forward = interaction.handleKey(.deleteForward, modifiers: [], snapshot: snapshot, skim: .none)
        #expect(forward == .handled([.removeSelection]))
    }

    @Test func optionLeftOnAClipNotSkimmedStartsAtItsRangeThenSteps() {
        var interaction = ClipsTabInteraction()
        let scene = entry(1)
        interaction.picked.setRange(of: scene.id, from: 2, to: 4, duration: scene.seconds)
        let outcome = interaction.handleKey(.leftArrow, modifiers: .option, snapshot: snapshot, skim: .none)
        #expect(outcome == .handled([.skim(scene, at: 2), .step(frames: -1)]))
    }

    @Test func optionShiftRightOnAClipSkimmedStepsTenFrames() {
        var interaction = ClipsTabInteraction()
        let scene = entry(0)
        interaction.picked.click(scene.id)
        let skim = ClipsTabInteraction.Skim(item: scene.id, seconds: 3, isActive: true)
        let outcome = interaction.handleKey(.rightArrow, modifiers: [.option, .shift], snapshot: snapshot, skim: skim)
        #expect(outcome == .handled([.step(frames: 10)]))
        let withoutOption = interaction.handleKey(.rightArrow, modifiers: [], snapshot: snapshot, skim: skim)
        #expect(withoutOption == .unhandled)
    }

    @Test func iSetsTheRangeStartWhereSkimmedButNotWithShift() {
        var interaction = ClipsTabInteraction()
        let scene = entry(1)
        let skim = ClipsTabInteraction.Skim(item: scene.id, seconds: 4, isActive: true)
        let withShift = interaction.handleKey("i", modifiers: .shift, snapshot: snapshot, skim: skim)
        #expect(withShift == .unhandled)
        #expect(interaction.picked.range == nil)
        let plain = interaction.handleKey("i", modifiers: [], snapshot: snapshot, skim: skim)
        #expect(plain == .handled([]))
        #expect(interaction.picked.range == .init(item: scene.id, start: 4, end: 10))
        #expect(interaction.cursor == scene.id)
        let unskimmed = interaction.handleKey("o", modifiers: [], snapshot: snapshot, skim: .none)
        #expect(unskimmed == .unhandled)
    }

    @Test func iWithCapsLockOnStillSetsTheRangeStart() {
        var interaction = ClipsTabInteraction()
        let scene = entry(1)
        let skim = ClipsTabInteraction.Skim(item: scene.id, seconds: 4, isActive: true)
        let outcome = interaction.handleKey("i", modifiers: .capsLock, snapshot: snapshot, skim: skim)
        #expect(outcome == .handled([]))
    }

    @Test func escapeStopsSkimmingOnlyWhileSkimming() {
        var interaction = ClipsTabInteraction()
        let idle = interaction.handleKey(.escape, modifiers: [], snapshot: snapshot, skim: .none)
        #expect(idle == .unhandled)
        let skim = ClipsTabInteraction.Skim(item: nil, seconds: 0, isActive: true)
        let skimming = interaction.handleKey(.escape, modifiers: [], snapshot: snapshot, skim: skim)
        #expect(skimming == .handled([.endSkim]))
    }

    @Test func downMovesTheSelectionAndStopsSkimming() {
        var interaction = ClipsTabInteraction()
        interaction.click(entry(0).id, flags: [], order: snapshot.order)
        let down = interaction.handleKey(.downArrow, modifiers: [], snapshot: snapshot, skim: .none)
        #expect(down == .handled([.endSkim]))
        #expect(interaction.cursor == entry(1).id)
        #expect(interaction.picked.items == [entry(1).id])
        let shiftDown = interaction.handleKey(.downArrow, modifiers: .shift, snapshot: snapshot, skim: .none)
        #expect(shiftDown == .handled([.endSkim]))
        #expect(interaction.picked.items == [entry(1).id, entry(2).id])
    }

    // MARK: - Presses

    private var layout: FilmstripLayout {
        FilmstripLayout(duration: 10, interval: .oneSecond, cellSize: CGSize(width: 20, height: 20), width: 400)
    }

    @Test func aPressOffTheSelectionTracksARangeAndAShortOnePicksTheClip() {
        var interaction = ClipsTabInteraction()
        let scene = entry(0)
        let tracks = interaction.pressBegan(entry: scene, layout: layout, point: CGPoint(x: 40, y: 5), flags: [])
        #expect(tracks)
        #expect(interaction.rangeDrag == .init(item: scene.id, anchor: 2))
        let effect = interaction.pressed(.track(CGPoint(x: 100, y: 5)), entry: scene, layout: layout, order: snapshot.order, skimming: true)
        #expect(effect == .skim(scene, at: 5))
        #expect(interaction.picked.range == .init(item: scene.id, start: 2, end: 5))
        _ = interaction.pressed(.track(CGPoint(x: 40.2, y: 5)), entry: scene, layout: layout, order: snapshot.order, skimming: true)
        _ = interaction.pressed(.endTrack(CGPoint(x: 40.2, y: 5)), entry: scene, layout: layout, order: snapshot.order, skimming: true)
        #expect(interaction.rangeDrag == nil)
        #expect(interaction.picked.range == nil)
        #expect(interaction.picked.items == [scene.id])
    }

    @Test func aPressOnTheSelectionDragsAndWithCommandNeverTracks() {
        var interaction = ClipsTabInteraction()
        let scene = entry(0)
        interaction.picked.click(scene.id)
        let onSelection = interaction.pressBegan(entry: scene, layout: layout, point: CGPoint(x: 40, y: 5), flags: [])
        #expect(!onSelection)
        let withOption = interaction.pressBegan(entry: scene, layout: layout, point: CGPoint(x: 40, y: 5), flags: .option)
        #expect(withOption)
        let withCommand = interaction.pressBegan(entry: entry(1), layout: layout, point: CGPoint(x: 40, y: 5), flags: .command)
        #expect(!withCommand)
    }

    @Test func aClickShowsTheFrameOnlyWithoutSkimming() {
        var interaction = ClipsTabInteraction()
        let scene = entry(0)
        let click = FilmstripPress.click(CGPoint(x: 60, y: 5), [])
        let skimming = interaction.pressed(click, entry: scene, layout: layout, order: snapshot.order, skimming: true)
        #expect(skimming == ClipsTabInteraction.PressEffect.none)
        let notSkimming = interaction.pressed(click, entry: scene, layout: layout, order: snapshot.order, skimming: false)
        #expect(notSkimming == .skim(scene, at: 3))
        #expect(interaction.cursor == scene.id)
    }

    // MARK: - Dragging

    @Test func aCommandDragOfAClipNotSelectedPicksItAloneAndCarriesIt() {
        var interaction = ClipsTabInteraction()
        interaction.picked.click(entry(0).id)
        interaction.pickForDrag(entry: entry(2), layout: layout, at: CGPoint(x: 10, y: 5))
        #expect(interaction.picked.items == [entry(2).id])
        #expect(interaction.draggedPieces(entry: entry(2), layout: layout, at: CGPoint(x: 10, y: 5), snapshot: snapshot) == [entry(2).piece()])
    }

    @Test func aDragFromInsideARangeCarriesTheRange() {
        var interaction = ClipsTabInteraction()
        let scene = entry(1)
        interaction.picked.setRange(of: scene.id, from: 2, to: 6, duration: scene.seconds)
        interaction.pickForDrag(entry: scene, layout: layout, at: CGPoint(x: 60, y: 5))
        #expect(interaction.picked.range != nil)
        #expect(interaction.draggedPieces(entry: scene, layout: layout, at: CGPoint(x: 60, y: 5), snapshot: snapshot) == [scene.piece(from: 2, to: 6)])
    }

    // MARK: - Show in Clips Browser

    @Test func footageAcrossScenesPicksFromTheFirstToTheLast() {
        var interaction = ClipsTabInteraction()
        let piece = MediaPiece(assetID: video.id, start: F.s(4), end: F.s(14))
        let revealed = interaction.revealSelection(for: piece, snapshot: snapshot)
        #expect(revealed == entry(0).id)
        #expect(interaction.picked.items == [entry(0).id, entry(1).id])
        #expect(interaction.picked.range == nil)
        #expect(interaction.cursor == entry(0).id)
    }

    @Test func footageWithinHalfAFrameOfASceneIsTheWholeScene() {
        var interaction = ClipsTabInteraction()
        let piece = MediaPiece(assetID: video.id, start: F.s(10.01), end: F.s(19.99))
        let revealed = interaction.revealSelection(for: piece, snapshot: snapshot)
        #expect(revealed == entry(1).id)
        #expect(interaction.picked.items == [entry(1).id])
        #expect(interaction.picked.range == nil)
    }

    @Test func partOfASceneIsARangeOfIt() throws {
        var interaction = ClipsTabInteraction()
        let piece = MediaPiece(assetID: video.id, start: F.s(12), end: F.s(15))
        let revealed = interaction.revealSelection(for: piece, snapshot: snapshot)
        #expect(revealed == entry(1).id)
        let range = try #require(interaction.picked.range)
        #expect(range.item == entry(1).id)
        #expect(abs(range.start - 2) < 1e-9)
        #expect(abs(range.end - 5) < 1e-9)
    }

    @Test func soundWithinHalfAFrameAtThirtyFramesIsTheWholeClip() {
        var interaction = ClipsTabInteraction()
        let piece = MediaPiece(assetID: song.id, start: F.s(0.01), end: F.s(29.99))
        let revealed = interaction.revealSelection(for: piece, snapshot: snapshot)
        #expect(revealed == entry(2).id)
        #expect(interaction.picked.range == nil)
    }

    @Test func anAssetNotListedPicksNothing() {
        var interaction = ClipsTabInteraction()
        let revealed = interaction.revealSelection(for: MediaPiece(assetID: UUID(), start: .zero, end: F.s(1)), snapshot: snapshot)
        #expect(revealed == nil)
        #expect(interaction.picked.items.isEmpty)
    }
}
