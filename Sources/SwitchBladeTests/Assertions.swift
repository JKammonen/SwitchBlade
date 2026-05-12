import Foundation

/// Lightweight assertion helpers used by the in-process test runner.
/// Each helper throws on failure; the runner catches and prints a single failure
/// line plus file:line so the offending assertion is easy to find.
struct TestFailure: Error {
    let message: String
    let file: String
    let line: Int
}

func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if !condition {
        let m = message()
        throw TestFailure(message: m.isEmpty ? "expectation failed" : m, file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual != expected {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }
}

func expectNotEqual<T: Equatable>(
    _ actual: T,
    _ unexpected: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual == unexpected {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected != \(unexpected) but values are equal",
            file: file,
            line: line
        )
    }
}

func expectNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if value != nil {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(message: "\(prefix)expected nil, got \(value!)", file: file, line: line)
    }
}

func expectNotNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if value == nil {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(message: "\(prefix)expected non-nil", file: file, line: line)
    }
}

func expectLessThanOrEqual<T: Comparable>(
    _ actual: T,
    _ upperBound: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual > upperBound {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected \(actual) <= \(upperBound)",
            file: file,
            line: line
        )
    }
}

func expectGreaterThan<T: Comparable>(
    _ actual: T,
    _ lowerBound: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual <= lowerBound {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected \(actual) > \(lowerBound)",
            file: file,
            line: line
        )
    }
}

func expectGreaterThanOrEqual<T: Comparable>(
    _ actual: T,
    _ lowerBound: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual < lowerBound {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected \(actual) >= \(lowerBound)",
            file: file,
            line: line
        )
    }
}

func expectLessThan<T: Comparable>(
    _ actual: T,
    _ upperBound: T,
    _ message: @autoclosure () -> String = "",
    file: String = #file,
    line: Int = #line
) throws {
    if actual >= upperBound {
        let m = message()
        let prefix = m.isEmpty ? "" : "\(m): "
        throw TestFailure(
            message: "\(prefix)expected \(actual) < \(upperBound)",
            file: file,
            line: line
        )
    }
}
