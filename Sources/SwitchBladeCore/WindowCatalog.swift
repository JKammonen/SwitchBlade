import AppKit
import ApplicationServices
import CoreGraphics
import os.log
@preconcurrency import ScreenCaptureKit

// Cache for SCShareableContent. Three refresh paths:
//   1. Launch warmup once Screen Recording has been granted.
//   2. End-of-cycle refresh via `refreshContentCache()` so the next Cmd+Tab
//      starts fresh.
//   3. Hot-path refresh via `refreshContentCacheIfStale()` inside
//      `capturePreviews` when the cache is older than `staleThreshold`.
// Never polled — ScreenCaptureKit can surface a macOS permission dialog when
// touched repeatedly in an unsettled TCC state.
actor SCContentCache {
    private(set) var content: SCShareableContent?
    private(set) var lastRefreshFailedAt: Date?
    private(set) var lastSuccessfulRefresh: Date?

    /// Stale cache leads to slow first captures after idle: the cached SCWindow
    /// refs lose their warm capture-pipeline link, and SCScreenshotManager has
    /// to re-resolve each one (300 ms timeout + retry per window). Above this
    /// age `capturePreviews` refreshes inline so the first batch hits a warm
    /// pipeline. SwitcherStore also kicks opportunistic refreshes on every
    /// NSWorkspace app activation; the hot-path refresh is the safety net when
    /// the user idles without switching apps.
    static let staleThreshold: TimeInterval = 5

    func refreshIfAllowed(successContext: String? = nil) async {
        // Guard: SCKit can trigger an OS permission dialog without Screen Recording access.
        guard CGPreflightScreenCaptureAccess() else {
            Logger.capture.notice("SCShareableContent refresh skipped — no Screen Recording permission")
            return
        }
        let start = Date()
        do {
            content = try await SCShareableContent.current
            lastRefreshFailedAt = nil
            lastSuccessfulRefresh = Date()
            let ms = Date().timeIntervalSince(start) * 1000
            if let successContext {
                Logger.capture.info("SCShareableContent refresh ok (\(successContext, privacy: .public)) in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            } else if PerformanceLoggingState.mode == .debug {
                Logger.capture.info("SCShareableContent refresh ok in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            }
        } catch {
            lastRefreshFailedAt = Date()
            Logger.capture.error("SCShareableContent refresh failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func shouldRetryAfterFailure() -> Bool {
        guard let lastRefreshFailedAt else { return true }
        return Date().timeIntervalSince(lastRefreshFailedAt) > 60
    }

    /// True when the cache exists but is older than `staleThreshold`. Used on
    /// the Cmd+Tab hot path to decide whether to await a fresh fetch before
    /// kicking off captures.
    func isStale() -> Bool {
        guard let lastSuccessfulRefresh else { return true }
        return Date().timeIntervalSince(lastSuccessfulRefresh) > Self.staleThreshold
    }

    func refreshIfStale() async {
        if content == nil || isStale() {
            guard shouldRetryAfterFailure() else { return }
            await refreshIfAllowed()
        }
    }

    func invalidate(reason: String) {
        content = nil
        lastRefreshFailedAt = nil
        lastSuccessfulRefresh = nil
        Logger.capture.notice("SCShareableContent cache invalidated: \(reason, privacy: .public)")
    }

    static func capture(window: SCWindow, maxDim: Int) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let fullW = max(1, Int(window.frame.width * scale))
        let fullH = max(1, Int(window.frame.height * scale))
        let ratio = min(1.0, CGFloat(maxDim) / CGFloat(max(fullW, fullH)))
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.width  = max(1, Int(CGFloat(fullW) * ratio))
        cfg.height = max(1, Int(CGFloat(fullH) * ratio))
        let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return NSImage(cgImage: cgImg, size: .zero)
    }

    enum CaptureAttemptResult: @unchecked Sendable {
        case success(NSImage)
        case failed
        case timedOut
        case resourceLimited
    }

    enum SoftTimeoutResult<Value: Sendable>: Sendable {
        case completed(Value)
        case timedOut
    }

    enum PermitBoundOperationResult<Value: Sendable>: Sendable {
        case completed(Value)
        case timedOut
        case resourceLimited
    }

    static func awaitTaskWithSoftTimeout<Value: Sendable>(
        _ task: Task<Value, Never>,
        timeoutMs: Int
    ) async -> SoftTimeoutResult<Value> {
        await withCheckedContinuation { continuation in
            let box = OneShotContinuation(continuation)
            let observedTask = task

            Task.detached(priority: .userInitiated) {
                box.resume(returning: .completed(await observedTask.value))
            }

            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                observedTask.cancel()
                box.resume(returning: .timedOut)
            }
        }
    }

    /// Starts work only when a global capture permit is available. The caller
    /// may stop waiting at the UX timeout, but the permit is released by the
    /// underlying operation itself, never by the timeout path. A blocked Apple
    /// API therefore consumes one bounded slot instead of allowing new orphaned
    /// work to accumulate across retries and switcher opens.
    static func runPermitBoundOperation<Value: Sendable>(
        permitPool: CapturePermitPool,
        timeoutMs: Int,
        operation: @escaping @Sendable () async -> Value
    ) async -> PermitBoundOperationResult<Value> {
        guard permitPool.tryAcquire() else {
            return .resourceLimited
        }

        let operationTask = Task.detached(priority: .userInitiated) {
            defer { permitPool.release() }
            return await operation()
        }
        switch await awaitTaskWithSoftTimeout(operationTask, timeoutMs: timeoutMs) {
        case .completed(let value):
            return .completed(value)
        case .timedOut:
            return .timedOut
        }
    }

    /// Captures the window or stops waiting after `timeoutMs`.
    ///
    /// Important: this is a UX timeout, not a hard resource kill. We cancel our
    /// Swift Task and return `.timedOut` to the caller promptly, but if
    /// ScreenCaptureKit is blocked inside `captureImage`, that framework work
    /// may continue until Apple's API returns or notices cancellation.
    static func captureWithSoftTimeout(
        window: SCWindow,
        maxDim: Int,
        timeoutMs: Int,
        permitPool: CapturePermitPool
    ) async -> CaptureAttemptResult {
        nonisolated(unsafe) let capturedWindow = window
        switch await runPermitBoundOperation(
            permitPool: permitPool,
            timeoutMs: timeoutMs,
            operation: { () async -> CaptureAttemptResult in
                do {
                    return .success(try await SCContentCache.capture(window: capturedWindow, maxDim: maxDim))
                } catch {
                    return .failed
                }
            }
        ) {
        case .completed(let result):
            return result
        case .timedOut:
            return .timedOut
        case .resourceLimited:
            return .resourceLimited
        }
    }
}

final class CapturePermitPool: @unchecked Sendable {
    private struct State {
        var availablePermits: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: LockedValue<State>

    init(limit: Int) {
        self.state = LockedValue(State(availablePermits: max(1, limit)))
    }

    func acquire() async {
        let acquiredImmediately = state.withValue { state in
            if state.availablePermits > 0 {
                state.availablePermits -= 1
                return true
            }
            return false
        }
        if acquiredImmediately { return }
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = state.withValue { state in
                if state.availablePermits > 0 {
                    state.availablePermits -= 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func tryAcquire() -> Bool {
        state.withValue { state in
            guard state.availablePermits > 0 else { return false }
            state.availablePermits -= 1
            return true
        }
    }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = state.withValue { state in
            if let waiter = state.waiters.first {
                state.waiters.removeFirst()
                return waiter
            }
            state.availablePermits += 1
            return nil
        }
        if let waiter {
            waiter.resume()
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

actor InFlightTaskCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let key: Key
        let task: Task<Value, Never>
    }

    private var inFlight: Entry?

    func value(
        for key: Key,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        while let active = inFlight {
            let value = await active.task.value
            if inFlight?.id == active.id {
                inFlight = nil
            }
            guard !Task.isCancelled else { return nil }
            if active.key == key {
                return value
            }
        }

        guard !Task.isCancelled else { return nil }
        let entry = Entry(
            id: UUID(),
            key: key,
            task: Task.detached(priority: priority, operation: operation)
        )
        inFlight = entry
        let value = await entry.task.value
        if inFlight?.id == entry.id {
            inFlight = nil
        }
        return Task.isCancelled ? nil : value
    }
}

struct AXScanBudget: Sendable {
    let maximumApplications: Int
    let maximumWindows: Int
    let maximumElapsedSeconds: TimeInterval
    let startedAt: TimeInterval
    private(set) var scannedApplications = 0
    private(set) var scannedWindows = 0
    private(set) var isExhausted = false

    mutating func beginApplication(now: TimeInterval) -> Bool {
        guard !isExhausted,
              scannedApplications < maximumApplications,
              now - startedAt < maximumElapsedSeconds else {
            isExhausted = true
            return false
        }
        scannedApplications += 1
        return true
    }

    mutating func beginWindow(now: TimeInterval) -> Bool {
        guard !isExhausted,
              scannedWindows < maximumWindows,
              now - startedAt < maximumElapsedSeconds else {
            isExhausted = true
            return false
        }
        scannedWindows += 1
        return true
    }
}

private struct MinimizedSnapshotContext: Hashable, Sendable {
    let requestEpoch: UInt64
    let frontmostPID: pid_t?
    let scope: SBWindowScope
    let hiddenAppTokens: Set<HiddenAppToken>
}

private struct WindowCaptureOutcome {
    let windowID: CGWindowID
    let image: NSImage?
    let firstAttempt: SCContentCache.CaptureAttemptResult
    let secondAttempt: SCContentCache.CaptureAttemptResult?
    let fallbackAttempt: WindowCatalog.FallbackAttemptResult?
}

struct PreviewCaptureWindowState: Equatable {
    let ownerPID: pid_t
    let bounds: CGRect
    let isOnScreen: Bool
    let sharingState: Int
    let alpha: Double
}

enum PreviewCaptureStabilityPolicy {
    private static let boundsTolerance: CGFloat = 1

    static func acceptedWindowIDs(
        capturedWindowIDs: Set<CGWindowID>,
        before: [CGWindowID: PreviewCaptureWindowState],
        after: [CGWindowID: PreviewCaptureWindowState],
        scope: SBWindowScope
    ) -> Set<CGWindowID> {
        Set(capturedWindowIDs.filter { windowID in
            guard let beforeState = before[windowID],
                  let afterState = after[windowID],
                  beforeState.ownerPID == afterState.ownerPID,
                  beforeState.sharingState != 0,
                  afterState.sharingState != 0,
                  beforeState.alpha > 0,
                  afterState.alpha > 0,
                  beforeState.isOnScreen == afterState.isOnScreen,
                  stableBounds(beforeState.bounds, afterState.bounds) else {
                return false
            }

            // A current-Space snapshot can only legitimately capture windows
            // that stay on-screen. A false value here means the window started
            // minimizing before capture began or completed the transition while
            // SCScreenshotManager was producing the frame.
            if scope == .currentSpace, !beforeState.isOnScreen {
                return false
            }
            return true
        })
    }

    private static func stableBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= boundsTolerance
            && abs(lhs.minY - rhs.minY) <= boundsTolerance
            && abs(lhs.width - rhs.width) <= boundsTolerance
            && abs(lhs.height - rhs.height) <= boundsTolerance
    }
}

enum WindowSharingPolicy {
    enum MinimizedTitleDecision: Equatable {
        case showTitle
        case redactTitle
        case exclude
    }

    static func canListWindow(appName: String, bundleIdentifier: String?, title: String, sharingState: Int) -> Bool {
        if isMicrosoftTeams(appName: appName, bundleIdentifier: bundleIdentifier),
           title.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("sharing indicator") {
            return false
        }

        guard sharingState == 0 else { return true }
        return isMicrosoftTeams(appName: appName, bundleIdentifier: bundleIdentifier)
    }

    static func minimizedTitleDecision(
        appName: String,
        bundleIdentifier: String?,
        title: String,
        matchingSharingStates: [Int]?
    ) -> MinimizedTitleDecision {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return .exclude }
        guard let matchingSharingStates,
              !matchingSharingStates.isEmpty else {
            return .redactTitle
        }
        return matchingSharingStates.contains {
            canListWindow(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                title: trimmedTitle,
                sharingState: $0
            )
        } ? .showTitle : .exclude
    }

    private static func isMicrosoftTeams(appName: String, bundleIdentifier: String?) -> Bool {
        let normalizedName = appName.lowercased()
        let normalizedBundle = (bundleIdentifier ?? "").lowercased()
        return normalizedName.contains("teams")
            && normalizedBundle.hasPrefix("com.microsoft.teams")
    }
}

enum WindowEligibilityPolicy {
    static func canIncludeApplication(
        processIdentifier: pid_t,
        currentProcessIdentifier: pid_t,
        activationPolicy: NSApplication.ActivationPolicy,
        isFinishedLaunching: Bool
    ) -> Bool {
        isFinishedLaunching
            && processIdentifier != currentProcessIdentifier
            && activationPolicy == .regular
    }
}

enum ApplicationFallbackPolicy {
    static func processIdentifiers(
        from applications: [RunningApplicationDescriptor],
        representedApplicationPIDs: Set<pid_t>,
        currentProcessIdentifier: pid_t,
        frontmostPID: pid_t?,
        scope: SBWindowScope
    ) -> [pid_t] {
        // Window-scoped switchers must contain concrete window rows. App-only
        // placeholders create full-size tiles that can never have a preview and
        // also pull applications from outside the selected Space into the grid.
        // Keep the fallback only for current-app mode, where it prevents an
        // otherwise empty selector when the frontmost app has no eligible row.
        guard scope == .currentApp, let frontmostPID else { return [] }

        var seen = Set<pid_t>()
        return applications.compactMap { application in
            let pid = application.processIdentifier
            guard !representedApplicationPIDs.contains(pid),
                  WindowEligibilityPolicy.canIncludeApplication(
                      processIdentifier: pid,
                      currentProcessIdentifier: currentProcessIdentifier,
                      activationPolicy: application.activationPolicy,
                      isFinishedLaunching: application.isFinishedLaunching
                  ),
                  pid == frontmostPID,
                  seen.insert(pid).inserted else {
                return nil
            }
            return pid
        }
    }
}

struct RunningApplicationDescriptor: Equatable {
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
    let isFinishedLaunching: Bool
    let bundleIdentifier: String?
    let bundleURL: URL?
}

struct RunningApplicationSnapshot {
    let applications: [NSRunningApplication]
    let applicationsByProcessIdentifier: [pid_t: NSRunningApplication]
    let discardedInvalidProcessIdentifiers: Int
    let coalescedDuplicateProcessIdentifiers: Int

    static func coalescing(_ applications: [NSRunningApplication]) -> RunningApplicationSnapshot {
        var orderedApplications: [NSRunningApplication] = []
        var orderedIndexByProcessIdentifier: [pid_t: Int] = [:]
        var applicationsByProcessIdentifier: [pid_t: NSRunningApplication] = [:]
        var discardedInvalidProcessIdentifiers = 0
        var coalescedDuplicateProcessIdentifiers = 0

        for application in applications {
            let processIdentifier = application.processIdentifier
            guard processIdentifier > 0 else {
                discardedInvalidProcessIdentifiers += 1
                continue
            }

            if let existingIndex = orderedIndexByProcessIdentifier[processIdentifier] {
                coalescedDuplicateProcessIdentifiers += 1
                let existingApplication = orderedApplications[existingIndex]
                if existingApplication.isTerminated && !application.isTerminated {
                    orderedApplications[existingIndex] = application
                    applicationsByProcessIdentifier[processIdentifier] = application
                }
                continue
            }

            orderedIndexByProcessIdentifier[processIdentifier] = orderedApplications.count
            orderedApplications.append(application)
            applicationsByProcessIdentifier[processIdentifier] = application
        }

        return RunningApplicationSnapshot(
            applications: orderedApplications,
            applicationsByProcessIdentifier: applicationsByProcessIdentifier,
            discardedInvalidProcessIdentifiers: discardedInvalidProcessIdentifiers,
            coalescedDuplicateProcessIdentifiers: coalescedDuplicateProcessIdentifiers
        )
    }
}

enum HostedWindowApplicationPolicy {
    /// Returns the regular application process that should own app-level
    /// actions for a WindowServer surface. Accessory processes are accepted
    /// only when their bundle lives inside a running regular app bundle. This
    /// is deliberately bundle-name agnostic: the process topology, not an app
    /// allowlist, establishes ownership.
    static func hostProcessIdentifier(
        for windowOwner: RunningApplicationDescriptor,
        among runningApplications: [RunningApplicationDescriptor],
        currentProcessIdentifier: pid_t
    ) -> pid_t? {
        if WindowEligibilityPolicy.canIncludeApplication(
            processIdentifier: windowOwner.processIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            activationPolicy: windowOwner.activationPolicy,
            isFinishedLaunching: windowOwner.isFinishedLaunching
        ) {
            return windowOwner.processIdentifier
        }

        guard windowOwner.processIdentifier != currentProcessIdentifier,
              windowOwner.activationPolicy == .accessory,
              windowOwner.isFinishedLaunching,
              let childBundleURL = windowOwner.bundleURL else {
            return nil
        }

        return runningApplications
            .filter { candidate in
                WindowEligibilityPolicy.canIncludeApplication(
                    processIdentifier: candidate.processIdentifier,
                    currentProcessIdentifier: currentProcessIdentifier,
                    activationPolicy: candidate.activationPolicy,
                    isFinishedLaunching: candidate.isFinishedLaunching
                ) && isNestedBundle(childBundleURL, inside: candidate.bundleURL)
            }
            .max { lhs, rhs in
                (lhs.bundleURL?.standardizedFileURL.pathComponents.count ?? 0)
                    < (rhs.bundleURL?.standardizedFileURL.pathComponents.count ?? 0)
            }?
            .processIdentifier
    }

    static func isNestedBundle(_ childBundleURL: URL, inside hostBundleURL: URL?) -> Bool {
        guard let hostBundleURL else { return false }
        let childPath = childBundleURL.standardizedFileURL.path
        let hostContentsPath = hostBundleURL.standardizedFileURL
            .appendingPathComponent("Contents", isDirectory: true)
            .path
        return childPath.hasPrefix(hostContentsPath + "/")
    }
}

enum HostedWindowSurfacePolicy {
    /// Some applications publish the same logical window through both their
    /// regular process and a nested renderer/helper process. Prefer the regular
    /// process for an exact geometric mirror; keep helper-owned surfaces whose
    /// geometry is unique, because those are the windows the host does not own.
    static func filteringMirroredHostedSurfaces(_ items: [WindowItem]) -> [WindowItem] {
        let directSurfaceKeys = Set(items.compactMap { item -> SurfaceKey? in
            guard item.windowOwnerPID == nil else { return nil }
            return SurfaceKey(hostPID: item.pid, bounds: item.bounds)
        })
        return items.filter { item in
            guard item.windowOwnerPID != nil else { return true }
            return !directSurfaceKeys.contains(SurfaceKey(hostPID: item.pid, bounds: item.bounds))
        }
    }

    private struct SurfaceKey: Hashable {
        let hostPID: pid_t
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(hostPID: pid_t, bounds: CGRect) {
            self.hostPID = hostPID
            x = Int(bounds.origin.x.rounded())
            y = Int(bounds.origin.y.rounded())
            width = Int(bounds.width.rounded())
            height = Int(bounds.height.rounded())
        }
    }
}

struct AXTopLevelWindowCandidate: Equatable, Sendable {
    let title: String?
    let frame: CGRect
    let isSwitcherWindow: Bool

    init(title: String?, frame: CGRect, isSwitcherWindow: Bool = true) {
        self.title = title
        self.frame = frame
        self.isSwitcherWindow = isSwitcherWindow
    }
}

enum AXWindowEligibilityPolicy {
    /// Single-surface apps stay on the fast CGWindowList path. Apps exposing
    /// several WindowServer surfaces get a semantic top-level-window check so
    /// named and unnamed Chromium-style child surfaces are treated alike.
    static func requiresValidation(_ items: [WindowItem]) -> Bool {
        items.count > 1
    }

    /// Keep only CGWindow rows that map one-to-one to the app's AXWindows list.
    /// Any unavailable or ambiguous AX evidence fails open so SwitchBlade does
    /// not hide legitimate windows from apps with incomplete Accessibility data.
    static func filteredItems(
        _ items: [WindowItem],
        candidates: [AXTopLevelWindowCandidate]?
    ) -> [WindowItem] {
        guard requiresValidation(items), let candidates else {
            return items
        }
        let switcherCandidates = candidates.filter(\.isSwitcherWindow)
        guard !switcherCandidates.isEmpty else { return items }

        let matches = items.map { matchIndex(for: $0, candidates: switcherCandidates) }
        let matchedIndices = matches.compactMap { $0 }
        guard !matchedIndices.isEmpty,
              Set(matchedIndices).count == matchedIndices.count else {
            return items
        }

        return zip(items, matches).compactMap { item, matchIndex in
            matchIndex == nil ? nil : item
        }
    }

    private static func matchIndex(
        for item: WindowItem,
        candidates: [AXTopLevelWindowCandidate]
    ) -> Int? {
        let frameMatches = candidates.indices.filter {
            WindowActivator.framesAreClose(candidates[$0].frame, item.bounds)
        }
        guard !frameMatches.isEmpty else { return nil }
        guard frameMatches.count > 1 else { return frameMatches[0] }

        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let titleAndFrameMatches = frameMatches.filter {
            candidates[$0].title == item.title
        }
        return titleAndFrameMatches.count == 1 ? titleAndFrameMatches[0] : nil
    }
}

struct WindowSharingStateIndex {
    private struct Key: Hashable {
        let pid: pid_t
        let title: String
    }

    struct Match: Equatable {
        let windowID: CGWindowID
        let sharingState: Int
    }

    private struct FramedMatch {
        let match: Match
        let bounds: CGRect
    }

    private let matchesByKey: [Key: [Match]]
    private let framedMatchesByPID: [pid_t: [FramedMatch]]

    private init(
        matchesByKey: [Key: [Match]],
        framedMatchesByPID: [pid_t: [FramedMatch]]
    ) {
        self.matchesByKey = matchesByKey
        self.framedMatchesByPID = framedMatchesByPID
    }

    static func fromCurrentWindowList() -> Self {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return WindowSharingStateIndex(matchesByKey: [:], framedMatchesByPID: [:])
        }
        return WindowSharingStateIndex(rawList: rawList)
    }

    init(rawList: [[String: Any]]) {
        var matchesByKey: [Key: [Match]] = [:]
        var framedMatchesByPID: [pid_t: [FramedMatch]] = [:]
        for entry in rawList {
            guard let windowID = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }
            let sharingState = entry[kCGWindowSharingState as String] as? Int ?? 0
            let match = Match(windowID: windowID, sharingState: sharingState)
            if let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDictionary) {
                framedMatchesByPID[ownerPID, default: []].append(
                    FramedMatch(match: match, bounds: bounds)
                )
            }
            let title = (entry[kCGWindowName as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            matchesByKey[Key(pid: ownerPID, title: title), default: []].append(
                match
            )
        }
        self.matchesByKey = matchesByKey
        self.framedMatchesByPID = framedMatchesByPID
    }

    func sharingStates(pid: pid_t, title: String) -> [Int]? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        return matchesByKey[Key(pid: pid, title: trimmedTitle)]?.map(\.sharingState)
    }

    /// A minimized window remains in CGWindowList with its original WindowServer
    /// ID even though current-Space snapshots stop returning it. Reuse that ID
    /// only when pid + exact raw title identify one layer-0 row. Ambiguous rows
    /// keep the synthetic ID so a preview can never be borrowed from a sibling.
    func uniqueWindow(pid: pid_t, title: String) -> Match? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let matches = matchesByKey[Key(pid: pid, title: trimmedTitle)],
              matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    /// AX and WindowServer titles can differ for the same document window.
    /// A full-frame match within the same process is a safe fallback only when
    /// exactly one layer-0 row matches; ambiguity keeps the synthetic identity.
    func uniqueWindow(pid: pid_t, bounds: CGRect) -> Match? {
        let matches = framedMatchesByPID[pid, default: []].filter {
            Self.framesAreClose($0.bounds, bounds)
        }
        return matches.count == 1 ? matches[0].match : nil
    }

    private static func framesAreClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

/// SwiftUI's `Image(nsImage:)` caches its rendered bitmap keyed by the
/// NSImage's `name`. `NSRunningApplication.icon` hands back name-less images,
/// so inside a recycling container (the switcher's `LazyVGrid`) SwiftUI can
/// serve a previously-cached bitmap for a different app when a tile view is
/// reused — e.g. Finder's tile showing Codex's icon after the minimized merge
/// mutates the displayed list. Returning a uniquely-named copy (keyed by bundle
/// id, falling back to app name) gives each app its own cache entry so reuse
/// resolves the right icon. Copy first so the shared app icon is never mutated.
enum IconNaming {
    static func named(_ icon: NSImage?, bundleIdentifier: String?, appName: String) -> NSImage? {
        guard let icon, let copy = icon.copy() as? NSImage else { return icon }
        let baseName = bundleIdentifier ?? appName
        if !copy.setName(baseName) {
            copy.setName("\(baseName)-\(UUID().uuidString)")
        }
        return copy
    }
}

final class WindowCatalog: WindowSnapshotProviding, Sendable {
    private struct WindowApplicationResolution {
        let windowApplication: NSRunningApplication
        let hostApplication: NSRunningApplication

        var windowProcessIdentifier: pid_t { windowApplication.processIdentifier }
        var hostProcessIdentifier: pid_t { hostApplication.processIdentifier }
        var windowOwnerPID: pid_t? {
            windowProcessIdentifier == hostProcessIdentifier ? nil : windowProcessIdentifier
        }
        var appName: String {
            hostApplication.localizedName
                ?? hostApplication.bundleIdentifier
                ?? windowApplication.localizedName
                ?? "Application"
        }
    }

    enum FallbackAttemptResult: @unchecked Sendable {
        case success(NSImage)
        case failed
        case timedOut
        case resourceLimited
    }

    private let excludedBundleIdentifiers: Set<String> = [
        "com.apple.PasswordsUIAgent",
        "com.apple.PasskeysUIService",
        "com.apple.Safari.PasswordBreachAgent"
    ]

    private static let processCapturePermitPool = CapturePermitPool(limit: 6)
    private static let auxiliaryWindowAXTimeoutSeconds: Float = 0.05
    private static let maximumAuxiliaryValidationApplications = 8
    private static let maximumAuxiliaryValidationWindows = 64
    private static let maximumAuxiliaryWindowsPerApplication = 32
    private static let maximumAuxiliaryValidationSeconds: TimeInterval = 0.15

    private let contentCache = SCContentCache()
    private let capturePermitPool: CapturePermitPool
    private let minimizedSnapshotCoalescer = InFlightTaskCoalescer<MinimizedSnapshotContext, [WindowItem]>()
    private let minimizedSnapshotEpoch = LockedValue<UInt64>(0)

    init() {
        capturePermitPool = Self.processCapturePermitPool
    }

    private static func captureWindowStates(
        for windowIDs: Set<CGWindowID>
    ) -> [CGWindowID: PreviewCaptureWindowState] {
        guard !windowIDs.isEmpty else { return [:] }
        // CGWindowListCreateDescriptionFromArray returns an empty list on
        // current macOS even for valid visible IDs. Use the same public window
        // list surface as enumeration and filter it down to this small batch.
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var states: [CGWindowID: PreviewCaptureWindowState] = [:]
        states.reserveCapacity(windowIDs.count)
        for entry in rawList {
            guard let windowID = entry[kCGWindowNumber as String] as? UInt32,
                  windowIDs.contains(windowID),
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool,
                  let sharingState = entry[kCGWindowSharingState as String] as? Int,
                  let alpha = entry[kCGWindowAlpha as String] as? Double else {
                continue
            }
            states[windowID] = PreviewCaptureWindowState(
                ownerPID: ownerPID,
                bounds: bounds,
                isOnScreen: isOnScreen,
                sharingState: sharingState,
                alpha: alpha
            )
        }
        return states
    }

    /// Re-warms the cache after a capture session so the next Cmd+Tab is fast.
    func refreshContentCache() async {
        await contentCache.refreshIfAllowed()
    }

    func refreshContentCache(context: String) async {
        await contentCache.refreshIfAllowed(successContext: context)
    }

    /// Like `refreshContentCache` but no-op when the cache is still fresh.
    /// Called from SwitcherStore on every NSWorkspace app activation so the
    /// cache stays warm while the user is doing anything at all. The staleness
    /// gate prevents this from hammering SCKit during rapid app switches.
    func refreshContentCacheIfStale() async {
        await contentCache.refreshIfStale()
    }

    func invalidateContentCache(reason: String) async {
        await contentCache.invalidate(reason: reason)
    }

    /// Drops stale SCWindow refs after process topology changes, then warms
    /// replacement content before the next Cmd+Tab preview batch needs it.
    func invalidateAndRefreshContentCache(reason: String, context: String) async {
        await contentCache.invalidate(reason: reason)
        await contentCache.refreshIfAllowed(successContext: context)
    }

    /// Fast path used on the Cmd+Tab critical path. Includes one icon-only
    /// fallback for each running regular app that has no eligible window in the
    /// selected scope. Skips the AX walk for minimized windows entirely; merge
    /// concrete minimized rows in lazily via `snapshotMinimized`.
    /// One AX cost remains: the frontmost app's focused-window probe in
    /// `normalizeFrontmostWindowOrder`, only when that app has several visible
    /// windows, bounded by the 0.25 s messaging timeout and reported as
    /// `ax_ms` in the `frontmost_focus_normalize` metric.
    func snapshotVisibleOnly() -> [WindowItem] {
        snapshotInternal(includeMinimized: false).visible
    }

    /// Returns minimized windows from an AX walk. ~150–500ms with many running
    /// apps — call from a background task and merge into items after the panel
    /// is already on screen. Safe to call AX read APIs off the main thread.
    func snapshotMinimized(cancellation: CooperativeCancellationToken) async -> [WindowItem] {
        guard !cancellation.isCancelled else { return [] }
        let requestEpoch = minimizedSnapshotEpoch.withValue { epoch in
            epoch &+= 1
            return epoch
        }
        let context = MinimizedSnapshotContext(
            requestEpoch: requestEpoch,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            scope: WindowFilterState.scope,
            hiddenAppTokens: HiddenAppFilterState.normalizedTokens
        )
        return await minimizedSnapshotCoalescer.value(for: context) { [self] in
            guard !cancellation.isCancelled else { return [] }
            return minimizedItems(
                excluding: Set(),
                frontmostPID: context.frontmostPID,
                sharingStateIndex: WindowSharingStateIndex.fromCurrentWindowList(),
                scope: context.scope,
                hiddenAppTokens: context.hiddenAppTokens,
                cancellation: cancellation
            )
        } ?? []
    }

    func snapshot() -> [WindowItem] {
        let result = snapshotInternal(includeMinimized: true)
        return result.visible + result.minimized
    }

    private struct SnapshotResult {
        let visible: [WindowItem]
        let minimized: [WindowItem]
    }

    private func snapshotInternal(includeMinimized: Bool) -> SnapshotResult {
        // .optionOnScreenOnly when restricting to current Space — macOS only
        // returns windows it considers on-screen, which excludes other Spaces.
        // .optionAll lets windows from other Spaces through.
        let windowScope = WindowFilterState.scope
        let listOptions: CGWindowListOption = windowScope == .currentSpace
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[String: Any]] else {
            return SnapshotResult(visible: [], minimized: [])
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let runningApplicationSnapshot = Self.runningApplicationSnapshot()
        let runningApplications = runningApplicationSnapshot.applications
        let runningApplicationsByPID = runningApplicationSnapshot.applicationsByProcessIdentifier
        let runningApplicationDescriptors = runningApplications.map(Self.applicationDescriptor)
        var applicationResolutionsByPID: [pid_t: WindowApplicationResolution] = [:]
        var rejectedApplicationPIDs = Set<pid_t>()
        var visibleWindowIDs = Set<CGWindowID>()

        func applicationResolution(for ownerPID: pid_t) -> WindowApplicationResolution? {
            if let cached = applicationResolutionsByPID[ownerPID] { return cached }
            if rejectedApplicationPIDs.contains(ownerPID) { return nil }
            guard let windowApplication = runningApplicationsByPID[ownerPID]
                    ?? NSRunningApplication(processIdentifier: ownerPID),
                  let resolution = resolveWindowApplication(
                      windowApplication,
                      runningApplicationsByPID: runningApplicationsByPID,
                      runningApplicationDescriptors: runningApplicationDescriptors
                  ) else {
                rejectedApplicationPIDs.insert(ownerPID)
                return nil
            }
            applicationResolutionsByPID[ownerPID] = resolution
            return resolution
        }

        let visibleItems = rawList.compactMap { entry -> WindowItem? in
            guard let windowID = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  let appName = entry[kCGWindowOwnerName as String] as? String,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                return nil
            }

            if appName == "Window Server" {
                return nil
            }

            // When restricting to current Space, also re-check isOnScreen per
            // entry. The list option above already filters, but the explicit
            // check protects against macOS occasionally returning stale rows.
            // When not restricting, accept windows regardless of isOnScreen.
            if windowScope == .currentSpace {
                let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
                guard isOnScreen else { return nil }
            }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else {
                return nil
            }

            let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                .flatMap(CGRect.init(dictionaryRepresentation:)) ?? .zero
            guard bounds.width >= 120, bounds.height >= 80 else {
                return nil
            }

            let title = entry[kCGWindowName as String] as? String ?? ""
            guard let applicationResolution = applicationResolution(for: ownerPID) else {
                return nil
            }
            if windowScope == .currentApp,
               applicationResolution.hostProcessIdentifier != frontmostPID,
               applicationResolution.windowProcessIdentifier != frontmostPID {
                return nil
            }
            let sharingState = entry[kCGWindowSharingState as String] as? Int ?? 0

            guard shouldIncludeWindow(
                appName: applicationResolution.appName,
                applicationResolution: applicationResolution,
                title: title,
                sharingState: sharingState
            ) else {
                return nil
            }
            visibleWindowIDs.insert(windowID)

            return WindowItem(
                windowID: windowID,
                pid: applicationResolution.hostProcessIdentifier,
                appName: applicationResolution.appName,
                title: title,
                bounds: bounds,
                isFrontmostApp: applicationResolution.hostProcessIdentifier == frontmostPID
                    || applicationResolution.windowProcessIdentifier == frontmostPID,
                isMinimized: false,
                canCapturePreview: sharingState != 0,
                isTitleRedacted: false,
                preview: nil,
                icon: IconNaming.named(
                    applicationResolution.hostApplication.icon,
                    bundleIdentifier: applicationResolution.hostApplication.bundleIdentifier,
                    appName: applicationResolution.appName
                ),
                bundleIdentifier: applicationResolution.hostApplication.bundleIdentifier,
                windowOwnerPID: applicationResolution.windowOwnerPID
            )
        }

        let filteredVisibleItems = filterAuxiliaryWindowSurfaces(
            HostedWindowSurfacePolicy.filteringMirroredHostedSurfaces(visibleItems)
        )
        let applicationFallbacks = applicationFallbackItems(
            representedApplicationPIDs: Set(filteredVisibleItems.map(\.pid)),
            runningApplications: runningApplications,
            frontmostPID: frontmostPID,
            scope: windowScope,
            hiddenAppTokens: HiddenAppFilterState.normalizedTokens
        )
        let minimized = includeMinimized
            ? minimizedItems(
                excluding: visibleWindowIDs,
                frontmostPID: frontmostPID,
                sharingStateIndex: WindowSharingStateIndex(rawList: rawList),
                scope: windowScope,
                hiddenAppTokens: HiddenAppFilterState.normalizedTokens,
                cancellation: CooperativeCancellationToken()
            )
            : []
        let minimizedApplicationPIDs = Set(minimized.map(\.pid))
        let visibleAndApplicationFallbacks = (filteredVisibleItems + applicationFallbacks)
            .filter { item in
                !item.isApplicationFallback || !minimizedApplicationPIDs.contains(item.pid)
            }
        PerformanceDiagnostics.record(
            "window_snapshot",
            fields: [
                "application_fallbacks": .int(applicationFallbacks.count),
                "concrete_visible": .int(filteredVisibleItems.count),
                "minimized": .int(minimized.count),
                "scope": .string(windowScope.rawValue)
            ]
        )
        return SnapshotResult(
            visible: normalizeFrontmostWindowOrder(
                visibleAndApplicationFallbacks,
                frontmostPID: frontmostPID
            ),
            minimized: minimized
        )
    }

    private func filterAuxiliaryWindowSurfaces(_ items: [WindowItem]) -> [WindowItem] {
        guard AXIsProcessTrusted(), items.count > 1 else { return items }

        let itemsByPID = Dictionary(grouping: items, by: \.windowProcessIdentifier)
        var orderedPIDs: [pid_t] = []
        var seenPIDs = Set<pid_t>()
        for item in items where seenPIDs.insert(item.windowProcessIdentifier).inserted {
            guard let siblings = itemsByPID[item.windowProcessIdentifier],
                  AXWindowEligibilityPolicy.requiresValidation(siblings) else {
                continue
            }
            orderedPIDs.append(item.windowProcessIdentifier)
        }
        guard !orderedPIDs.isEmpty else { return items }

        let startedAt = ProcessInfo.processInfo.systemUptime
        var budget = AXScanBudget(
            maximumApplications: Self.maximumAuxiliaryValidationApplications,
            maximumWindows: Self.maximumAuxiliaryValidationWindows,
            maximumElapsedSeconds: Self.maximumAuxiliaryValidationSeconds,
            startedAt: startedAt
        )
        var allowedWindowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        var validatedApplications = 0
        var fallbackApplications = 0

        for pid in orderedPIDs {
            guard budget.beginApplication(now: ProcessInfo.processInfo.systemUptime) else { break }
            guard let siblings = itemsByPID[pid],
                  let candidates = topLevelAXWindowCandidates(pid: pid, budget: &budget) else {
                fallbackApplications += 1
                continue
            }
            let filtered = AXWindowEligibilityPolicy.filteredItems(
                siblings,
                candidates: candidates
            )
            allowedWindowIDsByPID[pid] = Set(filtered.map(\.id))
            validatedApplications += 1
        }

        let filteredItems = items.filter { item in
            allowedWindowIDsByPID[item.windowProcessIdentifier]?.contains(item.id) ?? true
        }
        PerformanceDiagnostics.record(
            "window_ax_eligibility",
            fields: [
                "budget_exhausted": .bool(budget.isExhausted),
                "candidate_apps": .int(orderedPIDs.count),
                "fallback_apps": .int(fallbackApplications),
                "filtered_windows": .int(items.count - filteredItems.count),
                "milliseconds": .double(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                ),
                "validated_apps": .int(validatedApplications)
            ]
        )
        return filteredItems
    }

    private func topLevelAXWindowCandidates(
        pid: pid_t,
        budget: inout AXScanBudget
    ) -> [AXTopLevelWindowCandidate]? {
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, Self.auxiliaryWindowAXTimeoutSeconds)
        guard let windows = axWindows(for: appElement),
              windows.count <= Self.maximumAuxiliaryWindowsPerApplication else {
            return nil
        }

        var candidates: [AXTopLevelWindowCandidate] = []
        candidates.reserveCapacity(windows.count)
        for window in windows {
            guard budget.beginWindow(now: ProcessInfo.processInfo.systemUptime) else { return nil }
            _ = AXUIElementSetMessagingTimeout(window, Self.auxiliaryWindowAXTimeoutSeconds)
            guard let candidate = topLevelAXWindowCandidate(window) else { return nil }
            candidates.append(candidate)
        }
        return candidates
    }

    private func topLevelAXWindowCandidate(_ window: AXUIElement) -> AXTopLevelWindowCandidate? {
        let attributes = [
            kAXTitleAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
            kAXSubroleAttribute
        ] as CFArray
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            window,
            attributes,
            [],
            &rawValues
        ) == .success,
              let rawValues,
              CFArrayGetCount(rawValues) == 4 else {
            return nil
        }

        let values = rawValues as NSArray
        let title = values[0] as? String
        let positionValue = values[1] as CFTypeRef
        let sizeValue = values[2] as CFTypeRef
        let subrole = values[3] as? String
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return AXTopLevelWindowCandidate(
            title: title,
            frame: CGRect(origin: point, size: size),
            isSwitcherWindow: subrole != (kAXSystemDialogSubrole as String)
        )
    }

    /// CGWindowList z-order lags briefly after an activation: the frontmost
    /// app's previously-front sibling can still be listed first, and
    /// `orderedForDisplay` anchors slot 0 on the first same-pid row. When the
    /// frontmost app has several visible windows, resolve its AX-focused
    /// window and move it ahead of its logical app siblings so slot 0 is the
    /// window that actually has focus. Hosted helper windows keep their helper
    /// PID for AX while `WindowItem.pid` identifies the regular app.
    private func normalizeFrontmostWindowOrder(_ items: [WindowItem], frontmostPID: pid_t?) -> [WindowItem] {
        guard let frontmostPID else { return items }
        guard let frontmostItem = items.first(where: { $0.isFrontmostApp }) else { return items }
        let windowPID = frontmostItem.windowProcessIdentifier
        let siblingCount = items.reduce(0) {
            $0 + ($1.windowProcessIdentifier == windowPID ? 1 : 0)
        }
        guard siblingCount > 1 else { return items }

        let axStart = Date()
        let focusInfo = focusedAXWindowInfo(pid: windowPID)
        let axMs = Date().timeIntervalSince(axStart) * 1000
        let focused = focusInfo.flatMap {
            Self.focusedWindowMatch(
                in: items,
                pid: windowPID,
                focusedTitle: $0.title,
                focusedFrame: $0.frame
            )
        }
        let normalized = focused.map {
            Self.promotingWindow($0.id, in: items, beforeSiblingsOf: frontmostItem.pid)
        } ?? items
        PerformanceDiagnostics.record(
            "frontmost_focus_normalize",
            fields: [
                "ax_ms": .double(axMs),
                "ax_resolved": .bool(focusInfo != nil),
                "matched": .bool(focused != nil),
                "moved": .bool(normalized.map(\.id) != items.map(\.id)),
                "pid": .int(Int(frontmostPID)),
                "sibling_count": .int(siblingCount)
            ]
        )
        return normalized
    }

    /// Matches the AX-focused window info against `items` (same window-owner
    /// pid, visible
    /// only). Exact title match first; frame proximity disambiguates
    /// same-titled siblings. Returns nil when ambiguous — a wrong guess here
    /// would bake the wrong "active window" into MRU state.
    static func focusedWindowMatch(
        in items: [WindowItem],
        pid: pid_t,
        focusedTitle: String?,
        focusedFrame: CGRect?
    ) -> WindowItem? {
        let siblings = items.filter {
            $0.windowProcessIdentifier == pid && !$0.isMinimized
        }
        guard let first = siblings.first else { return nil }
        guard siblings.count > 1 else { return first }

        var candidates = siblings
        if let focusedTitle, !focusedTitle.isEmpty {
            let titleMatches = siblings.filter { $0.title == focusedTitle }
            if titleMatches.count == 1 { return titleMatches[0] }
            if !titleMatches.isEmpty { candidates = titleMatches }
        }
        guard let focusedFrame else { return nil }
        let frameMatches = candidates.filter {
            WindowActivator.framesAreClose($0.bounds, focusedFrame)
        }
        return frameMatches.count == 1 ? frameMatches[0] : nil
    }

    /// Moves `windowID` in front of the first window owned by `pid`, keeping
    /// every other position stable. No-op when it already leads its app group
    /// or is absent.
    static func promotingWindow(
        _ windowID: CGWindowID,
        in items: [WindowItem],
        beforeSiblingsOf pid: pid_t
    ) -> [WindowItem] {
        guard let currentIndex = items.firstIndex(where: { $0.id == windowID }),
              let firstSiblingIndex = items.firstIndex(where: { $0.pid == pid }),
              currentIndex != firstSiblingIndex else {
            return items
        }
        var reordered = items
        let item = reordered.remove(at: currentIndex)
        reordered.insert(item, at: firstSiblingIndex)
        return reordered
    }

    /// Resolves the app's AX-focused window and returns the matching item
    /// from a fresh visible snapshot. Used to upgrade an identity-only
    /// activation rank to a concrete per-window rank.
    func focusedWindowItem(pid: pid_t) -> WindowItem? {
        let items = snapshotVisibleOnly()
        var seenWindowPIDs = Set<pid_t>()
        for item in items where item.pid == pid {
            let windowPID = item.windowProcessIdentifier
            guard seenWindowPIDs.insert(windowPID).inserted,
                  let info = focusedAXWindowInfo(pid: windowPID),
                  let match = Self.focusedWindowMatch(
                      in: items,
                      pid: windowPID,
                      focusedTitle: info.title,
                      focusedFrame: info.frame
                  ) else {
                continue
            }
            return match
        }
        return nil
    }

    /// Reads the focused window's title and frame via AX. Bounded by the same
    /// 0.25 s messaging timeout as the minimized walk so a hung app cannot
    /// stall the snapshot path.
    private func focusedAXWindowInfo(pid: pid_t) -> (title: String?, frame: CGRect?)? {
        let axTimeoutSeconds: Float = 0.25
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = rawValue as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(window, axTimeoutSeconds)
        return (axString(kAXTitleAttribute, on: window), axFrame(on: window))
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int
    ) async -> [CGWindowID: NSImage] {
        guard !Task.isCancelled else { return [:] }
        // Single preflight syscall instead of currentState() which does three.
        guard CGPreflightScreenCaptureAccess() else {
            PerformanceDiagnostics.record(
                "capture_previews",
                fields: [
                    "captured": .int(0),
                    "max_concurrent": .int(maxConcurrentCaptures),
                    "requested": .int(maxCount.map { min(windowIDs.count, $0) } ?? windowIDs.count),
                    "screen_recording": .bool(false)
                ]
            )
            return [:]
        }

        // Refresh inline when the cache is missing OR stale: stale SCWindow refs
        // lose their warm capture-pipeline link, and proceeding with them costs
        // ~300 ms timeout + retry per window. The inline refresh is ~30–80 ms.
        await self.refreshContentCacheIfStale()
        guard let content = await contentCache.content else {
            Logger.capture.error("capturePreviews: no SCShareableContent available")
            return [:]
        }
        guard !Task.isCancelled else { return [:] }
        let windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let maxDim = 320
        let captureTimeoutMs = 300
        let fallbackTimeoutMs = 300
        let requestedIDs = maxCount.map { Array(windowIDs.prefix($0)) } ?? windowIDs
        let requestedIDSet = Set(requestedIDs)
        let captureScope = WindowFilterState.scope
        let captureStatesBefore = Self.captureWindowStates(for: requestedIDSet)
        let captureTargets = requestedIDs.compactMap { windowID -> (CGWindowID, SCWindow)? in
            guard let window = windowsByID[windowID] else { return nil }
            return (windowID, window)
        }
        let captureTargetIDs = Set(captureTargets.map { $0.0 })
        // Windows known to the switcher (from CGWindowList) but absent from
        // SCShareableContent. SCKit silently drops these — they get no capture
        // attempt at all. CGWindowList fallback runs for them after the SCKit pass.
        let scMissingIDs = requestedIDs.filter {
            !captureTargetIDs.contains($0) && !SyntheticWindowID.isSynthetic($0)
        }
        if !scMissingIDs.isEmpty {
            Logger.capture.notice(
                "capturePreviews: \(scMissingIDs.count, privacy: .public) windows absent from SCShareableContent — CGWindowList fallback queued"
            )
        }
        guard !captureTargets.isEmpty || !scMissingIDs.isEmpty else {
            Logger.capture.notice("capturePreviews: no matching SCWindows for \(windowIDs.count, privacy: .public) requested IDs")
            return [:]
        }
        let captureStart = Date()
        let permitPool = capturePermitPool

        return await withTaskGroup(of: WindowCaptureOutcome.self) { group in
            var nextIndex = 0
            var firstAttemptTimeouts = 0
            var firstAttemptFailures = 0
            var firstAttemptResourceLimits = 0
            var secondAttemptTimeouts = 0
            var secondAttemptFailures = 0
            var secondAttemptResourceLimits = 0
            var fallbackTimeouts = 0
            var fallbackFailures = 0
            var fallbackResourceLimits = 0

            func enqueueNextCapture() -> Bool {
                guard !Task.isCancelled, nextIndex < captureTargets.count else { return false }
                let (windowID, window) = captureTargets[nextIndex]
                nextIndex += 1
                nonisolated(unsafe) let capturedWindow = window
                group.addTask {
                    // Retry only a completed failure. A timed-out framework call
                    // still owns its global permit until Apple's API returns, so
                    // starting another call for the same window would compound
                    // the stall this limiter exists to contain.
                    let first = await SCContentCache.captureWithSoftTimeout(
                        window: capturedWindow,
                        maxDim: maxDim,
                        timeoutMs: captureTimeoutMs,
                        permitPool: permitPool
                    )
                    if case .success(let image) = first {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: image,
                            firstAttempt: first,
                            secondAttempt: nil,
                            fallbackAttempt: nil
                        )
                    }
                    if Task.isCancelled {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: nil,
                            fallbackAttempt: nil
                        )
                    }
                    if case .timedOut = first {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: nil,
                            fallbackAttempt: nil
                        )
                    }
                    if case .resourceLimited = first {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: nil,
                            fallbackAttempt: nil
                        )
                    }
                    let reason: String = switch first {
                    case .failed: "failed"
                    case .success: "succeeded" // unreachable; success returned above
                    case .timedOut: "timed out" // returned above
                    case .resourceLimited: "resource limited" // returned above
                    }
                    Logger.capture.notice(
                        "First capture \(reason, privacy: .public) for windowID=\(windowID, privacy: .public) — retrying"
                    )
                    let second = await SCContentCache.captureWithSoftTimeout(
                        window: capturedWindow,
                        maxDim: maxDim,
                        timeoutMs: captureTimeoutMs,
                        permitPool: permitPool
                    )
                    if case .success(let image) = second {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: image,
                            firstAttempt: first,
                            secondAttempt: second,
                            fallbackAttempt: nil
                        )
                    }
                    if Task.isCancelled {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: second,
                            fallbackAttempt: nil
                        )
                    }
                    if case .timedOut = second {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: second,
                            fallbackAttempt: nil
                        )
                    }
                    if case .resourceLimited = second {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: nil,
                            firstAttempt: first,
                            secondAttempt: second,
                            fallbackAttempt: nil
                        )
                    }
                    let fallback = await WindowCatalog.captureFallbackWithSoftTimeout(
                        windowID: windowID,
                        maxDim: maxDim,
                        timeoutMs: fallbackTimeoutMs,
                        permitPool: permitPool
                    )
                    if case .success(let image) = fallback {
                        Logger.capture.notice(
                            "CGWindowList fallback used for windowID=\(windowID, privacy: .public) — SCKit retry also failed"
                        )
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: image,
                            firstAttempt: first,
                            secondAttempt: second,
                            fallbackAttempt: fallback
                        )
                    }
                    if case .timedOut = fallback {
                        Logger.capture.error(
                            "CGWindowList fallback timed out for windowID=\(windowID, privacy: .public)"
                        )
                    } else if case .resourceLimited = fallback {
                        Logger.capture.notice(
                            "CGWindowList fallback skipped by global capture limit for windowID=\(windowID, privacy: .public)"
                        )
                    } else {
                        Logger.capture.error(
                            "All capture attempts failed for windowID=\(windowID, privacy: .public)"
                        )
                    }
                    return WindowCaptureOutcome(
                        windowID: windowID,
                        image: nil,
                        firstAttempt: first,
                        secondAttempt: second,
                        fallbackAttempt: fallback
                    )
                }

                return true
            }

            let initialCaptureCount = min(max(1, maxConcurrentCaptures), captureTargets.count)
            for _ in 0 ..< initialCaptureCount {
                _ = enqueueNextCapture()
            }

            var result: [CGWindowID: NSImage] = [:]
            for await captureResult in group {
                switch captureResult.firstAttempt {
                case .success:
                    break
                case .failed:
                    firstAttemptFailures += 1
                case .timedOut:
                    firstAttemptTimeouts += 1
                case .resourceLimited:
                    firstAttemptResourceLimits += 1
                }

                if let secondAttempt = captureResult.secondAttempt {
                    switch secondAttempt {
                    case .success:
                        break
                    case .failed:
                        secondAttemptFailures += 1
                    case .timedOut:
                        secondAttemptTimeouts += 1
                    case .resourceLimited:
                        secondAttemptResourceLimits += 1
                    }
                }

                if let fallbackAttempt = captureResult.fallbackAttempt {
                    switch fallbackAttempt {
                    case .success:
                        break
                    case .failed:
                        fallbackFailures += 1
                    case .timedOut:
                        fallbackTimeouts += 1
                    case .resourceLimited:
                        fallbackResourceLimits += 1
                    }
                }

                if let image = captureResult.image {
                    result[captureResult.windowID] = image
                }
                _ = enqueueNextCapture()
            }

            if !Task.isCancelled, !scMissingIDs.isEmpty {
                await withTaskGroup(of: (CGWindowID, FallbackAttemptResult).self) { fallbackGroup in
                    for windowID in scMissingIDs {
                        let wid = windowID
                        fallbackGroup.addTask {
                            let fallback = await WindowCatalog.captureFallbackWithSoftTimeout(
                                windowID: wid,
                                maxDim: maxDim,
                                timeoutMs: fallbackTimeoutMs,
                                permitPool: permitPool
                            )
                            return (wid, fallback)
                        }
                    }
                    for await (windowID, fallback) in fallbackGroup {
                        switch fallback {
                        case .success(let image):
                            Logger.capture.notice(
                                "CGWindowList fallback used for windowID=\(windowID, privacy: .public) — not in SCShareableContent"
                            )
                            result[windowID] = image
                        case .failed:
                            fallbackFailures += 1
                        case .timedOut:
                            fallbackTimeouts += 1
                        case .resourceLimited:
                            fallbackResourceLimits += 1
                        }
                    }
                }
            }
            let captureStatesAfter = Self.captureWindowStates(for: Set(result.keys))
            let acceptedWindowIDs = PreviewCaptureStabilityPolicy.acceptedWindowIDs(
                capturedWindowIDs: Set(result.keys),
                before: captureStatesBefore,
                after: captureStatesAfter,
                scope: captureScope
            )
            let transitionRejected = result.count - acceptedWindowIDs.count
            if transitionRejected > 0 {
                result = result.filter { acceptedWindowIDs.contains($0.key) }
                Logger.capture.notice(
                    "Rejected \(transitionRejected, privacy: .public) preview frame(s) captured during a window transition"
                )
            }

            let ms = Date().timeIntervalSince(captureStart) * 1000
            PerformanceDiagnostics.record(
                "capture_previews",
                fields: [
                    "captured": .int(result.count),
                    "first_failures": .int(firstAttemptFailures),
                    "first_resource_limited": .int(firstAttemptResourceLimits),
                    "first_timeouts": .int(firstAttemptTimeouts),
                    "max_concurrent": .int(maxConcurrentCaptures),
                    "milliseconds": .double(ms),
                    "requested": .int(requestedIDs.count),
                    "sc_missing": .int(scMissingIDs.count),
                    "screen_recording": .bool(true),
                    "fallback_failures": .int(fallbackFailures),
                    "fallback_resource_limited": .int(fallbackResourceLimits),
                    "fallback_timeouts": .int(fallbackTimeouts),
                    "second_failures": .int(secondAttemptFailures),
                    "second_resource_limited": .int(secondAttemptResourceLimits),
                    "second_timeouts": .int(secondAttemptTimeouts),
                    "stability_after": .int(captureStatesAfter.count),
                    "stability_before": .int(captureStatesBefore.count),
                    "transition_rejected": .int(transitionRejected)
                ]
            )
            if PerformanceLoggingState.mode == .debug {
                Logger.capture.info(
                    "Captured \(result.count, privacy: .public)/\(requestedIDs.count, privacy: .public) previews in \(ms, format: .fixed(precision: 1), privacy: .public) ms; firstTimeouts=\(firstAttemptTimeouts, privacy: .public), firstFailures=\(firstAttemptFailures, privacy: .public), firstLimited=\(firstAttemptResourceLimits, privacy: .public), secondTimeouts=\(secondAttemptTimeouts, privacy: .public), secondFailures=\(secondAttemptFailures, privacy: .public), secondLimited=\(secondAttemptResourceLimits, privacy: .public), fallbackTimeouts=\(fallbackTimeouts, privacy: .public), fallbackFailures=\(fallbackFailures, privacy: .public), fallbackLimited=\(fallbackResourceLimits, privacy: .public)"
                )
            }
            return result
        }
    }

    private static func applicationDescriptor(
        _ application: NSRunningApplication
    ) -> RunningApplicationDescriptor {
        RunningApplicationDescriptor(
            processIdentifier: application.processIdentifier,
            activationPolicy: application.activationPolicy,
            isFinishedLaunching: application.isFinishedLaunching,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL
        )
    }

    private static func runningApplicationSnapshot() -> RunningApplicationSnapshot {
        let snapshot = RunningApplicationSnapshot.coalescing(NSWorkspace.shared.runningApplications)
        let irregularCount = snapshot.discardedInvalidProcessIdentifiers
            + snapshot.coalescedDuplicateProcessIdentifiers
        if irregularCount > 0 {
            Logger.switcher.notice(
                "Coalesced running application snapshot: invalidPIDs=\(snapshot.discardedInvalidProcessIdentifiers, privacy: .public), duplicatePIDs=\(snapshot.coalescedDuplicateProcessIdentifiers, privacy: .public)"
            )
        }
        return snapshot
    }

    private func resolveWindowApplication(
        _ windowApplication: NSRunningApplication,
        runningApplicationsByPID: [pid_t: NSRunningApplication],
        runningApplicationDescriptors: [RunningApplicationDescriptor]
    ) -> WindowApplicationResolution? {
        guard let hostPID = HostedWindowApplicationPolicy.hostProcessIdentifier(
            for: Self.applicationDescriptor(windowApplication),
            among: runningApplicationDescriptors,
            currentProcessIdentifier: getpid()
        ),
              let hostApplication = hostPID == windowApplication.processIdentifier
                ? windowApplication
                : runningApplicationsByPID[hostPID] else {
            return nil
        }
        return WindowApplicationResolution(
            windowApplication: windowApplication,
            hostApplication: hostApplication
        )
    }

    private func shouldIncludeWindow(
        appName: String,
        applicationResolution: WindowApplicationResolution,
        title: String,
        sharingState: Int
    ) -> Bool {
        // sharingState == kCGWindowSharingNone (0) means macOS may refuse to
        // capture a preview for the window. Most such windows are privacy /
        // DRM / autofill surfaces and should stay hidden. Microsoft Teams is
        // the important exception: real meeting/chat windows can use this
        // sharing state, and switching to them is more important than showing
        // a live preview. Those tiles fall back to the app-icon treatment.
        let windowApplication = applicationResolution.windowApplication
        let hostApplication = applicationResolution.hostApplication
        guard WindowEligibilityPolicy.canIncludeApplication(
                  processIdentifier: hostApplication.processIdentifier,
                  currentProcessIdentifier: getpid(),
                  activationPolicy: hostApplication.activationPolicy,
                  isFinishedLaunching: hostApplication.isFinishedLaunching
              ) else {
            return false
        }
        guard WindowSharingPolicy.canListWindow(
            appName: appName,
            bundleIdentifier: hostApplication.bundleIdentifier,
            title: title,
            sharingState: sharingState
        ) else {
            return false
        }
        if [windowApplication.bundleIdentifier, hostApplication.bundleIdentifier]
            .compactMap({ $0 })
            .contains(where: excludedBundleIdentifiers.contains) {
            return false
        }

        if isHiddenByUser(appName: appName, bundleIdentifier: hostApplication.bundleIdentifier) {
            return false
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty,
           appName.localizedCaseInsensitiveContains("autofill") {
            return false
        }

        return true
    }

    private func applicationFallbackItems(
        representedApplicationPIDs: Set<pid_t>,
        runningApplications: [NSRunningApplication],
        frontmostPID: pid_t?,
        scope: SBWindowScope,
        hiddenAppTokens: Set<HiddenAppToken>
    ) -> [WindowItem] {
        let descriptors = runningApplications.map(Self.applicationDescriptor)
        let fallbackPIDs = Set(ApplicationFallbackPolicy.processIdentifiers(
            from: descriptors,
            representedApplicationPIDs: representedApplicationPIDs,
            currentProcessIdentifier: getpid(),
            frontmostPID: frontmostPID,
            scope: scope
        ))
        guard !fallbackPIDs.isEmpty else { return [] }

        return runningApplications.compactMap { application in
            let pid = application.processIdentifier
            guard fallbackPIDs.contains(pid), !application.isTerminated else { return nil }

            let bundleIdentifier = application.bundleIdentifier
            guard bundleIdentifier.map({ !excludedBundleIdentifiers.contains($0) }) ?? true else {
                return nil
            }
            let appName = application.localizedName
                ?? bundleIdentifier
                ?? application.bundleURL?.deletingPathExtension().lastPathComponent
                ?? "Application"
            guard !isHiddenByUser(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                tokens: hiddenAppTokens
            ) else {
                return nil
            }

            return WindowItem(
                windowID: SyntheticApplicationID.make(
                    pid: pid,
                    bundleIdentifier: bundleIdentifier,
                    appName: appName
                ),
                pid: pid,
                appName: appName,
                title: "",
                bounds: CGRect(x: 0, y: 0, width: 640, height: 400),
                isFrontmostApp: pid == frontmostPID,
                isMinimized: false,
                canCapturePreview: false,
                isTitleRedacted: false,
                preview: nil,
                icon: IconNaming.named(
                    application.icon,
                    bundleIdentifier: bundleIdentifier,
                    appName: appName
                ),
                bundleIdentifier: bundleIdentifier,
                windowOwnerPID: nil
            )
        }
    }

    private func minimizedItems(
        excluding visibleWindowIDs: Set<CGWindowID>,
        frontmostPID: pid_t?,
        sharingStateIndex: WindowSharingStateIndex,
        scope: SBWindowScope,
        hiddenAppTokens: Set<HiddenAppToken>,
        cancellation: CooperativeCancellationToken
    ) -> [WindowItem] {
        // Soft bound on AX IPC. Per Apple's AXUIElement header, a timeout set
        // on a specific element only governs calls to *that* element — it does
        // not propagate to children — so we set it on the app element (for
        // axWindows) and again on each window element (for axBool/axString/
        // axFrame). Already-in-flight AX calls keep running until the
        // framework returns; this only bounds new IPC, same as the
        // capture soft-timeout pattern.
        let axTimeoutSeconds: Float = 0.25
        // Real local telemetry: 9,977 activation samples, p95=3 candidate
        // windows and max=11. These ceilings are deliberately above that
        // observed scale while preventing a pathological app from running an
        // abandoned AX sweep without an aggregate bound.
        var budget = AXScanBudget(
            maximumApplications: 32,
            maximumWindows: 128,
            maximumElapsedSeconds: 2.0,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        var result: [WindowItem] = []
        var exactTitleMatchCount = 0
        var frameMatchCount = 0
        let runningApplicationSnapshot = Self.runningApplicationSnapshot()
        let runningApplications = runningApplicationSnapshot.applications
        let runningApplicationsByPID = runningApplicationSnapshot.applicationsByProcessIdentifier
        let runningApplicationDescriptors = runningApplications.map(Self.applicationDescriptor)
        applicationLoop: for windowApplication in runningApplications {
            // Bypass the rest of the sweep if the merge consumer already lost
            // interest (panel hidden, generation bumped). Won't unstick an
            // already-blocked AX call; only stops *new* per-app iterations.
            if cancellation.isCancelled { break }
            guard let applicationResolution = resolveWindowApplication(
                windowApplication,
                runningApplicationsByPID: runningApplicationsByPID,
                runningApplicationDescriptors: runningApplicationDescriptors
            ),
                  shouldIncludeApplication(
                      applicationResolution,
                      hiddenAppTokens: hiddenAppTokens
                  ) else {
                continue
            }
            if scope == .currentApp,
               applicationResolution.hostProcessIdentifier != frontmostPID,
               applicationResolution.windowProcessIdentifier != frontmostPID {
                continue
            }
            guard budget.beginApplication(now: ProcessInfo.processInfo.systemUptime) else { break }

            let appElement = AXUIElementCreateApplication(applicationResolution.windowProcessIdentifier)
            _ = AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
            guard let windows = axWindows(for: appElement) else { continue }

            let appName = applicationResolution.appName
            for (index, window) in windows.enumerated() {
                guard !cancellation.isCancelled else { break applicationLoop }
                guard budget.beginWindow(now: ProcessInfo.processInfo.systemUptime) else {
                    break applicationLoop
                }
                _ = AXUIElementSetMessagingTimeout(window, axTimeoutSeconds)
                guard axBool(kAXMinimizedAttribute, on: window) == true else { continue }

                let title = axString(kAXTitleAttribute, on: window) ?? ""
                let frame = axFrame(on: window)
                let exactTitleMatch = sharingStateIndex.uniqueWindow(
                    pid: applicationResolution.windowProcessIdentifier,
                    title: title
                )
                let frameMatch = exactTitleMatch == nil
                    ? frame.flatMap {
                        sharingStateIndex.uniqueWindow(
                            pid: applicationResolution.windowProcessIdentifier,
                            bounds: $0
                        )
                    }
                    : nil
                let matchedWindow = exactTitleMatch ?? frameMatch
                if exactTitleMatch != nil {
                    exactTitleMatchCount += 1
                } else if frameMatch != nil {
                    frameMatchCount += 1
                }
                let titleDecision = WindowSharingPolicy.minimizedTitleDecision(
                    appName: appName,
                    bundleIdentifier: applicationResolution.hostApplication.bundleIdentifier,
                    title: title,
                    matchingSharingStates: matchedWindow.map { [$0.sharingState] }
                        ?? sharingStateIndex.sharingStates(
                            pid: applicationResolution.windowProcessIdentifier,
                            title: title
                        )
                )
                if titleDecision == .exclude {
                    continue
                }

                let windowID = matchedWindow?.windowID ?? SyntheticWindowID.make(
                    pid: applicationResolution.windowProcessIdentifier,
                    index: index,
                    title: title
                )
                guard !visibleWindowIDs.contains(windowID) else { continue }

                result.append(WindowItem(
                    windowID: windowID,
                    pid: applicationResolution.hostProcessIdentifier,
                    appName: appName,
                    title: title,
                    bounds: frame ?? CGRect(x: 0, y: 0, width: 640, height: 400),
                    isFrontmostApp: applicationResolution.hostProcessIdentifier == frontmostPID
                        || applicationResolution.windowProcessIdentifier == frontmostPID,
                    isMinimized: true,
                    canCapturePreview: false,
                    isTitleRedacted: titleDecision == .redactTitle,
                    preview: nil,
                    icon: IconNaming.named(
                        applicationResolution.hostApplication.icon,
                        bundleIdentifier: applicationResolution.hostApplication.bundleIdentifier,
                        appName: appName
                    ),
                    bundleIdentifier: applicationResolution.hostApplication.bundleIdentifier,
                    windowOwnerPID: applicationResolution.windowOwnerPID
                ))
            }
        }
        if budget.isExhausted {
            Logger.capture.notice(
                "Minimized AX scan stopped at budget apps=\(budget.scannedApplications, privacy: .public) windows=\(budget.scannedWindows, privacy: .public)"
            )
        }
        let filteredResult = HostedWindowSurfacePolicy.filteringMirroredHostedSurfaces(result)
        PerformanceDiagnostics.record(
            "minimized_window_snapshot",
            fields: [
                "count": .int(filteredResult.count),
                "frame_matches": .int(frameMatchCount),
                "redacted_titles": .int(filteredResult.filter(\.isTitleRedacted).count),
                "synthetic_ids": .int(filteredResult.filter { SyntheticWindowID.isSynthetic($0.id) }.count),
                "title_matches": .int(exactTitleMatchCount)
            ]
        )
        return filteredResult
    }

    private func shouldIncludeApplication(
        _ applicationResolution: WindowApplicationResolution,
        hiddenAppTokens: Set<HiddenAppToken>
    ) -> Bool {
        let windowApplication = applicationResolution.windowApplication
        let hostApplication = applicationResolution.hostApplication
        guard WindowEligibilityPolicy.canIncludeApplication(
            processIdentifier: hostApplication.processIdentifier,
            currentProcessIdentifier: getpid(),
            activationPolicy: hostApplication.activationPolicy,
            isFinishedLaunching: hostApplication.isFinishedLaunching
        ) else { return false }

        if [windowApplication.bundleIdentifier, hostApplication.bundleIdentifier]
            .compactMap({ $0 })
            .contains(where: excludedBundleIdentifiers.contains) {
            return false
        }

        if isHiddenByUser(
            appName: applicationResolution.appName,
            bundleIdentifier: hostApplication.bundleIdentifier,
            tokens: hiddenAppTokens
        ) {
            return false
        }

        return true
    }

    private func isHiddenByUser(
        appName: String,
        bundleIdentifier: String?,
        tokens: Set<HiddenAppToken> = HiddenAppFilterState.normalizedTokens
    ) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.contains { token in
            token.matches(appName: appName, bundleIdentifier: bundleIdentifier)
        }
    }

    private func axWindows(for appElement: AXUIElement) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard result == .success, let windows = rawValue as? [AXUIElement] else { return nil }
        return windows
    }

    private func axBool(_ attribute: String, on element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }

        return rawValue as? Bool
    }

    private func axString(_ attribute: String, on element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }

        return rawValue as? String
    }

    private func axFrame(on element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionAX, .cgPoint, &point)
        AXValueGetValue(sizeAX, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }

    // CGWindowListCreateImage is deprecated in macOS 14 but still functional.
    // Used as a last-resort fallback when both SCKit capture attempts time out
    // or fail: SCKit can be flaky on off-screen / multi-Space / recently-created
    // windows, while the legacy API often succeeds where SCKit stalls. The
    // fallback itself is UX-bounded. If the legacy API wedges, its underlying
    // work retains one global permit until it really returns, preventing later
    // batches from accumulating more than the fixed process-wide limit.
    private static func captureFallbackWithSoftTimeout(
        windowID: CGWindowID,
        maxDim: Int,
        timeoutMs: Int,
        permitPool: CapturePermitPool
    ) async -> FallbackAttemptResult {
        switch await SCContentCache.runPermitBoundOperation(
            permitPool: permitPool,
            timeoutMs: timeoutMs,
            operation: { () async -> FallbackAttemptResult in
                WindowCatalog.captureWithCGWindowList(windowID: windowID, maxDim: maxDim)
                    .map(FallbackAttemptResult.success) ?? .failed
            }
        ) {
        case .completed(let result):
            return result
        case .timedOut:
            return .timedOut
        case .resourceLimited:
            return .resourceLimited
        }
    }

    private static func captureWithCGWindowList(windowID: CGWindowID, maxDim: Int) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let scale = min(CGFloat(maxDim) / CGFloat(max(width, 1)),
                        CGFloat(maxDim) / CGFloat(max(height, 1)))
        if scale >= 1.0 {
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
        let newW = max(1, Int(CGFloat(width) * scale))
        let newH = max(1, Int(CGFloat(height) * scale))
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: newW, height: newH))
    }

}

