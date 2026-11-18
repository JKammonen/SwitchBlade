import AppKit
@testable import SwitchBladeCore

enum FocusIntentIntegrationTests {
 static let all: [(String, @MainActor () async throws -> Void)] = [
 ("FocusIntent/externalActivationSupersedesDetachedTargeting", { try await focusSteal(cancel:false) }),
 ("FocusIntent/cancelSupersedesDetachedTargeting", { try await focusSteal(cancel:true) }),
 ("FocusIntent/cancelAloneStopsTargeting", { try await focusSteal(cancel:true,supersede:false) }),
 ("FocusIntent/modifierWindowSwitchHonorsCancel", { try await focusSteal(cancel:true,supersede:false,previous:true) }),
 ("FocusIntent/cancelledModifierLaneNewInputCommitsNormally", cancelledModifierInput),
 ("FocusIntent/currentActionStillActivates", { try await focusSteal(cancel:false,supersede:false) }),
 ("FocusIntent/modifierWindowSwitchHonorsExternalActivation", { try await focusSteal(cancel:false,previous:true) }),
 ("FocusIntent/failedFocusReadQuickReleaseWaitsFreshMembership", { try await membership(failedRead:true,waitForHealing:false) }),
 ("FocusIntent/healedMembershipRetainsPreviousWindow", { try await membership(failedRead:true,waitForHealing:true) }),
 ("FocusIntent/successfulFocusCaptureRetainsPreviousWindow", { try await membership(failedRead:false,waitForHealing:false) })
 ]

@MainActor static func until(_ condition: () -> Bool) async throws {
 for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
 try expect(false,"probe timed out")
}

@MainActor static func focusSteal(cancel: Bool, supersede: Bool = true, previous: Bool = false) async throws {
 let settings = SwitchBladeSettings.shared, oldDouble = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
 settings.doubleModifierSwitchEnabled = true
 defer { settings.doubleModifierSwitchEnabled = oldDouble }
 let targetPID: pid_t = previous ? 100 : 200
 let frontmost = LockedValue<pid_t>(100)
 let entered = LockedValue(false)
 let gate = DispatchSemaphore(value: 0)
 let activationCalls = LockedValue<[String]>([])
 let catalog = MockWindowCatalog()
 catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true),makeItem(id: 2,pid: targetPID),makeItem(id: 3,pid: 300)]
 let native = WindowActivator(
  activateApplicationOverride: { pid in
   activationCalls.withValue { $0.append("activate \(pid) after frontmost \(frontmost.value)") }
   frontmost.value = pid
   return true
  },
  isApplicationActiveOverride: { $0 == frontmost.value },
  matchCandidatesOverride: { item in
   entered.value = true
   precondition(gate.wait(timeout: .now() + 3) == .success)
   return ([.init(title:nil, frame:nil, isMain:false, isFocused:false, windowID:item.id)],1)
  },
  focusSampleOverride: { _,_ in .init(targetApplicationActive:frontmost.value == targetPID,focusedWindowError:0,focusedWindowIsMatchedElement:true) }
 )
 let store = SwitcherStore(catalog:catalog,activator:native,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
 await openSwitcher(store)
 try expectEqual(store.selectedID,2)
 if previous { store.cancel(); store.switchToPreviousApplication() } else { store.commitSelection() }
 try await until { entered.value }
 // This is the production NSWorkspace handler, on MainActor, while the
 // Coordinator's detached targeting operation remains blocked.
 if supersede { frontmost.value = 300; store.handleAppActivation(pid:300) }
 if cancel { store.cancel() }
 gate.signal()
 try await until { store.isIdleForRelaunch }
 print("FULL-CHAIN cancel=\(cancel) calls=\(activationCalls.value) final-frontmost=\(frontmost.value) panel-visible=\(store.isVisible)")
 try expectEqual(frontmost.value,supersede ? 300 : (cancel ? 100 : targetPID))
 try expectEqual(activationCalls.value.count,(supersede || cancel) ? 0 : 1,"only a current action may activate")
 try expect(!store.isVisible,"superseded action must not show failure recovery")
 store.cancel()
}

@MainActor static func cancelledModifierInput() async throws {
 let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
 settings.doubleModifierSwitchEnabled = true
 defer { settings.doubleModifierSwitchEnabled = old }
 let catalog = MockWindowCatalog(), activator = MockWindowActivator()
 catalog.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:100),makeItem(id:3,pid:300)]
 let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
 defer { store.cancel() }
 store.deferredModifierFlags = { [] }
 activator.actionDelayNanoseconds = 80_000_000
 store.switchToPreviousApplication()
 try await until { activator.startedActionCount > 0 }
 store.cancel()
 store.requestCycle(forward:true)
 store.commitSelection()
 try await until { activator.activatedItems.count == 2 && store.isIdleForRelaunch }
 try expect(!store.isVisible,"fresh input after cancel must commit normally, not stay in recovery")
}

@MainActor final class AuditObserver: WindowFocusObserving {
 var onFocus: ((WindowFocusCapture) -> Void)?
 var onMembershipInvalidated: ((pid_t) -> Void)?
 var shouldCaptureFocus: (() -> Bool)?
 var reads = 0
 lazy var driver = WindowFocusReadRecovery(frontmostPID: { 100 },isAllowed: { self.shouldCaptureFocus?() ?? true }, read: { _ in
  self.reads += 1; return .failure(.cannotComplete,"ax-error")
 }, invalidateMembership: { self.onMembershipInvalidated?($0) }, deliver: { self.onFocus?($0) })
 func observe(pid:pid_t?) { }
 func cancelPendingFocusReads() { driver.cancel(reason:"open-or-action") }
 func emit() { driver.capture(pid:100,trigger:"window-created") }
}
@MainActor static func membership(failedRead: Bool, waitForHealing: Bool) async throws {
 let observer = AuditObserver(), catalog = MockWindowCatalog(), activator = MockWindowActivator()
 let ud = makeIsolatedUserDefaults(), tracker = MRUTracker(userDefaults:makeIsolatedUserDefaults())
 let main = makeItem(id:1,pid:100,isFrontmostApp:true)
 tracker.trackFocusedWindowActivation(main)
 let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),windowFocusObserver:observer,userDefaults:ud,mruTracker:tracker,activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
 catalog.visibleItems = [main] + (2...16).map { makeItem(id:UInt32($0),pid:pid_t($0*100)) }
 await store.warmPreviewCache(context:"audit-seed")
 let booking = makeItem(id:17,pid:100,isFrontmostApp:true)
 catalog.visibleItems.insert(booking,at:0)
 catalog.snapshotFocusedWindow = booking
 catalog.focusedWindowItemsByPID[100] = booking
 catalog.visibleSnapshotDelayNanoseconds = 200_000_000
 if failedRead { observer.emit() }
 else { observer.onFocus?(WindowFocusCapture(pid:100, resolve:{ booking })) }
 store.requestCycle(forward:true)
 if waitForHealing { try await until { store.items.contains(where: {$0.id == 17}) } }
 let visibleAtRelease = store.isVisible
 store.commitSelection()
 try await until { !activator.activatedItems.isEmpty }
 print("MEMBERSHIP failed-read=\(failedRead) wait-heal=\(waitForHealing) visible-at-release=\(visibleAtRelease) chosen=\(activator.activatedItems.map(\.id)) reads=\(observer.reads)")
 try expectEqual(activator.activatedItems.first?.id,1,"quick release must select previous concrete main window")
 store.cancel()
}
}
