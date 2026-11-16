import Foundation

/// The real interpreter the scripting suites run on, from `AMV_PYTHON`:
/// `AMV_PYTHON=<python3> swift test --filter "PythonHelper|Confinement"`. Nil when the
/// variable isn't set, and those suites are skipped.
///
/// It lives outside the suites so their `@Suite(.enabled(if:))` traits
/// can read it: a trait naming a suite type's own member makes the
/// `@Suite` macro depend on itself, which doesn't compile.
enum TestPython {
    static let interpreter = ProcessInfo.processInfo.environment["AMV_PYTHON"].map { URL(filePath: $0) }
}
