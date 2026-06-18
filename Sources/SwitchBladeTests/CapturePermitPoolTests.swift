import Foundation
@testable import SwitchBladeCore

enum CapturePermitPoolTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CapturePermitPool/thirdAcquireWaitsForRelease", thirdAcquireWaitsForRelease),
        ("CapturePermitPool/contendedAcquiresDoNotStrandWaiters", contendedAcquiresDoNotStrandWaiters)
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

    @MainActor static func contendedAcquiresDoNotStrandWaiters() async throws {
        let limit = 4
        let pool = CapturePermitPool(limit: limit)
        let active = LockedValue(0)
        let maxActive = LockedValue(0)

        let work = Task.detached(priority: .userInitiated) { () -> Int in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 80 {
                    group.addTask {
                        await pool.acquire()
                        let current = active.withValue { value in
                            value += 1
                            return value
                        }
                        maxActive.withValue { value in
                            value = max(value, current)
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        active.withValue { value in
                            value -= 1
                        }
                        pool.release()
                    }
                }
            }
            return maxActive.value
        }

        let result = await SCContentCache.awaitTaskWithSoftTimeout(work, timeoutMs: 2_000)
        switch result {
        case .completed(let observedMax):
            try expectLessThanOrEqual(observedMax, limit)
            try expectEqual(active.value, 0)
        case .timedOut:
            try expect(false, "contended acquire/release should not strand waiters")
        }
    }
}
