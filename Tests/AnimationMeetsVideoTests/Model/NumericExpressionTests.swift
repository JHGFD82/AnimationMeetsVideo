import Testing
@testable import AnimationMeetsVideo

@Suite struct NumericExpressionTests {
    @Test func addsWhatIsTyped() {
        #expect(NumericExpression.evaluate("100+25") == 125)
    }

    @Test func followsPrecedenceAndParentheses() {
        #expect(NumericExpression.evaluate("2+3*4") == 14)
        #expect(NumericExpression.evaluate("(2+3)*4") == 20)
        #expect(NumericExpression.evaluate("1920/2 - 40") == 920)
        #expect(NumericExpression.evaluate("10-4-3") == 3)
        #expect(NumericExpression.evaluate("8/4/2") == 1)
    }

    @Test func readsSignsDecimalsAndOtherSymbols() {
        #expect(NumericExpression.evaluate("-12.5") == -12.5)
        #expect(NumericExpression.evaluate("-(3+2)") == -5)
        #expect(NumericExpression.evaluate("3--2") == 5)
        #expect(NumericExpression.evaluate(".5") == 0.5)
        #expect(NumericExpression.evaluate("3 × 4") == 12)
        #expect(NumericExpression.evaluate("3x4") == 12)
        #expect(NumericExpression.evaluate("9÷3") == 3)
        #expect(NumericExpression.evaluate("1,920") == 1920)
    }

    @Test func rejectsWhatIsNotANumber() {
        #expect(NumericExpression.evaluate("") == nil)
        #expect(NumericExpression.evaluate("abc") == nil)
        #expect(NumericExpression.evaluate("5+") == nil)
        #expect(NumericExpression.evaluate("(5") == nil)
        #expect(NumericExpression.evaluate("5)") == nil)
        #expect(NumericExpression.evaluate("1.2.3") == nil)
        #expect(NumericExpression.evaluate("1/0") == nil)
    }

    @Test func formatsResultsPlainly() {
        #expect(NumericExpression.format(125) == "125")
        #expect(NumericExpression.format(23.976) == "23.976")
        #expect(NumericExpression.format(1920.5) == "1920.5")
        #expect(NumericExpression.format(1.23456, maxFractionDigits: 1) == "1.2")
    }
}
