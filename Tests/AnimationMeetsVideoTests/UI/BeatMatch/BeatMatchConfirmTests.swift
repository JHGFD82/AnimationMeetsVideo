import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Confirming the beat match panel (`BeatMatchController.confirm`).
@MainActor
@Suite(.serialized) struct BeatMatchConfirmTests {
    /// The draft is made from the map the panel opened on: written over a
    /// map changed meanwhile (a script, another window, the file), it
    /// lost that change (code-review-notes.md, F25). It is written only
    /// over the map it was made from.
    @Test func theDraftIsWrittenOnlyOverTheMapItWasMadeFrom() throws {
        let song = try SnapshotSupport.clickSong(named: "beat-match-confirm")
        let session = BeatMatchSession(asset: song, url: try #require(song.url))
        defer { session.end() }
        session.chooseOneTempo()
        session.addBeat(at: 8, position: 1)
        let elsewhere = session.map
        session.addBeat(at: 16, position: 1)
        let draft = session.map
        #expect(draft != elsewhere && draft != session.original)

        var project = EditingProject.empty
        project.clips.append(song)
        // Unchanged since the panel opened: written.
        #expect(BeatMatchController.write(draft, over: session.original, assetID: song.id, in: &project))
        #expect(project.mediaClip(id: song.id)?.beatMap == draft)
        // Changed elsewhere meanwhile: left as it is, for the person to choose.
        let index = try #require(project.clips.firstIndex(id: song.id))
        project.clips[index].beatMap = elsewhere
        #expect(!BeatMatchController.write(draft, over: session.original, assetID: song.id, in: &project))
        #expect(project.mediaClip(id: song.id)?.beatMap == elsewhere)
    }
}
