import Testing
@testable import AnimationMeetsVideo

@Suite struct IdentifiedLookupTests {
    private struct Item: Identifiable, Equatable {
        var id: Int
        var name: String
    }

    private let items = [Item(id: 7, name: "a"), Item(id: 3, name: "b"), Item(id: 7, name: "c")]

    @Test func findsTheFirstElementWithTheID() {
        #expect(items.firstIndex(id: 7) == 0)
        #expect(items.firstIndex(id: 3) == 1)
        #expect(items.first(id: 7)?.name == "a")
    }

    @Test func anIDNoElementHasFindsNothing() {
        #expect(items.firstIndex(id: 4) == nil)
        #expect(items.first(id: 4) == nil)
    }

    @Test func anInsertOutsideTheArrayGoesAtTheNearerEnd() {
        var list = [1, 2, 3]
        list.insert(0, clampedAt: -5)
        list.insert(4, clampedAt: 99)
        list.insert(9, clampedAt: 2)
        #expect(list == [0, 1, 9, 2, 3, 4])
    }
}
