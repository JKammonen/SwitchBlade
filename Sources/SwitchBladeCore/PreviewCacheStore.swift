import AppKit
import CoreGraphics

/// Two-level preview cache:
/// 1. Primary key — CGWindowID. Hits when the window is still alive and its
///    bounds haven't drifted from the cached snapshot.
/// 2. Fallback key — "pid::displayTitle" signature. Hits when the windowID
///    changed (window recreated, e.g. after a doc reload) but the same
///    process is still showing the same title; bounds may differ.
///
/// Kept off SwitcherStore so the storage logic can be reasoned about in
/// isolation; the store just feeds it the live items + fresh captures and
/// reads back hydrated items.
@MainActor
final class PreviewCacheStore {
    private var byID: LRUDictionary<CGWindowID, CachedPreview>
    private var bySignature: LRUDictionary<String, CachedPreview>

    init(capacity: Int = 40) {
        byID = LRUDictionary(capacity: capacity)
        bySignature = LRUDictionary(capacity: capacity)
    }

    struct CachedPreview {
        let image: NSImage
        let bounds: CGRect
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
    func hydrated(_ item: WindowItem) -> WindowItem {
        if let cached = byID[item.windowID] {
            return item.withPreview(cached.image)
        }
        if let cached = bySignature[signature(for: item)] {
            return item.withPreview(cached.image)
        }
        return item
    }

    /// Records fresh previews and prunes anything not in `liveItems`. The prune
    /// step is what keeps the cache from growing past `capacity` even when an
    /// app spawns many short-lived windows.
    func record(_ previews: [CGWindowID: NSImage], liveItems: [WindowItem]) {
        guard !previews.isEmpty else {
            keepOnlyLive(liveItems)
            return
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: liveItems.map { ($0.windowID, $0) })
        for (windowID, image) in previews {
            guard let item = itemsByID[windowID] else { continue }
            let cached = CachedPreview(image: image, bounds: item.bounds)
            byID[windowID] = cached
            bySignature[signature(for: item)] = cached
        }
        keepOnlyLive(liveItems)
    }

    private func keepOnlyLive(_ items: [WindowItem]) {
        byID.keepOnly(Set(items.map(\.windowID)))
        bySignature.keepOnly(Set(items.map(signature(for:))))
    }

    private func signature(for item: WindowItem) -> String {
        "\(item.pid)::\(item.displayTitle)"
    }
}
