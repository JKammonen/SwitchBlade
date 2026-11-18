import AppKit
import Carbon
@testable import SwitchBladeCore

/// The agreed outcome/modifier table, exercised through the public store paths.
enum DeferredInputTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("DeferredInput/selectionSuccessUsesCompletedOrder", selectionSuccess),
        ("DeferredInput/selectionFailureAndRefusalStayInRecovery", selectionRecovery),
        ("DeferredInput/previousSwitchOutcomesRespectModifier", previousOutcomes),
        ("DeferredInput/expiryRejectsBothOrigins", expiry),
        ("DeferredInput/cancelledTaskStillWaitsForItsNativeLane", cancelledLane),
        ("DeferredInput/navigationAndLiveModifierStateWin", navigation),
        ("DeferredInput/cancellationSourcesDiscardQueuedInput", cancellation),
        ("DeferredInput/expiryAlsoAppliesDuringFreshOpening", expiryDuringOpen),
        ("DeferredInput/cancelledRefusalDoesNotReopen", cancelledRefusalDoesNotReopen),
        ("DeferredInput/freshInputCanCommitRecoveryOpening", freshInputCanCommitRecoveryOpening)
    ]
    @MainActor private final class Fixture {
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let store: SwitcherStore
        var flags: CGEventFlags = []
        var clock = DispatchTime.now().uptimeNanoseconds
        init(coordinator: WindowActionCoordinator = WindowActionCoordinator(), sameApp: Bool = false) {
            catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true),
                makeItem(id: 2, pid: sameApp ? 100 : 200), makeItem(id: 3, pid: sameApp ? 100 : 300)]
            store = SwitcherStore(catalog: catalog, activator: activator, permissionService: MockPermissionService(),
                userDefaults: makeIsolatedUserDefaults(), activationWarmupWindow: -1,
                focusedRankUpgradeDelayNanoseconds: 0, workspaceNotificationCenter: NotificationCenter(),
                initialFrontmostAppPID: 100, windowActionCoordinator: coordinator)
            store.deferredInputClock = { [weak self] in self?.clock ?? 0 }
            store.deferredModifierFlags = { [weak self] in self?.flags ?? [] }
        }
        var calls: Int { activator.activatedItems.count + activator.activatedApplicationPIDs.count }
        func advance(_ ms: UInt64) {
            clock += ms * 1_000_000
        }
        func startSelection() async throws {
            await openSwitcher(store)
            try expectEqual(store.selectedID, 2)
            activator.actionDelayNanoseconds = 80_000_000
            store.commitSelection()
            // Model the native switch's real resulting snapshot. Leaving A
            // frontmost here would make ordinary stale-cache healing undo B.
            if activator.activationSucceeds {
                catalog.visibleItems = catalog.visibleItems.map { $0.withFrontmostState($0.pid == 200) }
            }
        }
        func startPrevious(fast: Bool) async throws {
            if fast { await openSwitcher(store); store.cancel() }
            activator.actionDelayNanoseconds = 80_000_000
            store.switchToPreviousApplication()
            try await DeferredInputTests.wait { self.activator.startedActionCount > 0 }
            if activator.applicationActivationSucceeds, activator.activationResultOverride != .applicationOnly,
               let target = catalog.visibleItems.first(where: { $0.id == 2 }) {
                catalog.visibleItems = [target.withFrontmostState(true)] + catalog.visibleItems.filter { $0.id != 2 }.map { $0.withFrontmostState($0.pid == target.pid) }
            }
        }
        func finish() { store.cancel() }
    }
    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try expect(false, "deferred-input state did not settle")
    }
    @MainActor static func selectionSuccess() async throws {
        for result in [WindowActivationResult.selectedTarget, .applicationOnly] {
          for held in [true, false] {
            let f = Fixture(); defer { f.finish() }
            f.activator.activationResultOverride = result
            f.flags = held ? SwitchBladeSettings.shared.modifier.cgFlag : []
            try await f.startSelection()
            f.store.requestCycle(forward: true, eventTimestamp: f.clock)
            try expect(f.store.shouldTrackModifierRelease)
            f.store.handleAppActivation(pid: 200) // expected own activation must not cancel the input
            if !held { f.store.commitSelection() }
            try await wait { held ? f.store.isVisible : f.calls == 2 }
            if held {
                try expectEqual(f.store.selectedID, 1, "default must be A after B completes")
                try expectEqual(f.calls, 1)
            } else { try expectEqual(f.activator.activatedItems.last?.id, 1) }
          }
        }
    }
    @MainActor static func selectionRecovery() async throws {
        for refused in [false, true] {
            for held in [true, false] {
                let coordinator = WindowActionCoordinator()
                let f = Fixture(coordinator: coordinator); defer { f.finish() }
                f.flags = held ? SwitchBladeSettings.shared.modifier.cgFlag : []
                var blocker: Task<Bool?, Never>?
                if refused {
                    let entered = LockedValue(false)
                    blocker = Task { await coordinator.run {
                        entered.value = true; Thread.sleep(forTimeInterval: 0.15); return true
                    } }
                    try await wait { entered.value }
                } else { f.activator.activationSucceeds = false }
                try await f.startSelection()
                f.store.requestCycle(forward: true)
                if !held { f.store.commitSelection() }
                try await wait { f.store.isVisible }
                try expectEqual(f.store.selectedID, 3, "deferred forward moves the failed B selection to C")
                let calls = f.calls
                await runPendingMainTasks()
                try expectEqual(f.calls, calls, "recovery must not auto-activate a released input")
                if let blocker { _ = await blocker.value }
            }
        }
    }
    @MainActor static func cancelledRefusalDoesNotReopen() async throws {
        let coordinator = WindowActionCoordinator(), entered = LockedValue(false)
        let blocker = Task { await coordinator.run {
            entered.value = true; Thread.sleep(forTimeInterval: 0.15); return true
        } }
        try await wait { entered.value }
        let f = Fixture(coordinator: coordinator); defer { f.finish() }
        try await f.startSelection()
        f.store.cancel()
        _ = await blocker.value; await runPendingMainTasks()
        try expect(!f.store.isVisible && !f.store.isSwitching, "refusal cannot resurrect a cancelled panel")
    }
    @MainActor static func freshInputCanCommitRecoveryOpening() async throws {
        let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = old }
        let f = Fixture(); defer { f.finish() }
        f.activator.applicationActivationSucceeds = false
        try await f.startPrevious(fast: false)
        f.catalog.visibleSnapshotDelayNanoseconds = 150_000_000
        f.store.requestCycle(forward: true); f.store.commitSelection()
        try await wait { f.store.isSwitching }
        f.store.requestCycle(forward: true); f.store.commitSelection()
        try await wait { f.activator.activatedItems.count == 1 }
        try expectEqual(f.activator.activatedItems.last?.id, 3, "new explicit gesture owns the recovery opening")
    }
    @MainActor static func previousOutcomes() async throws {
        let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = old }
        // Fast app, snapshot app, and exact same-app window paths have different completions.
        for path in 0..<3 {
            for success in [true, false] {
                for held in [true, false] {
                    let f = Fixture(sameApp: path == 2); defer { f.finish() }
                    f.flags = held ? settings.modifier.cgFlag : []
                    if !success {
                        if path == 2 { f.activator.activationResultOverride = .applicationOnly }
                        else { f.activator.applicationActivationSucceeds = false }
                    }
                    try await f.startPrevious(fast: path == 0)
                    f.store.requestCycle(forward: true)
                    if !held { f.store.commitSelection() }
                    try await wait { held || !success ? f.store.isVisible : f.calls >= 2 }
                    if held || !success {
                        try expectEqual(f.store.selectedID, success ? 1 : 2,
                            "completed focus/MRU must anchor the next default, never an assumed partial target")
                        try expectEqual(f.calls, 1, "one old operation, no released recovery auto-commit")
                        if !success && held {
                            f.activator.applicationActivationSucceeds = true
                            f.activator.activationResultOverride = nil
                            f.store.commitSelection()
                            try await wait { f.calls == 2 }
                        }
                    }
                }
            }
        }
    }
    @MainActor static func expiry() async throws {
        let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
        settings.doubleModifierSwitchEnabled = true
        defer { settings.doubleModifierSwitchEnabled = old }
        for previous in [false, true] {
            for held in [false, true] {
                let f = Fixture(); defer { f.finish() }
                f.flags = held ? settings.modifier.cgFlag : []
                if previous { try await f.startPrevious(fast: true) } else { try await f.startSelection() }
                f.store.requestCycle(forward: true, eventTimestamp: f.clock - 200_000_000)
                f.advance(201)
                try await wait { f.calls == 1 }
                await runPendingMainTasks()
                try expect(!f.store.isSwitching && !f.store.isVisible)
                try expectEqual(f.calls, 1)
            }
        }
    }
    @MainActor static func cancelledLane() async throws {
        for held in [false, true] {
            let f = Fixture(); defer { f.finish() }
            f.flags = held ? SwitchBladeSettings.shared.modifier.cgFlag : []
            try await f.startSelection()
            f.store.cancel() // drops task handle while native activation still owns the lane
            f.store.requestCycle(forward: true)
            if !held { f.store.commitSelection() }
            try expect(!f.store.isVisible)
            try await wait { held ? f.store.isVisible : f.calls == 2 }
            if held { try expectEqual(f.store.selectedID, 1) }
            else { try expectEqual(f.activator.activatedItems.last?.id, 1) }
        }
    }
    @MainActor static func navigation() async throws {
        for (directions, expected) in [([true,true], UInt32(3)), ([false], 3), ([true,false], 2)] {
            let f = Fixture(); defer { f.finish() }
            try await f.startSelection()
            for direction in directions { f.store.requestCycle(forward: direction) }
            f.store.commitSelection() // stored release says up, but live modifier was re-pressed
            f.flags = SwitchBladeSettings.shared.modifier.cgFlag
            try await wait { f.store.isVisible }
            try expectEqual(f.store.selectedID, expected)
            try expectEqual(f.calls, 1)
        }
        // A missing release notification must not leave the panel open when live flags say up.
        let f = Fixture(); defer { f.finish() }
        try await f.startSelection(); f.store.requestCycle(forward: true)
        try await wait { f.calls == 2 }
        try expectEqual(f.activator.activatedItems.last?.id, 1)
    }
    @MainActor static func cancellation() async throws {
        for duringOpening in [false, true] {
          for reason in 0..<4 {
            let f = Fixture(); defer { f.finish() }
            if duringOpening {
                f.catalog.visibleItems.append(makeItem(id: 4, pid: 200))
                f.activator.activationResultOverride = .applicationOnly
            }
            try await f.startSelection()
            if duringOpening { f.catalog.visibleSnapshotDelayNanoseconds = 150_000_000 }
            f.store.requestCycle(forward: true)
            if duringOpening { try await wait { f.store.isSwitching } }
            switch reason {
            case 0: f.store.cancel()
            case 1: await f.store.handleActiveSpaceChange()
            case 2:
                let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.previewMode
                settings.previewMode = old == .iconsOnly ? .livePreviews : .iconsOnly
                settings.previewMode = old
            default: f.store.handleAppActivation(pid: 300)
            }
            try await wait { f.calls == 1 }; await runPendingMainTasks()
            try expectEqual(f.calls, 1); try expect(!f.store.isVisible && !f.store.isSwitching)
          }
        }
    }
    @MainActor static func expiryDuringOpen() async throws {
        let f = Fixture(); defer { f.finish() }
        f.catalog.visibleItems.append(makeItem(id: 4, pid: 200)) // app-only cannot pin a B sibling
        f.activator.activationResultOverride = .applicationOnly
        try await f.startSelection()
        f.catalog.visibleSnapshotDelayNanoseconds = 150_000_000
        f.store.requestCycle(forward: true); f.store.commitSelection()
        try await wait { f.store.isSwitching }
        f.advance(401)
        try await wait { !f.store.isSwitching }
        try expectEqual(f.calls, 1, "expired quick release must not activate after a slow snapshot")
    }
}
