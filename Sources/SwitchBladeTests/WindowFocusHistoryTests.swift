import AppKit
import ApplicationServices
@testable import SwitchBladeCore

/// Real-scale focus histories without native windows, input, or activation.
enum WindowFocusHistoryTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("FocusHistory/newSameAppBookingSurvivesExternalDeparture", sameAppBooking),
        ("FocusHistory/pendingFocusSurvivesDeparture", pendingFocus),
        ("FocusHistory/currentScanWinsOverOlderFocusNotification", prePanelDrift),
        ("FocusHistory/newerDepartureDiscardsOldResolution", newerDeparture),
        ("FocusHistory/spaceChangeDiscardsPendingResolution", spaceChange),
        ("FocusHistory/backgroundNotificationIsIgnored", backgroundNotification),
        ("FocusHistory/unresolvedCaptureRetainsIncomingUpgrade", unresolvedCapture),
        ("FocusHistory/incomingUpgradePreservesDepartureEvidence", upgradedDeparture),
        ("FocusHistory/newFocusInvalidatesMainOnlyCacheBeforeResolution", invalidatesYoungCache),
        ("FocusHistory/initialKnownFocusPreservesSingleWindowFastPath", initialKnownFocus),
        ("FocusHistory/initialUnknownFocusInvalidatesMainOnlyCache", initialUnknownFocus),
        ("FocusHistory/transientObserverRegistrationRetriesOnce", registrationRetries),
        ("FocusHistory/appChangeCancelsOldRegistrationRetry", registrationAppChange),
        ("FocusHistory/unsupportedObserverDoesNotRetry", registrationUnsupported),
        ("FocusHistory/repeatedRegistrationFailureRemainsBounded", registrationBounded),
        ("FocusHistory/registrationRetryPreservesWorkingSubscriptions", preservesSubscriptions)
    ]

    @MainActor private final class Observer: WindowFocusObserving {
        var onFocus: ((WindowFocusCapture) -> Void)?
        var observedPIDs: [pid_t?] = []
        func observe(pid: pid_t?) { observedPIDs.append(pid) }
        func emit(_ item: WindowItem, gate: LockedValue<Bool>? = nil) {
            onFocus?(WindowFocusCapture(pid: item.pid, resolve: {
                // A bounded stand-in for a CG/AX resolution still in flight.
                let deadline = Date().addingTimeInterval(2)
                while gate?.value == false, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                return item
            }))
        }
    }

    @MainActor private final class Fixture {
        let observer = Observer()
        let catalog = MockWindowCatalog()
        let tracker = MRUTracker(userDefaults: makeIsolatedUserDefaults())
        let booking = makeItem(id: 17, pid: 100, title: "New booking", isFrontmostApp: true, bundleIdentifier: "fixture.outlook")
        let main = makeItem(id: 1, pid: 100, title: "Calendar", isFrontmostApp: true, bundleIdentifier: "fixture.outlook")
        let others = (2...16).map { makeItem(id: UInt32($0), pid: pid_t($0 * 100), bundleIdentifier: "fixture.\($0)") }
        let store: SwitcherStore
        var windows: [WindowItem] { [booking] + others + [main] }

        init() {
            store = SwitcherStore(
                catalog: catalog, activator: MockWindowActivator(), permissionService: MockPermissionService(),
                windowFocusObserver: observer, userDefaults: makeIsolatedUserDefaults(), mruTracker: tracker,
                focusedRankUpgradeDelayNanoseconds: 0, workspaceNotificationCenter: NotificationCenter(),
                initialFrontmostAppPID: 100, switchBladePID: 999
            )
            for item in ([main] + others).reversed() { tracker.trackFocusedWindowActivation(item) }
            // No booking in the young cache, and no app activation when it opens.
            catalog.visibleItems = [main] + others
            catalog.focusedWindowItemsByPID[100] = main
            catalog.focusedWindowItemsByPID[200] = others[0]
        }

        func depart(to pid: pid_t = 200) {
            catalog.visibleItems = windows.map { $0.withFrontmostState($0.pid == pid) }
            store.handleAppActivation(pid: pid)
        }

        func assertBookingSecond() throws {
            let order = tracker.orderedForDisplay(from: catalog.visibleItems)
            try expectEqual(Array(order.prefix(2).map(\.id)), [2, 17],
                            "predeparture booking focus must survive Outlook reporting main after deactivation")
            try expectEqual(order[2].id, main.id, "unvisited siblings keep their existing rank")
            try expectEqual(catalog.focusedWindowItemCallCount, 1,
                            "only incoming app needs a late focus probe; outgoing focus was captured")
        }
    }

    @MainActor private static func sameAppBooking() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        await f.store.warmPreviewCache(context: "main-only-cache")
        f.observer.emit(f.booking)
        try await waitUntil { f.tracker.recentWindowIDs.first == 17 }
        f.depart()
        try await waitUntil { f.catalog.focusedWindowItemCallCount >= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        try f.assertBookingSecond()
    }

    @MainActor private static func pendingFocus() async throws {
        let f = Fixture()
        let gate = LockedValue(false)
        defer { gate.value = true; f.store.cancel() }
        f.observer.emit(f.booking, gate: gate)
        f.depart()
        gate.value = true
        try await waitUntil { f.tracker.recentWindowIDs.contains(17) && f.catalog.focusedWindowItemCallCount >= 1 }
        try f.assertBookingSecond()
    }

    @MainActor private static func prePanelDrift() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        f.observer.emit(f.booking)
        try await waitUntil { f.tracker.recentWindowIDs.first == 17 }
        f.catalog.visibleItems = [f.main] + f.others + [f.booking]
        f.catalog.snapshotFocusedWindow = f.main
        await openSwitcher(f.store)
        try expectEqual(f.store.items.first?.id, 1,
                        "a current AX-confirmed scan must win over earlier focus history")
        let completion = selectionCompletionProbe()
        defer { completion.restore() }
        f.store.selectedID = 2
        f.store.commitSelection()
        try await waitUntil { completion.completed.value }
        let order = f.tracker.orderedForDisplay(from: f.windows.map { $0.withFrontmostState($0.pid == 200) })
        try expectEqual(Array(order.prefix(2).map(\.id)), [2, 1])
    }

    @MainActor private static func newerDeparture() async throws {
        let f = Fixture()
        let gate = LockedValue(false)
        defer { gate.value = true; f.store.cancel() }
        f.observer.emit(f.booking, gate: gate)
        f.depart()
        f.catalog.focusedWindowItemsByPID[300] = f.others[1]
        f.depart(to: 300)
        gate.value = true
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(!f.tracker.recentWindowIDs.contains(17), "older source must not rewrite a newer transition")
    }

    @MainActor private static func spaceChange() async throws {
        let f = Fixture()
        let gate = LockedValue(false)
        defer { gate.value = true; f.store.cancel() }
        f.observer.emit(f.booking, gate: gate)
        await f.store.handleActiveSpaceChange()
        gate.value = true
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(!f.tracker.recentWindowIDs.contains(17))
    }

    @MainActor private static func backgroundNotification() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        f.depart()
        f.observer.emit(f.booking)
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(!f.tracker.recentWindowIDs.contains(17))
    }

    @MainActor private static func unresolvedCapture() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        f.depart()
        f.observer.onFocus?(WindowFocusCapture(pid: 200, resolve: { nil }))
        try await waitUntil { f.tracker.recentWindowIDs.first == 2 }
    }

    @MainActor private static func upgradedDeparture() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        await f.store.warmPreviewCache(context: "incoming-upgrade-cache")
        f.depart()
        f.observer.onFocus?(WindowFocusCapture(pid: 200, resolve: { nil }))
        try await waitUntil { f.tracker.recentWindowIDs.first == 2 }
        let unrelatedSibling = makeItem(id: 18, pid: 200, title: "Unvisited sibling", bundleIdentifier: "fixture.2")
        f.catalog.focusedWindowItemsByPID[200] = unrelatedSibling
        f.catalog.focusedWindowItemsByPID[300] = f.others[1]
        f.depart(to: 300)
        f.catalog.visibleItems.append(unrelatedSibling)
        try await waitUntil { f.tracker.recentWindowIDs.first == 3 }
        try await Task.sleep(nanoseconds: 20_000_000)
        let order = f.tracker.orderedForDisplay(from: f.catalog.visibleItems)
        try expectEqual(Array(order.prefix(2).map(\.id)), [3, 2],
                        "a recovered foreground match must be retained before the next app departure")
    }

    @MainActor private static func invalidatesYoungCache() async throws {
        let f = Fixture()
        let gate = LockedValue(false)
        defer { gate.value = true; f.store.cancel() }
        await f.store.warmPreviewCache(context: "main-only-cache")
        f.observer.emit(f.booking, gate: gate)
        f.catalog.visibleItems = f.windows
        f.catalog.snapshotFocusedWindow = f.booking
        f.store.requestCycle(forward: true)
        try expect(!f.store.isVisible, "must not paint main-only cached membership while new focus is unresolved")
        try await waitUntil { f.store.isVisible }
        try expectEqual(f.store.items.first?.id, 17,
                        "opening must not wait for background focus resolution")
        gate.value = true
    }
    @MainActor private static func initialKnownFocus() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        await f.store.warmPreviewCache(context: "known-focus-cache")
        let resolved = LockedValue(false)
        let main = f.main
        f.observer.onFocus?(WindowFocusCapture(pid: 100, invalidatesMembership: false, resolve: {
            resolved.value = true
            return main
        }))
        try await waitUntil { resolved.value }
        try await Task.sleep(nanoseconds: 10_000_000)
        let snapshots = f.catalog.visibleSnapshotCount
        f.catalog.visibleSnapshotDelayNanoseconds = 100_000_000
        f.store.requestCycle(forward: true)
        try expect(f.store.isVisible, "initial observation of a known window must retain immediate cached paint")
        try expectEqual(f.catalog.visibleSnapshotCount, snapshots)
    }

    @MainActor private static func initialUnknownFocus() async throws {
        let f = Fixture()
        defer { f.store.cancel() }
        await f.store.warmPreviewCache(context: "unknown-focus-cache")
        let booking = f.booking
        f.observer.onFocus?(WindowFocusCapture(pid: 100, invalidatesMembership: false, resolve: { booking }))
        try await waitUntil { f.tracker.recentWindowIDs.first == 17 }
        f.catalog.visibleItems = f.windows
        f.catalog.snapshotFocusedWindow = booking
        f.store.requestCycle(forward: true)
        try expect(!f.store.isVisible, "a newly discovered window must bypass main-only rebasing")
        try await waitUntil { f.store.isVisible }
        try expectEqual(f.store.items.first?.id, 17)
    }

    @MainActor private static func registrationRetries() async throws {
        var attempts: [pid_t] = []
        let driver = WindowFocusRegistration(retryDelay: 5_000_000, attempt: { pid, index in
            attempts.append(pid)
            return index == 0 ? .cannotComplete : .success
        }, reset: {})
        driver.observe(pid: 100)
        driver.observe(pid: 100)
        try await waitUntil { driver.registeredPID == 100 }
        try expectEqual(attempts, [100, 100], "one transient activation error must not disable same-app tracking")
    }

    @MainActor private static func registrationAppChange() async throws {
        var attempts: [pid_t] = []
        let driver = WindowFocusRegistration(retryDelay: 5_000_000, attempt: { pid, _ in
            attempts.append(pid)
            return pid == 100 ? .cannotComplete : .success
        }, reset: {})
        driver.observe(pid: 100)
        driver.observe(pid: 200)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expectEqual(driver.registeredPID, 200)
        try expectEqual(attempts, [100, 200], "an old retry cannot replace the current app's observer")
        driver.observe(pid: nil)
        try expectEqual(driver.registeredPID, nil)
    }

    @MainActor private static func registrationUnsupported() async throws {
        var count = 0
        let driver = WindowFocusRegistration(retryDelay: 5_000_000, attempt: { _, _ in
            count += 1
            return .notificationUnsupported
        }, reset: {})
        driver.observe(pid: 100)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expectEqual(count, 1)
    }

    @MainActor private static func registrationBounded() async throws {
        var count = 0
        let driver = WindowFocusRegistration(retryDelay: 5_000_000, attempt: { _, _ in
            count += 1
            return .cannotComplete
        }, reset: {})
        driver.observe(pid: 100)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expectEqual(count, 2, "a hung app must not create a registration polling loop")
    }

    @MainActor private static func preservesSubscriptions() throws {
        var subscriptions = WindowFocusSubscriptions()
        var calls: [String] = []
        let first = subscriptions.register { notification in
            calls.append(notification)
            return notification == kAXFocusedWindowChangedNotification ? .success : .cannotComplete
        }
        try expectEqual(first.map(\.rawValue), [0, -25204, -25204])
        try expect(subscriptions.registered.contains(kAXFocusedWindowChangedNotification))
        calls.removeAll()
        let retry = subscriptions.register { notification in
            calls.append(notification)
            return notification == kAXMainWindowChangedNotification ? .success : .cannotComplete
        }
        try expectEqual(retry.map(\.rawValue), [0, 0, -25204])
        try expectEqual(calls, [kAXMainWindowChangedNotification, kAXWindowCreatedNotification],
                        "an optional failure must not discard or re-register working primary focus coverage")
        try expectEqual(subscriptions.registered.count, 2)
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(false, "mock operation did not reach the expected state")
    }

    private static func selectionCompletionProbe() -> (completed: LockedValue<Bool>, restore: () -> Void) {
        let completed = LockedValue(false)
        let previousObserver = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previousObserver?(event, fields)
            if event == "selection_action_dispatch" || event == "selection_action_failed" {
                completed.value = true
            }
        }
        return (completed, { PerformanceDiagnostics.testObserver.value = previousObserver })
    }


}
