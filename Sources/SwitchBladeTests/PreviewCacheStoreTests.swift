import AppKit
@testable import SwitchBladeCore

enum PreviewCacheStoreTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PreviewCache/hydrated_returnsItem_whenNoPreviewMatch", hydrated_noMatch),
        ("PreviewCache/record_then_hydrated_returnsImage_byWindowID", roundTrip_byWindowID),
        ("PreviewCache/record_keepsOnlyLiveItems_acrossCalls", keepOnlyLive),
        ("PreviewCache/hydrated_fallsBackTo_signature_whenBoundsChange", signatureFallback),
        ("PreviewCache/capacity_evictsOldestSignature_too", capacityEvictsSignature),
        ("PreviewCache/staleWhileRevalidate_returnsCachedDespiteBoundsDrift", staleWhileRevalidate)
    ]

    @MainActor static func hydrated_noMatch() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1)
        let result = store.hydrated(item)
        try expectNil(result.preview)
    }

    @MainActor static func roundTrip_byWindowID() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1)
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [item])

        let result = store.hydrated(item)
        try expect(result.preview === img)
    }

    @MainActor static func keepOnlyLive() throws {
        let store = PreviewCacheStore()
        // Distinct signatures (pid + title) so the signature fallback doesn't
        // hand A's preview to B after B is pruned.
        let a = makeItem(id: 1, pid: 100, title: "A")
        let b = makeItem(id: 2, pid: 200, title: "B")
        store.record([1: NSImage(), 2: NSImage()], liveItems: [a, b])

        // Second pass — only `a` is live; both caches should drop `b`.
        store.record([:], liveItems: [a])
        try expect(store.hydrated(a).preview != nil)
        try expectNil(store.hydrated(b).preview)
    }

    @MainActor static func signatureFallback() throws {
        let store = PreviewCacheStore()
        let original = makeItem(id: 1, pid: 100, appName: "App", title: "Doc")
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [original])

        // The window has been recreated with a new windowID (2) but same pid +
        // title; the signature path should still produce a preview.
        let respawned = makeItem(id: 2, pid: 100, appName: "App", title: "Doc")
        let result = store.hydrated(respawned)
        try expect(result.preview === img)
    }

    /// User resizes a window: same windowID, different bounds. The cache still
    /// hands back the previously-captured image so the tile has *something* to
    /// show while a fresh capture is in flight (replaces it on landing).
    @MainActor static func staleWhileRevalidate() throws {
        let store = PreviewCacheStore()
        let original = makeItem(id: 1, bounds: .init(x: 0, y: 0, width: 800, height: 600))
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [original])

        // Same windowID, but the window has been resized.
        let resized = makeItem(id: 1, bounds: .init(x: 0, y: 0, width: 1200, height: 900))
        let result = store.hydrated(resized)
        try expect(result.preview === img, "expected stale image despite bounds drift")
    }

    @MainActor static func capacityEvictsSignature() throws {
        // Tiny capacity makes the test cheap and obvious.
        let store = PreviewCacheStore(capacity: 2)
        let a = makeItem(id: 1, pid: 1, title: "A")
        let b = makeItem(id: 2, pid: 2, title: "B")
        let c = makeItem(id: 3, pid: 3, title: "C")
        store.record([1: NSImage()], liveItems: [a, b, c])
        store.record([2: NSImage()], liveItems: [a, b, c])
        store.record([3: NSImage()], liveItems: [a, b, c])
        // capacity 2 — `a` should be evicted from both caches.
        try expectNil(store.hydrated(a).preview)
        try expect(store.hydrated(b).preview != nil)
        try expect(store.hydrated(c).preview != nil)
    }
}