/// Generates CGWindowID-shaped identifiers for minimized windows that
/// CGWindowList doesn't expose. The previous implementation packed (pid, title
/// hash, index) into a hand-rolled 31-bit layout with 15 bits for pid and 16
/// bits of title hash — different titles within the same app collided at
/// ~0.7% by 30 windows. This version uses Swift's `Hasher` across the full
/// (pid, index, title) tuple and keeps only the top bit (0x8000_0000)
/// reserved so synthetic IDs never collide with real CGWindowIDs.
///
/// Stable within a single launch; `Hasher`'s per-process seed means the same
/// tuple produces different IDs across launches. That's fine — real
/// CGWindowIDs aren't stable across launches either, and MRU persistence keys
/// on bundle identifier rather than window ID.
enum SyntheticWindowID {
    static let markerBit: UInt32 = 0x8000_0000

    static func make(pid: pid_t, index: Int, title: String) -> CGWindowID {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(index)
        hasher.combine(title)
        let raw = UInt32(truncatingIfNeeded: hasher.finalize())
        return markerBit | (raw & 0x7FFF_FFFF)
    }

    static func isSynthetic(_ id: CGWindowID) -> Bool {
        (id & markerBit) != 0
    }
}

/// Stable-for-launch identity for an app that is running but has no eligible
/// window row in the current scope. The `01` high-bit namespace keeps these
/// icon-only rows distinct from both real and AX-minimized window identifiers.
enum SyntheticApplicationID {
    private static let namespaceMask: UInt32 = 0xC000_0000
    private static let namespace: UInt32 = 0x4000_0000

    static func make(pid: pid_t, bundleIdentifier: String?, appName: String) -> CGWindowID {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(bundleIdentifier)
        hasher.combine(appName)
        let raw = UInt32(truncatingIfNeeded: hasher.finalize())
        return namespace | (raw & 0x3FFF_FFFF)
    }

    static func isSynthetic(_ id: CGWindowID) -> Bool {
        (id & namespaceMask) == namespace
    }
}
