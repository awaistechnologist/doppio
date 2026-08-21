import Foundation

/// A dependency-free test harness.
///
/// The project deliberately builds with the Command Line Tools alone, where
/// neither XCTest nor swift-testing is available, so the suite is a plain
/// executable: `swift run DoppioTests` exits non-zero if anything fails, which
/// is all CI needs.
enum Check {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var currentTest = ""

    static func expect(_ condition: Bool, _ message: String,
                       file: String = #fileID, line: Int = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("\(currentTest): \(message)  (\(file):\(line))")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                                    file: String = #fileID, line: Int = #line) {
        expect(actual == expected, "\(message) — expected \(expected), got \(actual)",
               file: file, line: line)
    }

    static func require<T>(_ value: T?, _ message: String,
                           file: String = #fileID, line: Int = #line) throws -> T {
        guard let value else {
            failures.append("\(currentTest): \(message) was nil  (\(file):\(line))")
            throw HarnessError.requirementFailed(message)
        }
        return value
    }
}

enum HarnessError: Error { case requirementFailed(String) }

struct TestCase {
    let name: String
    let run: () throws -> Void
}

func runSuite(_ suiteName: String, _ tests: [TestCase]) {
    print("\n\(suiteName)")
    for test in tests {
        Check.currentTest = "\(suiteName).\(test.name)"
        let before = Check.failures.count
        do {
            try test.run()
        } catch {
            if case HarnessError.requirementFailed = error {} else {
                Check.failures.append("\(Check.currentTest): threw \(error)")
            }
        }
        let ok = Check.failures.count == before
        print("  \(ok ? "✓" : "✗") \(test.name)")
    }
}
