import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct RecentProjectsTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Projects/\(name).amv", isDirectory: true)
    }

    @Test func theNewestComesFirstAndOnlyOnce() {
        var recents = RecentProjects()
        recents.add(url("A"))
        recents.add(url("B"))
        recents.add(url("A"))
        #expect(recents.urls.map(RecentProjects.name(of:)) == ["A", "B"])
    }

    @Test func theOldestFallOffPastTheLimit() {
        var recents = RecentProjects()
        for index in 0..<(RecentProjects.limit + 3) { recents.add(url("P\(index)")) }
        #expect(recents.paths.count == RecentProjects.limit)
        #expect(RecentProjects.name(of: recents.urls[0]) == "P\(RecentProjects.limit + 2)")
    }

    @Test func survivesBeingStoredAndRead() {
        var recents = RecentProjects()
        recents.add(url("A"))
        recents.add(url("B"))
        #expect(RecentProjects(stored: recents.stored) == recents)
        #expect(RecentProjects(stored: "not json").paths.isEmpty)
    }

    @Test func removesAProject() {
        var recents = RecentProjects()
        recents.add(url("A"))
        recents.add(url("B"))
        recents.remove(url("A"))
        #expect(recents.urls.map(RecentProjects.name(of:)) == ["B"])
    }
}
