import Foundation
@testable import SwitchBladeCore

enum CapturePermitPoolTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CapturePermitPool/thirdAcquireWaitsForRelease", thirdAcquireWaitsForRelease)
    ]

    @MainActor static func thirdAcquireWaitsForRelease() async throws {
        let pool = CapturePermitPool(limit: 2)
        let flag = LockedValue(false)

        await pool.acquire()
        await pool.acquire()

        let waiter = Task {
            await pool.acquire()
            flag.value = true
            pool.release()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        try expect(!flag.value, "third acquire should still be blocked while both permits are held")

        pool.release()

        for _ in 0 ..< 20 where !flag.value {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        try expect(flag.value, "third acquire should resume after a permit is released")

        pool.release()
        _ = await waiter.result
    }
}
