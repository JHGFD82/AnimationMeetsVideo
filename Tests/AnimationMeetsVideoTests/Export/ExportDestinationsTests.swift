import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ExportDestinationsTests {
    private let folder = URL(filePath: "/Volumes/Work/Exports", directoryHint: .isDirectory)

    @Test func theSamePlaceConflictsWhateverItsCaseOrSpelling() {
        let taken = folder.appending(path: "Trailer Main.mov")
        #expect(ExportDestinations.conflict(for: folder.appending(path: "trailer main.mov"), among: [taken]) == taken)
        #expect(ExportDestinations.conflict(for: folder.appending(path: "./Trailer Main.mov"), among: [taken]) == taken)
    }

    @Test func anotherExtensionOrFolderDoesNotConflict() {
        let taken = folder.appending(path: "Trailer Main.mov")
        #expect(ExportDestinations.conflict(for: folder.appending(path: "Trailer Main.wav"), among: [taken]) == nil)
        let elsewhere = URL(filePath: "/Volumes/Work/Other/Trailer Main.mov")
        #expect(ExportDestinations.conflict(for: elsewhere, among: [taken]) == nil)
    }

    @Test func aStemsFolderConflictsWithItself() {
        let stems = folder.appending(path: "Trailer Main Stems", directoryHint: .isDirectory)
        #expect(ExportDestinations.conflict(for: stems, among: [stems]) == stems)
    }

    @Test func aFreeNameSkipsNamesTakenWithTheSameExtension() {
        let taken = [folder.appending(path: "Trailer Main.mov"), folder.appending(path: "Trailer Main 2.mov")]
        #expect(ExportDestinations.freeName("Trailer Main", fileExtension: "mov", avoiding: taken) == "Trailer Main 3")
        #expect(ExportDestinations.freeName("Trailer Main", fileExtension: "wav", avoiding: taken) == "Trailer Main")
    }

    @Test func aFreeFolderNameSkipsATakenFolder() {
        let taken = [folder.appending(path: "Trailer Main Stems", directoryHint: .isDirectory)]
        #expect(ExportDestinations.freeName("Trailer Main Stems", fileExtension: nil, avoiding: taken) == "Trailer Main Stems 2")
    }

    @Test func withNothingTakenTheNameIsKept() {
        #expect(ExportDestinations.freeName("Trailer", fileExtension: "mov", avoiding: []) == "Trailer")
    }
}
