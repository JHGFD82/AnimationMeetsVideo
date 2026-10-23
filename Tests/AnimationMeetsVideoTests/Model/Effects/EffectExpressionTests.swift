import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct EffectExpressionTests {
    private struct Values: EffectExpression.Values {
        var numbers: [String: [Double]] = [:]
        var centers: [String: [Double]] = [:]
        var indices: [String: Double] = [:]

        func value(_ name: String) -> [Double] { numbers[name] ?? [0] }
        func center(_ name: String) -> [Double] { centers[name] ?? [0, 0] }
        func index(_ name: String) -> Double { indices[name] ?? 0 }
    }

    private let names: [String: EffectExpression.ValueType] = [
        "angle": .number, "spinSpeed": .number, "glow": .number, "tint": .vector(3), "middle": .point, "shape": .choice,
    ]

    private func value(_ text: String, _ values: Values = Values()) throws -> [Double] {
        try EffectExpression(text, names: names).evaluate(values)
    }

    private func problem(_ text: String) -> String? {
        do {
            _ = try EffectExpression(text, names: names)
            return nil
        } catch {
            return error.message
        }
    }

    @Test func arithmeticHasTheUsualPrecedence() throws {
        #expect(try value("1 + 2 * 3") == [7])
        #expect(try value("(1 + 2) * 3") == [9])
        #expect(try value("10 - 4 - 3") == [3])
        #expect(try value("-2 * -3") == [6])
        #expect(try value("7 / 2") == [3.5])
        // Dividing by zero gives 0 rather than infinity, which a kernel
        // can't use.
        #expect(try value("1 / 0") == [0])
    }

    @Test func namesAndFunctionsReadTheirValues() throws {
        var values = Values()
        values.numbers = ["angle": [90], "spinSpeed": [0.5], "seconds": [2], "pi": [.pi]]
        let kaleidoscope = try value("-(rad(angle) + spinSpeed * seconds * 2 * pi)", values)
        #expect(abs(kaleidoscope[0] - -(Double.pi / 2 + 2 * .pi)) < 1e-12)
        #expect(try value("fract(2.75)") == [0.75])
        #expect(try value("floor(-1.5)") == [-2])
        #expect(try value("min(3, max(1, 2))") == [2])
        #expect(try value("abs(-4)") == [4])
    }

    @Test func comparisonsGiveOneOrZero() throws {
        var values = Values()
        values.numbers = ["glow": [50]]
        #expect(try value("glow > 0", values) == [1])
        #expect(try value("glow / 100 >= 1", values) == [0])
        #expect(try value("glow != 50", values) == [0])
    }

    @Test func vectorsArePassedWhole() throws {
        var values = Values()
        values.numbers = ["tint": [0.1, 0.2, 0.3]]
        values.centers = ["middle": [960, 540]]
        values.indices = ["shape": 2]
        #expect(try EffectExpression("tint", names: names).type == .vector(3))
        #expect(try value("tint", values) == [0.1, 0.2, 0.3])
        #expect(try EffectExpression("center(middle)", names: names).type == .vector(2))
        #expect(try value("center(middle)", values) == [960, 540])
        #expect(try value("index(shape) + 1", values) == [3])
    }

    @Test func mistakesAreFoundWhenTheExpressionIsRead() {
        #expect(problem("spped * 2") == "Unknown name \"spped\"")
        #expect(problem("sin(angle)") == "Unknown function \"sin\"")
        #expect(problem("min(angle)") == "min takes 2 numbers, not 1")
        #expect(problem("tint * 2") == "Only numbers can be multiplied, not 3 numbers")
        #expect(problem("shape") == "\"shape\" is a choice; read it as index(shape)")
        #expect(problem("center(angle)") == "center takes a point control, and \"angle\" isn't one")
        #expect(problem("(angle + 1") == "Missing \")\"")
        #expect(problem("angle angle") == "Unexpected \"a\"")
        #expect(problem("") == "The expression is empty")
        #expect(problem("angle =< 1") == "Unknown comparison \"=\"")
    }
}
