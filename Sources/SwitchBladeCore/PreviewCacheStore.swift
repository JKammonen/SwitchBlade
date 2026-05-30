import AppKit
import CoreGraphics

/// Multi-key preview cache:
/// 1. Primary key — CGWindowID. Hits when the window is still alive and its
///    bounds haven't drifted from the cached snapshot.
/// 2. Fallback key — "pid::displayTitle" signature. Hits when the windowID
///    changed (window recreated, e.g. after a doc reload) but the same
///    process is still showing the same title; bounds may differ.
/// 3. Narrow app-identity fallback. If an app currently has exactly one live
///    window, a recreated window can reuse that app's last preview even when
///    both ID and title changed.
/// 4. Retained exact signature for minimized AX rows. Visible-only snapshots
///    prune normal live keys once a window is minimized, but a recent
///    pid+bundle/title match can still safely show the last real preview.
///
/// Kept off SwitcherStore so the storage logic can be reasoned about in
/// isolation; the store just feeds it the live items + fresh captures and
/// reads back hydrated items.
@MainActor
final class PreviewCacheStore {
    private var byID: LRUDictionary<CGWindowID, CachedPreview>
    private var bySignature: LRUDictionary<String, CachedPreview>
    private var byAppIdentity: LRUDictionary<String, CachedPreview>
    private var byRecentlySeenSignature: LRUDictionary<String, CachedPreview>
    private let retainedPreviewMaxAge: TimeInterval
    private let now: () -> Date

    init(
        capacity: Int = 40,
        retainedPreviewMaxAge: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        byID = LRUDictionary(capacity: capacity)
        bySignature = LRUDictionary(capacity: capacity)
        byAppIdentity = LRUDictionary(capacity: capacity)
        byRecentlySeenSignature = LRUDictionary(capacity: capacity)
        self.retainedPreviewMaxAge = retainedPreviewMaxAge
        self.now = now
    }

    struct CachedPreview {
        let image: NSImage
        let bounds: CGRect
        let capturedAt: Date
    }

    /// Returns a hydrated copy of `item` if we have any usable preview,
    /// otherwise the item unchanged.
    ///
    /// Stale-while-revalidate: a windowID hit returns its cached image even
    /// when bounds drifted (user resized the window). The fresh capture is
    /// still in flight and will replace this preview when it lands. The user
    /// sees an instant, slightly off-aspect preview instead of a blank tile
    /// for ~100 ms. Window IDs are stable for the lifetime of the window in
    /// macOS, so there's no risk of showing the wrong window's image.
    func hydrated(_ item: WindowItem, liveItems: [WindowItem]) -> WindowItem {
        if let cached = byID[item.windowID] {
            return item.withPreview(cached.image)
        }
        let itemSignature = signature(for: item)
        if liveItems.filter({ signature(for: $0) == itemSignature }).count == 1,
           let cached = bySignature[itemSignature] {
            return item.withPreview(cached.image)
        }
        let exactSignature = recentSignature(for: item)
        if item.isMinimized,
           liveItems.filter({ recentSignature(for: $0) == exactSignature }).count == 1,
           let cached = byRecentlySeenSignature[exactSignature],
           isFreshEnough(cached) {
            return item.withPreview(cached.image)
        }
        let identity = appIdentity(for: item)
        if liveItems.filter({ appIdentity(for: $0) == identity }).count == 1,
           let cached = byAppIdentity[identity] {
            return item.withPreview(cached.image)
        }
        return item
    }

    /// Records fresh previews and prunes anything not in `liveItems`. Returns
    /// the accepted previews so callers don't immediately paint captures we
    /// intentionally rejected.
    ///
    /// The prune step is what keeps the cache from growing past `capacity`
    /// even when an app spawns many short-lived windows.
    @discardableResult
    func record(_ previews: [CGWindowID: NSImage], liveItems: [WindowItem]) -> [CGWindowID: NSImage] {
        guard !previews.isEmpty else {
            keepOnlyLive(liveItems)
            return [:]
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: liveItems.map { ($0.windowID, $0) })
        let singleWindowAppIdentities = Self.singleWindowAppIdentities(in: liveItems, appIdentity: appIdentity(for:))
        var accepted: [CGWindowID: NSImage] = [:]
        for (windowID, image) in previews {
            guard let item = itemsByID[windowID] else { continue }
            if shouldRejectTransientBlankCapture(image) {
                continue
            }
            let cached = CachedPreview(image: image, bounds: item.bounds, capturedAt: now())
            byID[windowID] = cached
            bySignature[signature(for: item)] = cached
            byRecentlySeenSignature[recentSignature(for: item)] = cached
            if singleWindowAppIdentities.contains(appIdentity(for: item)) {
                byAppIdentity[appIdentity(for: item)] = cached
            }
            accepted[windowID] = image
        }
        keepOnlyLive(liveItems)
        return accepted
    }

    private func keepOnlyLive(_ items: [WindowItem]) {
        byID.keepOnly(Set(items.map(\.windowID)))
        bySignature.keepOnly(Set(items.map(signature(for:))))
        byAppIdentity.keepOnly(Self.singleWindowAppIdentities(in: items, appIdentity: appIdentity(for:)))
    }

    private func signature(for item: WindowItem) -> String {
        "\(item.pid)::\(item.displayTitle)"
    }

    private func recentSignature(for item: WindowItem) -> String {
        "\(item.pid)::\(appIdentity(for: item))::\(item.displayTitle)"
    }

    private func appIdentity(for item: WindowItem) -> String {
        item.bundleIdentifier ?? item.appName
    }

    private func isFreshEnough(_ cached: CachedPreview) -> Bool {
        now().timeIntervalSince(cached.capturedAt) <= retainedPreviewMaxAge
    }

    private func shouldRejectTransientBlankCapture(_ image: NSImage) -> Bool {
        guard Self.isMostlyWhite(image) else {
            return false
        }
        return true
    }

    static func isMostlyWhite(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var opaqueSamples = 0
        var whiteSamples = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[index + 3]
            guard alpha > 245 else { continue }
            opaqueSamples += 1
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            if red > 246, green > 246, blue > 246 {
                whiteSamples += 1
            }
        }

        guard opaqueSamples > 0 else { return false }
        return Double(whiteSamples) / Double(opaqueSamples) > 0.97
    }

    private static func singleWindowAppIdentities(
        in items: [WindowItem],
        appIdentity: (WindowItem) -> String
    ) -> Set<String> {
        Set(
            Dictionary(grouping: items, by: appIdentity)
                .filter { $0.value.count == 1 }
                .map(\.key)
        )
    }
}
