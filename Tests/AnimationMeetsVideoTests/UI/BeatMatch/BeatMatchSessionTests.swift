import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite(.serialized) struct BeatMatchSessionTests {
    private func session(_ name: String) throws -> BeatMatchSession {
        let song = try SnapshotSupport.clickSong(named: name)
        return BeatMatchSession(asset: song, url: try #require(song.url))
    }

    private func ranges(_ session: BeatMatchSession) -> [[Double]] {
        session.map.sections.map { [$0.start.seconds, $0.end.seconds] }
    }

    @Test func aDrawnSectionIsSelectedAndPickingAKindChangesItOnce() throws {
        let session = try session("beat-match-session-kinds")
        defer { session.end() }
        session.chooseSections()
        session.drawSection(from: 0, to: 10, snap: 0)
        let first = try #require(session.map.sections.first)
        #expect(session.selectedSectionID == first.id)
        // Changes the drawn section, then lets go of it…
        session.chooseKind(.ramp)
        #expect(session.map.sections[0].kind == .ramp)
        #expect(session.selectedSectionID == nil)
        // …so the next pick only sets what is drawn next.
        session.chooseKind(.none)
        #expect(session.map.sections[0].kind == .ramp)
        session.drawSection(from: 10, to: 20, snap: 0)
        #expect(session.map.sections[1].kind == .none)
        #expect(session.selectedSectionID == session.map.sections[1].id)
    }

    @Test func mWhileDrawingMarksUpToThePlayheadAndUndoTakesItBack() throws {
        let session = try session("beat-match-session-mark")
        defer { session.end() }
        // No run loop turns between the steps here to group each one, as
        // each event is in the app.
        session.undoManager.groupsByEvent = false
        func step(_ change: () -> Void) {
            session.undoManager.beginUndoGrouping()
            change()
            session.undoManager.endUndoGrouping()
        }
        step { session.chooseSections() }
        #expect(session.canUndo)
        session.seek(to: 12)
        step { session.drawSectionToPlayhead() }
        // The marked section is selected: picking a kind changes it.
        #expect(session.selectedSectionID == session.map.sections[0].id)
        step { session.chooseKind(.ramp) }
        #expect(session.selectedSectionID == nil)
        session.seek(to: 15)
        step { session.drawSectionToPlayhead() }
        #expect(ranges(session) == [[0, 12], [12, 15]])
        #expect(session.map.sections.map(\.kind) == [.ramp, .ramp])
        #expect(session.selectedSectionID == session.map.sections[1].id)
        // Inside a section there is nothing to mark.
        session.seek(to: 5)
        session.drawSectionToPlayhead()
        #expect(session.message != nil)

        session.undo()
        #expect(ranges(session) == [[0, 12]])
        #expect(session.canRedo)
        session.redo()
        #expect(ranges(session) == [[0, 12], [12, 15]])
    }

    @Test func confirmWaitsForAFilledSectionAndFillingLeavesTheView() async throws {
        let session = try session("beat-match-session-confirm")
        defer { session.end() }
        for _ in 0..<200 where session.audio == nil { try await Task.sleep(for: .milliseconds(50)) }
        session.chooseSections()
        session.drawSection(from: 0, to: 20, snap: 0)
        session.drawSection(from: 20, to: 40, snap: 0)
        session.finishDrawing()
        let sections = session.map.sections.map(\.id)
        #expect(session.selectedSectionID == sections[0])
        #expect(!session.canConfirm)
        // In close on the first section, the second out of view.
        session.secondsPerPoint = 0.01
        session.visibleStart = 4
        session.addBeat(at: 8.25, position: 1)
        session.addBeat(at: 16.25, position: 1)
        #expect(!session.canConfirm)
        session.fillSelected()
        for _ in 0..<100 where session.isFilling { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.canConfirm)
        // The next section to mark is selected, but the view stays put.
        #expect(session.selectedSectionID == sections[1])
        #expect(session.visibleStart == 4)
    }

    @Test func startingOverASongWithBeatsOffersToRemoveThem() throws {
        var song = try SnapshotSupport.clickSong(named: "beat-match-session-remove")
        song.beatMap = .oneTempo(duration: CMTime(seconds: 40, preferredTimescale: 48_000))
        let session = BeatMatchSession(asset: song, url: try #require(song.url))
        defer { session.end() }
        #expect(!session.removesBeats)
        session.startOver()
        #expect(session.removesBeats)
        // Choosing sections afresh still leaves nothing drawn to keep.
        session.chooseSections()
        #expect(session.removesBeats)
        session.drawSection(from: 0, to: 10, snap: 0)
        #expect(!session.removesBeats)
        #expect(!session.canConfirm)

        // A song without beats has nothing to remove.
        let fresh = try self.session("beat-match-session-remove-fresh")
        defer { fresh.end() }
        fresh.chooseSections()
        fresh.startOver()
        #expect(!fresh.removesBeats)
    }
}
