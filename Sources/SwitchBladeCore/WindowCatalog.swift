import AppKit
import ApplicationServices
import CoreGraphics
import os.log
@preconcurrency import ScreenCaptureKit

// Cache for SCShareableContent. Three refresh paths:
//   1. Launch warmup once Screen Recording has been granted.
//   2. End-of-cycle refresh via `refreshContentCache()` so the next Cmd+Tab
//      starts fresh.
//   3. Hot-path refresh via `refreshIfStale()` inside `capturePreviews` when
//      the cache is older than `staleThreshold` seconds.
// Never polled — ScreenCaptureKit can surface a macOS permission dialog when
// touched repeatedly in an unsettled TCC state.
actor SCContentCache {
    private(set) var content: SCShareableContent?
    private(set) var lastRefreshFailedAt: Date?
    private(set) var lastSuccessfulRefresh: Date?

    /// Stale cache leads to slow first captures after idle: the cached SCWindow
    /// refs lose their warm capture-pipeline link, and SCScreenshotManager has
    /// to re-resolve each one. Below this age the cache is reused as-is.
    ///
    /// 5 s is tight enough that "a few seconds of idle" still gets a fresh
    /// fetch; SwitcherStore also triggers opportunistic refreshes on every
    /// NSWorkspace app activation, so this threshold is mostly the safety net.
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
            Logger.capture.error("SCShareableContent refresh failed: \(error.localizedDescription, privacy: .public)")
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

    /// Refreshes inline only when there is no cached content to use, respecting
    /// the failure cooldown. Stale-but-present content is still useful on the
    /// Cmd+Tab hot path; callers can refresh it in the background.
    func refreshIfMissing() async {
        if content == nil {
            guard shouldRetryAfterFailure() else { return }
            await refreshIfAllowed()
        }
    }

    func refreshIfStale() async {
        if content == nil || isStale() {
            guard shouldRetryAfterFailure() else { return }
            await refreshIfAllowed()
        }
    }

    func shouldRefreshStaleContentInBackground() -> Bool {
        content != nil && isStale() && shouldRetryAfterFailure()
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
    }

    /// Captures the window or stops waiting after `timeoutMs`.
    ///
    /// Important: this is a UX timeout, not a hard resource kill. We cancel our
    /// Swift Task and return `.timedOut` to the caller promptly, but if
    /// ScreenCaptureKit is blocked inside `captureImage`, that framework work
    /// may continue until Apple's API returns or notices cancellation.
    static func captureWithSoftTimeout(window: SCWindow, maxDim: Int, timeoutMs: Int) async -> CaptureAttemptResult {
        nonisolated(unsafe) let capturedWindow = window
        let captureTask = Task.detached(priority: .userInitiated) { () -> CaptureAttemptResult in
            do {
                return .success(try await SCContentCache.capture(window: capturedWindow, maxDim: maxDim))
            } catch {
                return .failed
            }
        }

        return await withCheckedContinuation { continuation in
            let box = OneShotContinuation(continuation)

            Task {
                let result = await captureTask.value
                box.resume(returning: result)
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                captureTask.cancel()
                box.resume(returning: .timedOut)
            }
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

private struct WindowCaptureOutcome {
    let windowID: CGWindowID
    let image: NSImage?
    let firstAttempt: SCContentCache.CaptureAttemptResult
    let secondAttempt: SCContentCache.CaptureAttemptResult?
}

enum WindowSharingPolicy {
    static func canListWindow(appName: String, bundleIdentifier: String?, title: String, sharingState: Int) -> Bool {
        if isMicrosoftTeams(appName: appName, bundleIdentifier: bundleIdentifier),
           title.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("sharing indicator") {
            return false
        }

        guard sharingState == 0 else { return true }
        return isMicrosoftTeams(appName: appName, bundleIdentifier: bundleIdentifier)
    }

    private static func isMicrosoftTeams(appName: String, bundleIdentifier: String?) -> Bool {
        let normalizedName = appName.lowercased()
        let normalizedBundle = (bundleIdentifier ?? "").lowercased()
        return normalizedName.contains("teams")
            && normalizedBundle.hasPrefix("com.microsoft.teams")
    }
}

final class WindowCatalog: WindowSnapshotProviding, Sendable {
    private let excludedBundleIdentifiers: Set<String> = [
        "com.apple.PasswordsUIAgent",
        "com.apple.PasskeysUIService",
        "com.apple.Safari.PasswordBreachAgent"
    ]

    private let contentCache = SCContentCache()

    init() {}

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

    /// Fast path used on the Cmd+Tab critical path. Skips the AX walk for
    /// minimized windows entirely; merge those in lazily via `snapshotMinimized`.
    func snapshotVisibleOnly() -> [WindowItem] {
        snapshotInternal(includeMinimized: false).visible
    }

    /// Returns minimized windows from an AX walk. ~150–500ms with many running
    /// apps — call from a background task and merge into items after the panel
    /// is already on screen. Safe to call AX read APIs off the main thread.
    func snapshotMinimized() async -> [WindowItem] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return minimizedItems(excluding: Set(), frontmostPID: frontmostPID)
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
        var visibleWindowIDs = Set<CGWindowID>()

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
            if windowScope == .currentApp, ownerPID != frontmostPID {
                return nil
            }
            visibleWindowIDs.insert(windowID)

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
            let application = NSRunningApplication(processIdentifier: ownerPID)
            let sharingState = entry[kCGWindowSharingState as String] as? Int ?? 0

            guard shouldIncludeWindow(
                appName: appName,
                application: application,
                title: title,
                sharingState: sharingState
            ) else {
                return nil
            }

            return WindowItem(
                windowID: windowID,
                pid: ownerPID,
                appName: appName,
                title: title,
                bounds: bounds,
                isFrontmostApp: ownerPID == frontmostPID,
                isMinimized: false,
                canCapturePreview: sharingState != 0,
                preview: nil,
                icon: application?.icon,
                bundleIdentifier: application?.bundleIdentifier
            )
        }

        let minimized = includeMinimized
            ? minimizedItems(excluding: visibleWindowIDs, frontmostPID: frontmostPID)
            : []
        return SnapshotResult(visible: visibleItems, minimized: minimized)
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int?,
        maxConcurrentCaptures: Int
    ) async -> [CGWindowID: NSImage] {
        // Single preflight syscall instead of currentState() which does three.
        guard CGPreflightScreenCaptureAccess() else { return [:] }

        // Missing content must block; stale-but-present content is used
        // immediately and refreshed in the background so Cmd+Tab doesn't pay
        // an inline SCShareableContent.current call after short idle gaps.
        await contentCache.refreshIfMissing()
        guard let content = await contentCache.content else {
            Logger.capture.error("capturePreviews: no SCShareableContent available")
            return [:]
        }
        if await contentCache.shouldRefreshStaleContentInBackground() {
            Task.detached(priority: .utility) { [contentCache] in
                await contentCache.refreshIfAllowed()
            }
        }
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let maxDim = 320
        let requestedIDs = maxCount.map { Array(windowIDs.prefix($0)) } ?? windowIDs
        let captureTargets = requestedIDs.compactMap { windowID -> (CGWindowID, SCWindow)? in
            guard let window = windowsByID[windowID] else { return nil }
            return (windowID, window)
        }
        guard !captureTargets.isEmpty else {
            Logger.capture.notice("capturePreviews: no matching SCWindows for \(windowIDs.count, privacy: .public) requested IDs")
            return [:]
        }
        let captureStart = Date()

        return await withTaskGroup(of: WindowCaptureOutcome.self) { group in
            var nextIndex = 0
            var firstAttemptTimeouts = 0
            var firstAttemptFailures = 0
            var secondAttemptTimeouts = 0
            var secondAttemptFailures = 0

            func enqueueNextCapture() -> Bool {
                guard nextIndex < captureTargets.count else { return false }
                let (windowID, window) = captureTargets[nextIndex]
                nextIndex += 1
                nonisolated(unsafe) let capturedWindow = window
                group.addTask {
                    // First attempt — usually succeeds, but SCKit's first call
                    // after a few seconds idle can fail silently while the
                    // capture pipeline warms up. Both attempts are bounded by a
                    // 300 ms UX timeout so one slow preview doesn't block the
                    // caller, though the underlying SCKit work may outlive it.
                    let first = await SCContentCache.captureWithSoftTimeout(
                        window: capturedWindow, maxDim: maxDim, timeoutMs: 300
                    )
                    if case .success(let image) = first {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: image,
                            firstAttempt: first,
                            secondAttempt: nil
                        )
                    }
                    Logger.capture.notice(
                        "First capture failed/timed out for windowID=\(windowID, privacy: .public) — retrying"
                    )
                    let second = await SCContentCache.captureWithSoftTimeout(
                        window: capturedWindow, maxDim: maxDim, timeoutMs: 300
                    )
                    if case .success(let image) = second {
                        return WindowCaptureOutcome(
                            windowID: windowID,
                            image: image,
                            firstAttempt: first,
                            secondAttempt: second
                        )
                    }
                    Logger.capture.error(
                        "Both capture attempts failed for windowID=\(windowID, privacy: .public)"
                    )
                    return WindowCaptureOutcome(
                        windowID: windowID,
                        image: nil,
                        firstAttempt: first,
                        secondAttempt: second
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
                }

                if let secondAttempt = captureResult.secondAttempt {
                    switch secondAttempt {
                    case .success:
                        break
                    case .failed:
                        secondAttemptFailures += 1
                    case .timedOut:
                        secondAttemptTimeouts += 1
                    }
                }

                if let image = captureResult.image {
                    result[captureResult.windowID] = image
                }
                _ = enqueueNextCapture()
            }

            let ms = Date().timeIntervalSince(captureStart) * 1000
            if PerformanceLoggingState.mode == .debug {
                Logger.capture.info(
                    "Captured \(result.count, privacy: .public)/\(captureTargets.count, privacy: .public) previews in \(ms, format: .fixed(precision: 1), privacy: .public) ms; firstTimeouts=\(firstAttemptTimeouts, privacy: .public), firstFailures=\(firstAttemptFailures, privacy: .public), secondTimeouts=\(secondAttemptTimeouts, privacy: .public), secondFailures=\(secondAttemptFailures, privacy: .public)"
                )
            }
            return result
        }
    }

    private func shouldIncludeWindow(
        appName: String,
        application: NSRunningApplication?,
        title: String,
        sharingState: Int
    ) -> Bool {
        // sharingState == kCGWindowSharingNone (0) means macOS may refuse to
        // capture a preview for the window. Most such windows are privacy /
        // DRM / autofill surfaces and should stay hidden. Microsoft Teams is
        // the important exception: real meeting/chat windows can use this
        // sharing state, and switching to them is more important than showing
        // a live preview. Those tiles fall back to the app-icon treatment.
        guard let application,
              application.isFinishedLaunching else {
            return false
        }
        guard WindowSharingPolicy.canListWindow(
            appName: appName,
            bundleIdentifier: application.bundleIdentifier,
            title: title,
            sharingState: sharingState
        ) else {
            return false
        }
        // Allow .regular apps and also our own .accessory process (settings window etc.)
        let isRegular = application.activationPolicy == .regular
        let isOwnProcess = application.processIdentifier == getpid()
        guard isRegular || isOwnProcess else {
            return false
        }

        if let bundleIdentifier = application.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }

        if isHiddenByUser(appName: appName, bundleIdentifier: application.bundleIdentifier) {
            return false
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty,
           appName.localizedCaseInsensitiveContains("autofill") {
            return false
        }

        return true
    }

    private func minimizedItems(excluding visibleWindowIDs: Set<CGWindowID>, frontmostPID: pid_t?) -> [WindowItem] {
        // Soft bound on AX IPC. Per Apple's AXUIElement header, a timeout set
        // on a specific element only governs calls to *that* element — it does
        // not propagate to children — so we set it on the app element (for
        // axWindows) and again on each window element (for axBool/axString/
        // axFrame). Already-in-flight AX calls keep running until the
        // framework returns; this only bounds new IPC, same as the
        // capture soft-timeout pattern.
        let axTimeoutSeconds: Float = 0.25
        var result: [WindowItem] = []
        for application in NSWorkspace.shared.runningApplications {
            // Bypass the rest of the sweep if the merge consumer already lost
            // interest (panel hidden, generation bumped). Won't unstick an
            // already-blocked AX call; only stops *new* per-app iterations.
            if Task.isCancelled { break }
            guard shouldIncludeApplication(application) else { continue }
            if WindowFilterState.scope == .currentApp,
               application.processIdentifier != frontmostPID {
                continue
            }

            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            _ = AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
            guard let windows = axWindows(for: appElement) else { continue }

            let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
            for (index, window) in windows.enumerated() {
                _ = AXUIElementSetMessagingTimeout(window, axTimeoutSeconds)
                guard axBool(kAXMinimizedAttribute, on: window) == true else { continue }

                let title = axString(kAXTitleAttribute, on: window) ?? ""
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }

                let syntheticID = syntheticWindowID(pid: application.processIdentifier, index: index, title: title)
                guard !visibleWindowIDs.contains(syntheticID) else { continue }

                result.append(WindowItem(
                    windowID: syntheticID,
                    pid: application.processIdentifier,
                    appName: appName,
                    title: title,
                    bounds: axFrame(on: window) ?? CGRect(x: 0, y: 0, width: 640, height: 400),
                    isFrontmostApp: application.processIdentifier == frontmostPID,
                    isMinimized: true,
                    canCapturePreview: false,
                    preview: nil,
                    icon: application.icon,
                    bundleIdentifier: application.bundleIdentifier
                ))
            }
        }
        return result
    }

    private func shouldIncludeApplication(_ application: NSRunningApplication) -> Bool {
        guard application.isFinishedLaunching else { return false }

        let isRegular = application.activationPolicy == .regular
        let isOwnProcess = application.processIdentifier == getpid()
        guard isRegular || isOwnProcess else { return false }

        if let bundleIdentifier = application.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }

        if isHiddenByUser(
            appName: application.localizedName ?? application.bundleIdentifier ?? "",
            bundleIdentifier: application.bundleIdentifier
        ) {
            return false
        }

        return true
    }

    private func isHiddenByUser(appName: String, bundleIdentifier: String?) -> Bool {
        let tokens = HiddenAppFilterState.normalizedTokens
        guard !tokens.isEmpty else { return false }
        let app = appName.lowercased()
        let bundle = (bundleIdentifier ?? "").lowercased()
        return tokens.contains { token in
            app.contains(token) || bundle.contains(token)
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

    private func syntheticWindowID(pid: pid_t, index: Int, title: String) -> CGWindowID {
        var hash = UInt32(bitPattern: Int32(pid)) & 0x7FFF
        for scalar in title.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return 0x8000_0000 | ((UInt32(bitPattern: Int32(pid)) & 0x7FFF) << 16) | ((hash &+ UInt32(index)) & 0xFFFF)
    }
}
