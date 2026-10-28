import Foundation

/// One of an effect package's arithmetic expressions: a kernel argument, a
/// filter parameter, a reach or a condition (see docs/effect-packages.md,
/// "Arguments"). It is parsed and checked once, when the package loads,
/// against the names it may use, and evaluated each frame.
///
/// `+ - * /` and parentheses work as in a numeric field, with unary minus.
/// Comparisons (`< <= > >= == !=`) bind loosest and give 1 or 0. Only
/// numbers take part in arithmetic; a vector (a point, a color, several
/// numbers) can only be an expression's whole value.
struct EffectExpression: Equatable, Sendable {
    /// What an expression or a name gives.
    enum ValueType: Equatable, Sendable {
        case number
        /// Several numbers, as a `float2`, `float3` or `float4`.
        case vector(Int)
        /// A point control: a vector of 2, or a position through `center`.
        case point
        /// A choice control, read through `index`.
        case choice
        /// A curve control, which only a kernel reads, as a picture.
        case curve

        var noun: String {
            switch self {
            case .number: "a number"
            case .vector(let count): "\(count) numbers"
            case .point: "a point"
            case .choice: "a choice"
            case .curve: "a curve"
            }
        }
    }

    /// What an expression reads when it is evaluated.
    protocol Values {
        /// A name's value: one number, or a vector's components.
        func value(_ name: String) -> [Double]
        /// Point control `name` as a position in output pixels.
        func center(_ name: String) -> [Double]
        /// The position of choice `name`'s option in its list, from 0.
        func index(_ name: String) -> Double
    }

    struct Problem: Error, Equatable {
        var message: String
    }

    /// The names every expression may use besides a package's controls.
    static let builtInNames: [String: ValueType] = [
        "seconds": .number, "frame": .number, "scale": .number,
        "frameWidth": .number, "frameHeight": .number, "frameCenter": .vector(2),
        "canvasWidth": .number, "canvasHeight": .number, "frameDuration": .number, "pi": .number,
    ]

    /// The functions, by how many numbers they take; `center` and `index`
    /// take a control's name instead.
    static let functions: [String: Int] = [
        "rad": 1, "fract": 1, "floor": 1, "round": 1, "abs": 1, "min": 2, "max": 2, "mod": 2, "pow": 2, "log": 1,
    ]

    /// Every name a package's control can't take.
    static var reservedNames: Set<String> {
        Set(builtInNames.keys).union(functions.keys).union(["center", "index", "amount", "hasInput", "hasAgainst", "hasMotion", "pass", "passes"])
    }

    indirect enum Node: Equatable, Sendable {
        case number(Double)
        case name(String)
        case negate(Node)
        case binary(Character, Node, Node)
        case comparison(String, Node, Node)
        case call(String, [Node])
        case center(String)
        case index(String)
    }

    let text: String
    let root: Node
    let type: ValueType

    /// Parses `text` and checks it against `names` (a package's controls)
    /// and `builtInNames`.
    init(_ text: String, names: [String: ValueType]) throws(Problem) {
        var parser = Parser(text: text, names: names.merging(Self.builtInNames) { own, _ in own })
        let (root, type) = try parser.parse()
        self.text = text
        self.root = root
        self.type = type == .point ? .vector(2) : type
    }

    /// Its value: one number, or a vector's components.
    func evaluate(_ values: some Values) -> [Double] {
        Self.evaluate(root, values)
    }

    /// Its value as one number, for an expression of type `.number`.
    func number(_ values: some Values) -> Double {
        evaluate(values).first ?? 0
    }

