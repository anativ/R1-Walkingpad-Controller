import Foundation

/// Minimal check harness. This project builds against the Command Line Tools SDK,
/// which ships neither XCTest nor swift-testing, so the protocol assertions run as a
/// plain executable instead: `padctl selftest`.
enum Check {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var currentTest = ""
}

struct RequirementUnmet: Error { let message: String }

func check(_ condition: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    Check.checks += 1
    if !condition {
        let detail = message.isEmpty ? "" : " — \(message)"
        Check.failures.append("\(Check.currentTest): failed at \(file):\(line)\(detail)")
    }
}

func fail(_ message: String, file: String = #fileID, line: Int = #line) {
    Check.failures.append("\(Check.currentTest): \(message) (\(file):\(line))")
}

func require<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    Check.checks += 1
    guard let value else {
        Check.failures.append("\(Check.currentTest): required value was nil at \(file):\(line)")
        throw RequirementUnmet(message: "nil at \(file):\(line)")
    }
    return value
}

func runSelfTest(_ tests: [(String, () throws -> Void)]) -> Int32 {
    for (name, body) in tests {
        Check.currentTest = name
        let before = Check.failures.count
        do {
            try body()
        } catch {
            Check.failures.append("\(name): threw \(error)")
        }
        let ok = Check.failures.count == before
        print("  \(ok ? "✓" : "✗") \(name)")
    }
    print("")
    if Check.failures.isEmpty {
        print("All \(tests.count) checks passed (\(Check.checks) assertions).")
        return 0
    }
    print("\(Check.failures.count) failure(s):")
    for failure in Check.failures { print("  • \(failure)") }
    return 1
}
