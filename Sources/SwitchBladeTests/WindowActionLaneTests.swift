import AppKit
import Foundation
@testable import SwitchBladeCore

/// The single window-action lane stays occupied after `hide()` drops the
/// caller task, because detached AX work cannot be interrupted. A commit that
/// arrives meanwhile must surface as a refused action, never vanish silently.
enum WindowActionLaneTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowActionLane/cachedQuickReleaseOnBusyLaneShowsRecoveryPanel", cachedQuickReleaseOnBusyLane),
        ("WindowActionLane/freshQuickReleaseOnBusyLaneDoesNotWedgeOpen", freshQuickReleaseOnBusyLane)
    ]

    @MainActor private static func cachedQuickReleaseOnBusyLane() async throws {
        let (store, catalog, activator, _) = makeStore()
        defer { store.cancel() }
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300)
        ]
        try await occupyLaneWithCancelledClose(store, activator: activator)

        store.requestCycle(forward: true)
        store.commitSelection()
        await runPendingMainTasks()
        try expect(store.isVisible, "refused quick release must show the recovery panel")
        try expect(activator.activatedItems.isEmpty)

        try await waitForLane(activator)
        let selected = try unwrap(store.selectedID)
        store.commitSelection()
        try await waitUntil { activator.activatedItems.map(\.id) == [selected] }
        try expect(!store.isVisible)
        try expect(!store.isSwitching)
    }

    @MainActor private static func freshQuickReleaseOnBusyLane() async throws {
        let (store, catalog, activator, _) = makeStore(initialFrontmostAppPID: 100, switchBladePID: 999)
        defer { store.cancel() }
        // Two windows of the current app force the fresh off-main snapshot
        // path, whose quick release used to leave the open phase resolving.
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true),
            makeItem(id: 4, pid: 100, isFrontmostApp: true),
            makeItem(id: 2, pid: 200),
            makeItem(id: 3, pid: 300)
        ]
        try await occupyLaneWithCancelledClose(store, activator: activator)

        store.requestCycle(forward: true)
        store.commitSelection()
        try await waitUntil { store.isVisible }
        try expect(activator.activatedItems.isEmpty)

        try await waitForLane(activator)
        store.cancel()
        try expect(!store.isSwitching, "cancel must leave the open lifecycle idle")
        await openSwitcher(store)
        try expect(store.isVisible, "a later Cmd+Tab must open the switcher again")
    }

    /// Starts a delayed close from the visible panel, then dismisses it the way
    /// a click outside does. The detached close keeps the lane busy afterwards.
    @MainActor private static func occupyLaneWithCancelledClose(
        _ store: SwitcherStore,
        activator: MockWindowActivator
    ) async throws {
        await openSwitcher(store)
        try expect(store.isVisible)
        activator.actionDelayNanoseconds = 300_000_000
        let closeTarget = try unwrap(store.items.last)
        store.close(closeTarget)
        store.cancel()
        await runPendingMainTasks()
        try expect(!store.isVisible)
        try expect(activator.closedItems.isEmpty, "close must still be running in the detached lane")
    }

    @MainActor private static func waitForLane(_ activator: MockWindowActivator) async throws {
        try await waitUntil { !activator.closedItems.isEmpty }
        activator.actionDelayNanoseconds = 0
        await runPendingMainTasks()
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "operation did not reach the expected state")
    }

    private static func unwrap<T>(_ value: T?, file: String = #file, line: Int = #line) throws -> T {
        guard let value else {
            throw TestFailure(message: "unexpected nil", file: file, line: line)
        }
        return value
    }
}
