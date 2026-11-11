import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct StrictJSONTests {
    private func passes(_ json: String, _ shape: JSONShape) -> Bool {
        (try? StrictJSON.validate(Data(json.utf8), against: shape)) != nil
    }

    /// A whole number must also fit an Int, which is what is read from it,
    /// in effect.json and project.json alike.
    @Test func anIntegerIsWholeAndFitsAnInt() {
        #expect(passes("5", .integer))
        #expect(passes("5.0", .integer))
        #expect(passes("-3", .integer))
        #expect(passes("9223372036854775807", .integer))
        #expect(!passes("5.5", .integer))
        #expect(!passes("1e30", .integer))
        #expect(!passes("18446744073709551615", .integer))
        #expect(!passes("true", .integer))
        #expect(!passes("\"5\"", .integer))
    }

    @Test func numbersAreReadWhateverTheirSize() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data("[9007199254740993, 1e30, 0.5]".utf8)) as? [Any]
        #expect(StrictJSON.numbers(parsed) == [9_007_199_254_740_992, 1e30, 0.5])
        #expect(StrictJSON.number(true as NSNumber) == nil)
        #expect(StrictJSON.numbers([1, "2"] as [Any]) == nil)
        #expect(StrictJSON.integer(1e30 as NSNumber) == nil)
        #expect(StrictJSON.integer(7.0 as NSNumber) == 7)
    }
}
