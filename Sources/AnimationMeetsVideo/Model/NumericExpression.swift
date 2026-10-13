import Foundation

/// Evaluates the arithmetic typed into a numeric field, so "100+25" enters
/// 125. Supports `+ - * /`, parentheses, unary minus and decimals, with the
/// usual precedence. `x` and `×` multiply, `÷` divides, and spaces and
/// thousands commas are ignored.
enum NumericExpression {
    /// Nil when the text isn't a complete expression or the result isn't a
    /// finite number (for example after dividing by zero).
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(text)
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) {
            characters = text.filter { !$0.isWhitespace && $0 != "," }.map { character in
                switch character {
                case "x", "X", "×": "*"
                case "÷": "/"
                case "−": "-"
                default: character
                }
            }
        }

        var isAtEnd: Bool { index == characters.count }

        private var current: Character? { index < characters.count ? characters[index] : nil }

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = current, op == "+" || op == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*' | '/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = current, op == "*" || op == "/" {
                index += 1
                guard let rhs = parseFactor() else { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        // factor := ('-' | '+') factor | '(' expression ')' | number
        private mutating func parseFactor() -> Double? {
            switch current {
            case "-":
                index += 1
                return parseFactor().map { -$0 }
            case "+":
                index += 1
                return parseFactor()
            case "(":
                index += 1
                guard let value = parseExpression(), current == ")" else { return nil }
                index += 1
                return value
            default:
                return parseNumber()
            }
        }

        private mutating func parseNumber() -> Double? {
            let start = index
            while let character = current, ("0"..."9").contains(character) || character == "." {
                index += 1
            }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }
    }
}
