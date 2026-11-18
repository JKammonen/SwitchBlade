import AppKit
@testable import SwitchBladeCore

enum InteractionIntentTests {
 static let all: [(String, @MainActor () async throws -> Void)] = [
  ("InteractionIntent/cancelledBusyActionInvalidatesNewSameAppMembership", changedMembership),
  ("InteractionIntent/newCmdTabSupersedesPreviousSnapshotEvenSameApp", newerCycle),
  ("InteractionIntent/ordinaryTypingAndNonFocusKeysKeepPendingSwitch", { try await siblingChoice(sameApp:false,pointer:false,ordinaryTyping:true) }),
  ("InteractionIntent/explicitFocusChordClassification", focusChords),
  ("InteractionIntent/controlF4SupersedesLookup", { try await siblingChoice(sameApp:false,keyboard:true,keyCode:118,keyFlags:.maskControl) }),
  ("InteractionIntent/cmdBacktickSiblingChoiceSupersedesLookup", { try await siblingChoice(sameApp:false,keyboard:true) }),
  ("InteractionIntent/hardwareTimestampCmdTabStillDefers", { try await siblingChoice(sameApp:false,pointer:false,consumedCycle:true,hardwareTimestamp:true) }),
  ("InteractionIntent/consumedCmdTabStillDefers", { try await siblingChoice(sameApp:false,pointer:false,consumedCycle:true) }),
  ("InteractionIntent/visiblePanelNavigationPassesAndStaysOpen", panelNavigation),
  ("PointerIntent/targetAppSiblingClickSupersedesLookup", { try await siblingChoice(sameApp:false) }),
  ("PointerIntent/sameAppSiblingClickSupersedesLookup", { try await siblingChoice(sameApp:true) }),
  ("PointerIntent/rightClickSupersedesLookup", { try await siblingChoice(sameApp:false,button:.rightMouseDown) }),
  ("PointerIntent/otherClickSupersedesLookup", { try await siblingChoice(sameApp:false,button:.otherMouseDown) }),
  ("PointerIntent/noPointerRetainsOriginalIntent", { try await siblingChoice(sameApp:false,pointer:false) }),
  ("PointerIntent/panelClickBeforeCommitDoesNotCancelNewIntent", { try await siblingChoice(sameApp:false,pointer:false,clickBeforeCommit:true) }),
  ("PointerIntent/previousSnapshotPointerCancelsActivation", { try await previousSnapshot(external:false) }),
  ("PointerIntent/previousSnapshotExternalActivationCancels", { try await previousSnapshot(external:true) }),
  ("PointerIntent/hiddenQuickReleaseClickCancelsOpening", hiddenOpening),
  ("PointerIntent/modifierMouseKeepsExistingShortcutSemantics", modifierShortcut),
  ("PointerIntent/clickDiscardsDeferredCycle", { try await siblingChoice(sameApp:false,queue:true) })
 ]
 @MainActor static func changedMembership() async throws {
  let catalog = MockWindowCatalog(), activator = MockWindowActivator()
  let tracker = MRUTracker(userDefaults:makeIsolatedUserDefaults())
  let main = makeItem(id:1,pid:100,isFrontmostApp:true)
  tracker.trackFocusedWindowActivation(main)
  catalog.visibleItems = [main] + (2...16).map { makeItem(id:UInt32($0),pid:pid_t($0*100)) }
  let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),mruTracker:tracker,activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { store.cancel() }
  await store.warmPreviewCache(context:"main-only-before-action")
  await openSwitcher(store)
  activator.actionDelayNanoseconds = 80_000_000
  store.commitSelection()
  try await wait { activator.startedActionCount > 0 }
  let booking = makeItem(id:17,pid:100,isFrontmostApp:true)
  catalog.visibleItems.insert(booking,at:0)
  catalog.snapshotFocusedWindow = booking
  catalog.focusedWindowItemsByPID[100] = booking
  store.handleUserInteraction()
  try await wait { store.isIdleForRelaunch }
  activator.actionDelayNanoseconds = 0
  store.requestCycle(forward:true);store.commitSelection()
  try await wait { activator.activatedItems.count == 2 && store.isIdleForRelaunch }
  try expectEqual(activator.activatedItems.last?.id,1,"post-interaction fresh membership must place new A17 first and previous A1 second, never stale B2")
 }
 private final class HeldCatalog: WindowSnapshotProviding, @unchecked Sendable {
  let base = MockWindowCatalog(), started = LockedValue(false), first = LockedValue(true)
  let gate = DispatchSemaphore(value:0)
  func snapshotVisibleOnly() -> [WindowItem] {
   let hold = first.withValue { value in let hold = value;value=false;return hold }
   if hold {
    let snapshot = base.visibleItems;started.value=true
    _ = gate.wait(timeout:.now()+3)
    return snapshot
   }
   return base.snapshotVisibleOnly()
  }
  func snapshotMinimized(cancellation:CooperativeCancellationToken) async -> MinimizedWindowSnapshot { await base.snapshotMinimized(cancellation:cancellation) }
  func focusedWindowItem(pid:pid_t) -> WindowItem? { base.focusedWindowItem(pid:pid) }
  func capturePreviews(for ids:[CGWindowID],maxCount:Int?,maxConcurrentCaptures:Int,allowedOffscreenWindowIDs:Set<CGWindowID>) async -> [CGWindowID:NSImage] { [:] }
  func refreshContentCache() async { }
  func refreshContentCacheIfStale() async { }
  func invalidateContentCache(reason:String) async { }
 }
 @MainActor static func newerCycle() async throws {
  let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
  settings.doubleModifierSwitchEnabled = true
  defer { settings.doubleModifierSwitchEnabled = old }
  let catalog = HeldCatalog(), activator = MockWindowActivator()
  catalog.base.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:100,isFrontmostApp:true)]
  let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { catalog.gate.signal();store.cancel() }
  store.switchToPreviousApplication()
  try await wait { catalog.started.value }
  store.requestCycle(forward:true);store.commitSelection()
  try await wait { activator.activatedItems.count == 1 && !store.isSwitching }
  catalog.gate.signal()
  try await wait { store.isIdleForRelaunch }
  try expectEqual(activator.activatedItems.map(\.id),[2],"older previous snapshot must not activate after newer same-app CmdTab finishes")
 }
 @MainActor static func focusChords() throws {
  for reverse in [false,true] {
   let shift: CGEventFlags = reverse ? .maskShift : []
   for code: Int64 in [48,50] {
    try expect(HotkeyMonitor.isFocusChangingShortcut(keyCode:code,flags:[.maskCommand,shift]))
   }
   try expect(HotkeyMonitor.isFocusChangingShortcut(keyCode:118,flags:[.maskControl,shift]))
  }
  try expect(!HotkeyMonitor.isFocusChangingShortcut(keyCode:50,flags:[.maskCommand,.maskAlternate]))
  try expect(!HotkeyMonitor.isFocusChangingShortcut(keyCode:124,flags:[.maskControl,.maskAlternate]),"VoiceOver chords pass through without inferring focus intent")
 }
 @MainActor static func panelNavigation() async throws {
  let catalog = MockWindowCatalog(), activator = MockWindowActivator()
  catalog.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:200),makeItem(id:3,pid:300)]
  let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { store.cancel() }
  let monitor = HotkeyMonitor();monitor.onUserInteraction = { store.handleUserInteraction() }
  await openSwitcher(store)
  store.updatePanelColumnCount(3)
  let original = store.selectedID
  let raw = CGEvent(keyboardEventSource:nil,virtualKey:124,keyDown:true)!
  try expect(monitor.handleEventTapForTesting(type:.keyDown,event:raw)?.takeUnretainedValue() === raw)
  let local = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
  try expect(store.handleKeyDown(local))
  try expect(store.isVisible && store.selectedID != original,"ordinary visible navigation remains local and open")
  raw.flags = [.maskControl,.maskAlternate]
  try expect(monitor.handleEventTapForTesting(type:.keyDown,event:raw)?.takeUnretainedValue() === raw,"VoiceOver chord must pass through")
  try expect(store.isVisible)
 }
 @MainActor static func previousSnapshot(external: Bool) async throws {
  let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
  settings.doubleModifierSwitchEnabled = true
  defer { settings.doubleModifierSwitchEnabled = old }
  let catalog = MockWindowCatalog(), activator = MockWindowActivator()
  catalog.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:200),makeItem(id:3,pid:300)]
  catalog.visibleSnapshotDelayNanoseconds = 150_000_000
  let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { store.cancel() }
  store.switchToPreviousApplication()
  try await wait { catalog.visibleSnapshotCount > 0 }
  if external { store.handleAppActivation(pid:300) } else { store.handleUserInteraction() }
  try await wait { store.isIdleForRelaunch }
  try expect(activator.activatedItems.isEmpty && activator.activatedApplicationPIDs.isEmpty,"superseded previous-switch snapshot must never start native activation")
 }
 @MainActor static func hiddenOpening() async throws {
  let catalog = MockWindowCatalog(), activator = MockWindowActivator()
  catalog.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:200)]
  catalog.visibleSnapshotDelayNanoseconds = 150_000_000
  let store = SwitcherStore(catalog:catalog,activator:activator,permissionService:MockPermissionService(),userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { store.cancel() }
  let monitor = HotkeyMonitor(); monitor.onUserInteraction = { store.handleUserInteraction() }
  store.requestCycle(forward:true);store.commitSelection()
  try expect(store.isSwitching && !store.isVisible)
  let event = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
  try expect(monitor.handleEventTapForTesting(type:.leftMouseDown,event:event)?.takeUnretainedValue() === event)
  try expect(!store.isSwitching,"continued click cancels hidden commitWhenReady opening immediately")
  // Await real mock snapshot completion through the catalog warmup, not a sleep.
  await store.warmPreviewCache(context:"after-pointer-cancellation")
  await runPendingMainTasks()
  try expect(activator.activatedItems.isEmpty,"cancelled hidden release must not activate later")
  try expect(!store.isVisible && !store.isSwitching)
 }
 @MainActor static func modifierShortcut() throws {
  let settings = SwitchBladeSettings.shared, old = SwitchBladeSettings.shared.doubleModifierSwitchEnabled
  settings.doubleModifierSwitchEnabled = true
  defer { settings.doubleModifierSwitchEnabled = old }
  let monitor = HotkeyMonitor()
  var ordinaryPointers = 0, shortcuts = 0
  monitor.onUserInteraction = { ordinaryPointers += 1 }
  monitor.onModifierMouseSwitch = { shortcuts += 1 }
  let event = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
  event.flags = settings.doubleModifier.cgFlag
  try expect(monitor.handleEventTapForTesting(type:.leftMouseDown,event:event) == nil,"existing modifier mouse gesture stays consumed")
  try expectEqual(shortcuts,1)
  try expectEqual(ordinaryPointers,0,"consumed switch gesture must not invalidate the existing busy action")
 }
 @MainActor final class Observer: WindowFocusObserving {
  var onFocus: ((WindowFocusCapture) -> Void)?
  var onMembershipInvalidated: ((pid_t) -> Void)?
  var shouldCaptureFocus: (() -> Bool)?
  let active: LockedValue<pid_t>
  let chosen: LockedValue<CGWindowID>
  let reads = LockedValue(0)
  lazy var driver = WindowFocusReadRecovery(frontmostPID: { self.active.value }, isAllowed: { self.shouldCaptureFocus?() ?? true }, read: { request in
   self.reads.withValue { $0 += 1 }
   return .captured(WindowFocusCapture(pid:request.pid, resolve: { nil }))
  }, invalidateMembership: { self.onMembershipInvalidated?($0) }, deliver: { self.onFocus?($0) })
  init(active: LockedValue<pid_t>, chosen: LockedValue<CGWindowID>) { self.active=active;self.chosen=chosen }
  func observe(pid:pid_t?) { }
  func cancelPendingFocusReads() { driver.cancel(reason:"action") }
  func emit(pid:pid_t) { driver.capture(pid:pid,trigger:"focused-window-changed") }
 }
 @MainActor static func wait(_ predicate: () -> Bool) async throws {
  for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds:2_000_000) }
  try expect(false,"audit timed out")
 }
 @MainActor static func siblingChoice(sameApp: Bool, pointer: Bool = true, button: CGEventType = .leftMouseDown, clickBeforeCommit: Bool = false, queue: Bool = false, keyboard: Bool = false, consumedCycle: Bool = false, hardwareTimestamp: Bool = false, ordinaryTyping: Bool = false, keyCode: CGKeyCode = 50, keyFlags: CGEventFlags = .maskCommand) async throws {
  let targetPID: pid_t = sameApp ? 100 : 200
  let active = LockedValue<pid_t>(100), chosen = LockedValue<CGWindowID>(1)
  let entered = LockedValue(false), gate = DispatchSemaphore(value:0)
  let permissionAfterUserChoice = LockedValue(false), applicationCalls = LockedValue<[String]>([])
  let observer = Observer(active:active,chosen:chosen), catalog = MockWindowCatalog()
  catalog.visibleItems = [makeItem(id:1,pid:100,isFrontmostApp:true),makeItem(id:2,pid:targetPID,isFrontmostApp:sameApp),makeItem(id:3,pid:targetPID,isFrontmostApp:sameApp)]
  let native = WindowActivator(activateApplicationOverride: { pid in
   applicationCalls.withValue { $0.append("activate \(pid), user-focused-window=\(chosen.value)") }
   return true
  },isApplicationActiveOverride: { $0 == active.value },matchCandidatesOverride: { item in
   let first = entered.withValue { value in let first = !value; value = true; return first }
   if first { precondition(gate.wait(timeout:.now()+3) == .success) }
   permissionAfterUserChoice.value=WindowActionIntent.permitsSideEffect
   return ([.init(title:nil,frame:nil,isMain:false,isFocused:false,windowID:item.id)],1)
  },focusSampleOverride: { _,_ in .init(targetApplicationActive:true,focusedWindowError:0,focusedWindowIsMatchedElement:nil) }, focusObservationBudgetSeconds:0)
  let store = SwitcherStore(catalog:catalog,activator:native,permissionService:MockPermissionService(),windowFocusObserver:observer,userDefaults:makeIsolatedUserDefaults(),activationWarmupWindow:-1,workspaceNotificationCenter:NotificationCenter(),initialFrontmostAppPID:100,switchBladePID:999)
  defer { gate.signal();store.cancel() }
  let monitor = HotkeyMonitor()
  monitor.onUserInteraction = { store.handleUserInteraction() }
  monitor.onHotkey = { direction, timestamp in store.requestCycle(forward:direction == .forward,eventTimestamp:timestamp) }
  store.deferredModifierFlags = { [] }
  func deliverPointer() throws {
   let event = keyboard ? CGEvent(keyboardEventSource:nil,virtualKey:keyCode,keyDown:true)! : CGEvent(mouseEventSource:nil,mouseType:button,mouseCursorPosition:.zero,mouseButton:button == .rightMouseDown ? .right : (button == .otherMouseDown ? .center : .left))!
   if keyboard { event.flags = keyFlags }
   let returned = monitor.handleEventTapForTesting(type:keyboard ? .keyDown : button,event:event)
   try expect(returned?.takeUnretainedValue() === event,"pointer event must pass through unchanged")
  }
  await openSwitcher(store)
  if clickBeforeCommit { try deliverPointer() }
  store.selectedID=2
  store.commitSelection()
  try await wait { entered.value }
  if queue { store.requestCycle(forward:true);store.commitSelection() }
  if ordinaryTyping {
   for (code, flags): (CGKeyCode, CGEventFlags) in [(0,[]),(36,[]),(53,[]),(124,[]),(37,.maskCommand)] {
    let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!;event.flags=flags
    try expect(monitor.handleEventTapForTesting(type:.keyDown,event:event)?.takeUnretainedValue() === event,"ordinary typing and nonfocus shortcuts pass through")
   }
  } else {
   active.value=targetPID;chosen.value=3
   if !sameApp { store.handleAppActivation(pid:targetPID) }
   observer.emit(pid:targetPID)
  }
  if pointer { try deliverPointer() }
  if consumedCycle {
   let event = CGEvent(keyboardEventSource:nil,virtualKey:48,keyDown:true)!;event.flags = .maskCommand
   event.timestamp = hardwareTimestamp ? mach_absolute_time() : DispatchTime.now().uptimeNanoseconds
   try expect(monitor.handleEventTapForTesting(type:.keyDown,event:event) == nil,"configured CmdTab stays consumed")
   store.commitSelection()
  }
  gate.signal()
  try await wait { store.isIdleForRelaunch }
  try expectEqual(permissionAfterUserChoice.value,!pointer,"a later pointer edge must invalidate future native mutations")
  try expectEqual(observer.reads.value,0,"in-flight action suppresses observation of user's sibling change")
  try expectEqual(applicationCalls.value.count,consumedCycle ? 2 : ((pointer || sameApp) ? 0 : 1))
  try expect(!store.isVisible,"continued pointer interaction must not resurrect recovery or deferred switching")
 }
}
