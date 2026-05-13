import Foundation
@testable import SwitchBladeCore

enum LockedValueTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("LockedValue/roundTrip_singleThread", roundTrip),
        ("LockedValue/concurrentWrites_dontCorrupt", concurrentWrites)
    ]

    static func roundTrip() throws {
        let v = LockedValue<Int>(42)
        try expectEqual(v.value, 42)
        v.value = 7
        try expectEqual(v.value, 7)
    }

    /// Smoke test: many concurrent writes from multiple queues shouldn't crash
    /// or land in a state outside the set of values we wrote. The exact final
    /// value isn't deterministic, but it must be one of 0..<writers.
    static func concurrentWrites() async throws {
        let v = LockedValue<Int>(-1)
        let writers = 200
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< writers {
                group.addTask { v.value = i }
            }
        }
        try expect((0 ..< writers).contains(v.value), "got out-of-range value \(v.value)")
    }
}
