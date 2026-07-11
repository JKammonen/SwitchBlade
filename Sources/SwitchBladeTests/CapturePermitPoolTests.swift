import Darwin
import Foundation
@testable import SwitchBladeCore

enum CapturePermitPoolTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CapturePermitPool/thirdAcquireWaitsForRelease", thirdAcquireWaitsForRelease),
        ("CapturePermitPool/contendedAcquiresDoNotStrandWaiters", contendedAcquiresDoNotStrandWaiters),
        ("CapturePermitPool/softTimeoutRetainsPermitUntilUnderlyingWorkReturns", softTimeoutRetainsPermitUntilUnderlyingWorkReturns),
        ("InFlightTaskCoalescer/concurrentConsumersShareUnderlyingWork", concurrentConsumersShareUnderlyingWork),
        ("InFlightTaskCoalescer/contextChangeWaitsThenStartsFreshWork", contextChangeWaitsThenStartsFreshWork),
        ("InFlightTaskCoalescer/cancelledContextDoesNotLaunchAbandonedWork", cancelledContextDoesNotLaunchAbandonedWork),
        ("InFlightTaskCoalescer/newEpochDoesNotReuseSameContextResult", newEpochDoesNotReuseSameContextResult),
        ("AXScanBudget/capsApplicationsWindowsAndElapsedTime", axScanBudgetCapsAllDimensions),
        ("WindowActionCoordinator/holdsLaneUntilDetachedWorkReturns", windowActionCoordinatorHoldsLane)
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

    @MainActor static func softTimeoutRetainsPermitUntilUnderlyingWorkReturns() async throws {
        let pool = CapturePermitPool(limit: 1)
        let firstStart = Date()
        let first = await SCContentCache.runPermitBoundOperation(
            permitPool: pool,
            timeoutMs: 50,
            operation: {
                usleep(200_000)
                return 7
            }
        )
        let firstElapsedMs = Date().timeIntervalSince(firstStart) * 1_000

        switch first {
        case .timedOut:
            break
        case .completed, .resourceLimited:
            try expect(false, "first blocked operation should hit the UX timeout")
        }
        try expectLessThan(firstElapsedMs, 160)

        let secondStart = Date()
        let second = await SCContentCache.runPermitBoundOperation(
            permitPool: pool,
            timeoutMs: 50,
            operation: { 9 }
        )
        let secondElapsedMs = Date().timeIntervalSince(secondStart) * 1_000
        switch second {
        case .resourceLimited:
            break
        case .completed, .timedOut:
            try expect(false, "global permit was released by the UX timeout instead of underlying completion")
        }
        try expectLessThan(secondElapsedMs, 40)

        try? await Task.sleep(nanoseconds: 180_000_000)
        try expect(pool.tryAcquire(), "permit should return after the blocked operation actually exits")
        pool.release()
    }

    @MainActor static func concurrentConsumersShareUnderlyingWork() async throws {
        let coalescer = InFlightTaskCoalescer<String, Int>()
        let starts = LockedValue(0)

        let first = Task.detached {
            await coalescer.value(for: "same-context") {
                starts.withValue { $0 += 1 }
                usleep(120_000)
                return 42
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let second = Task.detached {
            await coalescer.value(for: "same-context") {
                starts.withValue { $0 += 1 }
                return 99
            }
        }

        try expectEqual(await first.value, 42)
        try expectEqual(await second.value, 42)
        try expectEqual(starts.value, 1)

        let next = await coalescer.value(for: "same-context") {
            starts.withValue { $0 += 1 }
            return 7
        }
        try expectEqual(next, 7)
        try expectEqual(starts.value, 2, "completed work should be cleared for the next snapshot")
    }

    @MainActor static func contextChangeWaitsThenStartsFreshWork() async throws {
        let coalescer = InFlightTaskCoalescer<String, Int>()
        let active = LockedValue(0)
        let maxActive = LockedValue(0)

        let operation: @Sendable (Int, useconds_t) async -> Int = { result, delayMicroseconds in
            let current = active.withValue { value in
                value += 1
                return value
            }
            maxActive.withValue { $0 = max($0, current) }
            usleep(delayMicroseconds)
            active.withValue { $0 -= 1 }
            return result
        }

        let oldContext = Task.detached {
            await coalescer.value(for: "app-a") {
                await operation(1, 120_000)
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let newContext = Task.detached {
            await coalescer.value(for: "app-b") {
                await operation(2, 10_000)
            }
        }

        try expectEqual(await oldContext.value, 1)
        try expectEqual(await newContext.value, 2)
        try expectEqual(maxActive.value, 1, "different minimized-snapshot contexts must not overlap")
    }

    @MainActor static func cancelledContextDoesNotLaunchAbandonedWork() async throws {
        let coalescer = InFlightTaskCoalescer<String, String>()
        let starts = LockedValue<[String]>([])

        let first = Task.detached {
            await coalescer.value(for: "app-a") {
                starts.withValue { $0.append("app-a") }
                usleep(120_000)
                return "app-a"
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let abandoned = Task.detached {
            await coalescer.value(for: "app-b") {
                starts.withValue { $0.append("app-b") }
                return "app-b"
            }
        }
        abandoned.cancel()
        let current = Task.detached {
            await coalescer.value(for: "app-c") {
                starts.withValue { $0.append("app-c") }
                return "app-c"
            }
        }

        try expectEqual(await first.value, "app-a")
        try expectNil(await abandoned.value)
        try expectEqual(await current.value, "app-c")
        try expectEqual(starts.value, ["app-a", "app-c"])
    }

    @MainActor static func newEpochDoesNotReuseSameContextResult() async throws {
        struct Context: Hashable, Sendable {
            let app: String
            let epoch: UInt64
        }

        let coalescer = InFlightTaskCoalescer<Context, Int>()
        let starts = LockedValue(0)
        let first = Task.detached {
            await coalescer.value(for: Context(app: "same-app", epoch: 1)) {
                starts.withValue { $0 += 1 }
                usleep(80_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let reopened = Task.detached {
            await coalescer.value(for: Context(app: "same-app", epoch: 2)) {
                starts.withValue { $0 += 1 }
                return 2
            }
        }

        try expectEqual(await first.value, 1)
        try expectEqual(await reopened.value, 2)
        try expectEqual(starts.value, 2)
    }

    @MainActor static func axScanBudgetCapsAllDimensions() throws {
        var appBudget = AXScanBudget(
            maximumApplications: 2,
            maximumWindows: 10,
            maximumElapsedSeconds: 5,
            startedAt: 100
        )
        try expect(appBudget.beginApplication(now: 100))
        try expect(appBudget.beginApplication(now: 101))
        try expect(!appBudget.beginApplication(now: 102))
        try expect(appBudget.isExhausted)

        var windowBudget = AXScanBudget(
            maximumApplications: 10,
            maximumWindows: 1,
            maximumElapsedSeconds: 5,
            startedAt: 100
        )
        try expect(windowBudget.beginWindow(now: 100))
        try expect(!windowBudget.beginWindow(now: 100))

        var timeBudget = AXScanBudget(
            maximumApplications: 10,
            maximumWindows: 10,
            maximumElapsedSeconds: 2,
            startedAt: 100
        )
        try expect(!timeBudget.beginApplication(now: 102))
        try expect(timeBudget.isExhausted)
    }

    @MainActor static func windowActionCoordinatorHoldsLane() async throws {
        let coordinator = WindowActionCoordinator()
        let starts = LockedValue(0)
        let first = Task.detached {
            await coordinator.run {
                starts.withValue { $0 += 1 }
                usleep(100_000)
                return true
            }
        }
        for _ in 0 ..< 50 where starts.value == 0 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        try expectEqual(starts.value, 1)

        let overlapping = await coordinator.run {
            starts.withValue { $0 += 1 }
            return true
        }
        try expectNil(overlapping)
        try expectEqual(await first.value, true)

        let afterReturn = await coordinator.run {
            starts.withValue { $0 += 1 }
            return true
        }
        try expectEqual(afterReturn, true)
        try expectEqual(starts.value, 2)
    }
}
