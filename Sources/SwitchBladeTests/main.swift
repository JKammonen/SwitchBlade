import AppKit
import Foundation

/// In-process test runner. Each test is a `@MainActor () async throws -> Void`
/// thunk; failures print as `✗ <name>  <file>:<line> <message>`.
/// Exit code is the number of failures (0 = green).
@MainActor
func runAll() async -> Int {
    let suites: [(String, [(String, @MainActor () async throws -> Void)])] = [
        ("WindowItem",              WindowItemTests.all),
        ("PermissionState",         PermissionStateTests.all),
        ("Localization",            LocalizationTests.all),
        ("SwitcherLayoutCalculator", SwitcherLayoutCalculatorTests.all),
        ("SwitcherStore",           SwitcherStoreTests.all)
    ]

    var passed = 0
    var failed: [(name: String, failure: TestFailure)] = []
    var unexpected: [(name: String, error: Error)] = []

    let started = Date()

    for (_, suite) in suites {
        for (name, thunk) in suite {
            do {
                try await thunk()
                print("✓ \(name)")
                passed += 1
            } catch let f as TestFailure {
                print("✗ \(name)\n    \(prettyFile(f.file)):\(f.line)  \(f.message)")
                failed.append((name, f))
            } catch {
                print("✗ \(name)\n    unexpected error: \(error)")
                unexpected.append((name, error))
            }
        }
    }

    let elapsed = Date().timeIntervalSince(started)
    let total = passed + failed.count + unexpected.count
    let failures = failed.count + unexpected.count

    print("")
    print(String(format: "Ran %d tests in %.2fs — %d passed, %d failed",
                 total, elapsed, passed, failures))

    return failures
}

/// Strip the repo prefix from file paths so output stays terse.
private func prettyFile(_ path: String) -> String {
    if let range = path.range(of: "/Sources/") {
        return String(path[range.upperBound...])
    }
    return path
}

// Entry point. Run on the main actor — SwitcherStore tests need it.
let failures = await MainActor.run { Task { @MainActor in await runAll() } }.value
exit(Int32(failures == 0 ? 0 : 1))