    /// Whether it reads `name`, a control's or a built-in one.
    func reads(_ name: String) -> Bool {
        func reads(_ node: Node) -> Bool {
            switch node {
            case .number: false
            case .name(let read), .center(let read), .index(let read): read == name
            case .negate(let operand): reads(operand)
            case .binary(_, let lhs, let rhs), .comparison(_, let lhs, let rhs): reads(lhs) || reads(rhs)
            case .call(_, let arguments): arguments.contains(where: reads)
            }
        }
        return reads(root)
    }

    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    private static func evaluate(_ node: Node, _ values: some Values) -> [Double] {
        func scalar(_ node: Node) -> Double { evaluate(node, values).first ?? 0 }
        switch node {
        case .number(let value): return [value]
        case .name(let name): return values.value(name)
        case .negate(let operand): return [-scalar(operand)]
        case .binary(let op, let lhs, let rhs):
            let (a, b) = (scalar(lhs), scalar(rhs))
            switch op {
            case "+": return [a + b]
            case "-": return [a - b]
            case "*": return [a * b]
            default: return [b == 0 ? 0 : a / b]
            }
        case .comparison(let op, let lhs, let rhs):
            let (a, b) = (scalar(lhs), scalar(rhs))
            let holds = switch op {
            case "<": a < b
            case "<=": a <= b
            case ">": a > b
            case ">=": a >= b
            case "==": a == b
            default: a != b
            }
            return [holds ? 1 : 0]
        case .call(let name, let arguments):
            let numbers = arguments.map(scalar)
            switch name {
            case "rad": return [numbers[0] * .pi / 180]
            case "fract": return [numbers[0] - numbers[0].rounded(.down)]
            case "floor": return [numbers[0].rounded(.down)]
            // Halves away from zero, as Swift's `rounded()`.
            case "round": return [numbers[0].rounded()]
            case "mod": return [numbers[1] == 0 ? 0 : numbers[0] - numbers[1] * (numbers[0] / numbers[1]).rounded(.down)]
            case "abs": return [abs(numbers[0])]
            // Only where it is a real number: 0 for a negative base's
            // fraction, as for a logarithm of 0 or less.
            case "pow": return [finite(pow(numbers[0], numbers[1]))]
            case "log": return [numbers[0] > 0 ? log(numbers[0]) : 0]
            case "min": return [min(numbers[0], numbers[1])]
            default: return [max(numbers[0], numbers[1])]
            }
        case .center(let name): return values.center(name)
        case .index(let name): return [values.index(name)]
        }
    }

    // MARK: Parsing

    private struct Parser {
        let characters: [Character]
        let names: [String: ValueType]
        var index = 0

        init(text: String, names: [String: ValueType]) {
            characters = Array(text)
            self.names = names
        }

        private var current: Character? {
            mutating get {
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                return index < characters.count ? characters[index] : nil
            }
        }

        mutating func parse() throws(Problem) -> (Node, ValueType) {
            guard current != nil else { throw Problem(message: "The expression is empty") }
            let result = try comparison()
            if let extra = current { throw Problem(message: "Unexpected \"\(extra)\"") }
            return result
        }

        // comparison := sum (('<' | '<=' | '>' | '>=' | '==' | '!=') sum)?
        private mutating func comparison() throws(Problem) -> (Node, ValueType) {
            let lhs = try sum()
            guard let first = current, "<>=!".contains(first) else { return lhs }
            index += 1
            var op = String(first)
            if index < characters.count, characters[index] == "=" {
                op.append("=")
                index += 1
            }
            guard ["<", "<=", ">", ">=", "==", "!="].contains(op) else { throw Problem(message: "Unknown comparison \"\(op)\"") }
            let rhs = try sum()
            try requireNumber(lhs.1, "compared")
            try requireNumber(rhs.1, "compared")
            return (.comparison(op, lhs.0, rhs.0), .number)
        }

        // sum := product (('+' | '-') product)*
        private mutating func sum() throws(Problem) -> (Node, ValueType) {
            var (node, type) = try product()
            while let op = current, op == "+" || op == "-" {
                index += 1
                let rhs = try product()
                try requireNumber(type, "added")
                try requireNumber(rhs.1, "added")
                (node, type) = (.binary(op, node, rhs.0), .number)
            }
            return (node, type)
        }

