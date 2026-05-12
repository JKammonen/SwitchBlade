import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

// Cache for SCShareableContent. It is warmed once and refreshed on demand, not
// polled continuously, because ScreenCaptureKit may surface macOS permission
// dialogs when touched repeatedly in an unsettled TCC state.
actor SCContentCache {
    private(set) var content: SCShareableContent?
    private(set) var lastRefreshFailedAt: Date?

    func refreshIfAllowed() async {
        // Guard: SCKit can trigger an OS permission dialog without Screen Recording access.
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            content = try await SCShareableContent.current
            lastRefreshFailedAt = nil
        } catch {
            lastRefreshFailedAt = Date()
        }
    }

    func shouldRetryAfterFailure() -> Bool {
        guard let lastRefreshFailedAt else { return true }
        return Date().timeIntervalSince(lastRefreshFailedAt) > 60
    }

    static func capture(window: SCWindow, maxDim: Int) async throws -> NSImage? {
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
}

final class WindowCatalog: Sendable {
    private let excludedBundleIdentifiers: Set<String> = [
        "com.apple.PasswordsUIAgent",
        "com.apple.PasskeysUIService",
        "com.apple.Safari.PasswordBreachAgent"
    ]

    private let permissionService: PermissionService
    private let contentCache = SCContentCache()

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    /// Call once at launch. Warms SCShareableContent without polling it forever.
    func startBackgroundRefresh() {
        Task.detached(priority: .utility) { [contentCache] in
            await contentCache.refreshIfAllowed()
        }
    }

    func snapshot() -> [WindowItem] {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
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

            // Only include windows that are part of the on-screen window stack.
            // This filters ghost CGWindows, background helper surfaces, etc.
            let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            guard isOnScreen else {
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
                preview: nil,
                icon: application?.icon
            )
        }

        return visibleItems + minimizedItems(excluding: visibleWindowIDs, frontmostPID: frontmostPID)
    }

    func capturePreviews(
        for windowIDs: [CGWindowID],
        maxCount: Int? = nil,
        maxConcurrentCaptures: Int = 3
    ) async -> [CGWindowID: NSImage] {
        guard !permissionService.currentState().needsScreenRecording else { return [:] }

        // Use warm cached SCShareableContent — avoids slow SCShareableContent.current on hot path.
        let cachedContent = await contentCache.content
        let content: SCShareableContent
        if let c = cachedContent {
            content = c
        } else {
            guard await contentCache.shouldRetryAfterFailure(),
                  CGPreflightScreenCaptureAccess() else {
                return [:]
            }
            await contentCache.refreshIfAllowed()
            guard let fresh = await contentCache.content else { return [:] }
            content = fresh
        }
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let maxDim = 320
        let requestedIDs = maxCount.map { Array(windowIDs.prefix($0)) } ?? windowIDs
        let captureTargets = requestedIDs.compactMap { windowID -> (CGWindowID, SCWindow)? in
            guard let window = windowsByID[windowID] else { return nil }
            return (windowID, window)
        }
        guard !captureTargets.isEmpty else { return [:] }

        return await withTaskGroup(of: (CGWindowID, NSImage)?.self) { group in
            var nextIndex = 0

            func enqueueNextCapture() -> Bool {
                guard nextIndex < captureTargets.count else { return false }
                let (windowID, window) = captureTargets[nextIndex]
                nextIndex += 1
                nonisolated(unsafe) let capturedWindow = window
                group.addTask {
                    guard let image = try? await SCContentCache.capture(window: capturedWindow, maxDim: maxDim) else { return nil }
                    return (windowID, image)
                }

                return true
            }

            let initialCaptureCount = min(max(1, maxConcurrentCaptures), captureTargets.count)
            for _ in 0 ..< initialCaptureCount {
                _ = enqueueNextCapture()
            }

            var result: [CGWindowID: NSImage] = [:]
            for await captureResult in group {
                if let (windowID, image) = captureResult {
                    result[windowID] = image
                }
                _ = enqueueNextCapture()
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
        guard sharingState != 0,
              let application,
              application.isFinishedLaunching else {
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

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty,
           appName.localizedCaseInsensitiveContains("autofill") {
            return false
        }

        return true
    }

    private func minimizedItems(excluding visibleWindowIDs: Set<CGWindowID>, frontmostPID: pid_t?) -> [WindowItem] {
        NSWorkspace.shared.runningApplications.flatMap { application -> [WindowItem] in
            guard shouldIncludeApplication(application) else { return [] }

            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            guard let windows = axWindows(for: appElement) else { return [] }

            let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
            return windows.enumerated().compactMap { index, window in
                guard axBool(kAXMinimizedAttribute, on: window) == true else { return nil }

                let title = axString(kAXTitleAttribute, on: window) ?? ""
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }

                let syntheticID = syntheticWindowID(pid: application.processIdentifier, index: index, title: title)
                guard !visibleWindowIDs.contains(syntheticID) else { return nil }

                return WindowItem(
                    windowID: syntheticID,
                    pid: application.processIdentifier,
                    appName: appName,
                    title: title,
                    bounds: axFrame(on: window) ?? CGRect(x: 0, y: 0, width: 640, height: 400),
                    isFrontmostApp: application.processIdentifier == frontmostPID,
                    isMinimized: true,
                    preview: nil,
                    icon: application.icon
                )
            }
        }
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

        return true
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