        // product := unary (('*' | '/') unary)*
        private mutating func product() throws(Problem) -> (Node, ValueType) {
            var (node, type) = try unary()
            while let op = current, op == "*" || op == "/" {
                index += 1
                let rhs = try unary()
                try requireNumber(type, "multiplied")
                try requireNumber(rhs.1, "multiplied")
                (node, type) = (.binary(op, node, rhs.0), .number)
            }
            return (node, type)
        }

        // unary := '-' unary | '+' unary | primary
        private mutating func unary() throws(Problem) -> (Node, ValueType) {
            switch current {
            case "-":
                index += 1
                let (node, type) = try unary()
                try requireNumber(type, "negated")
                return (.negate(node), .number)
            case "+":
                index += 1
                return try unary()
            default:
                return try primary()
            }
        }

        // primary := number | name | name '(' arguments ')' | '(' comparison ')'
        private mutating func primary() throws(Problem) -> (Node, ValueType) {
            guard let character = current else { throw Problem(message: "The expression ends too soon") }
            if character == "(" {
                index += 1
                let inner = try comparison()
                try expect(")")
                return inner
            }
            if character.isNumber || character == "." { return (.number(try number()), .number) }
            guard character.isLetter else { throw Problem(message: "Unexpected \"\(character)\"") }
            let name = identifier()
            guard current == "(" else {
                guard let type = names[name] else { throw Problem(message: "Unknown name \"\(name)\"") }
                guard type != .choice else { throw Problem(message: "\"\(name)\" is a choice; read it as index(\(name))") }
                guard type != .curve else { throw Problem(message: "\"\(name)\" is a curve; a kernel reads it as a picture from it") }
                return (.name(name), type)
            }
            index += 1
            return try call(name)
        }

        private mutating func call(_ name: String) throws(Problem) -> (Node, ValueType) {
            if name == "center" || name == "index" {
                guard let character = current, character.isLetter else { throw Problem(message: "\(name) takes a control's name") }
                let argument = identifier()
                try expect(")")
                let wanted: ValueType = name == "center" ? .point : .choice
                guard names[argument] == wanted else {
                    throw Problem(message: "\(name) takes \(wanted.noun) control, and \"\(argument)\" isn't one")
                }
                return name == "center" ? (.center(argument), .vector(2)) : (.index(argument), .number)
            }
            guard let count = Self.functionArity(name) else { throw Problem(message: "Unknown function \"\(name)\"") }
            var arguments: [Node] = []
            if current != ")" {
                repeat {
                    if !arguments.isEmpty { index += 1 }
                    let (node, type) = try comparison()
                    try requireNumber(type, "passed to \(name)")
                    arguments.append(node)
                } while current == ","
            }
            try expect(")")
            guard arguments.count == count else {
                throw Problem(message: "\(name) takes \(count) number\(count == 1 ? "" : "s"), not \(arguments.count)")
            }
            return (.call(name, arguments), .number)
        }

        private static func functionArity(_ name: String) -> Int? { EffectExpression.functions[name] }

        private mutating func identifier() -> String {
            let start = index
            while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                index += 1
            }
            return String(characters[start..<index])
        }

        private mutating func number() throws(Problem) -> Double {
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            let text = String(characters[start..<index])
            guard let value = Double(text), value.isFinite else { throw Problem(message: "\"\(text)\" isn't a number") }
            return value
        }

        private mutating func expect(_ character: Character) throws(Problem) {
            guard current == character else {
                throw Problem(message: current.map { "Expected \"\(character)\" instead of \"\($0)\"" } ?? "Missing \"\(character)\"")
            }
            index += 1
        }

        private func requireNumber(_ type: ValueType, _ verb: String) throws(Problem) {
            guard type == .number else { throw Problem(message: "Only numbers can be \(verb), not \(type.noun)") }
        }
    }
}
