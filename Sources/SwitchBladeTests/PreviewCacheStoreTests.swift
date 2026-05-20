import AppKit
@testable import SwitchBladeCore

enum PreviewCacheStoreTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PreviewCache/hydrated_returnsItem_whenNoPreviewMatch", hydrated_noMatch),
        ("PreviewCache/record_then_hydrated_returnsImage_byWindowID", roundTrip_byWindowID),
        ("PreviewCache/record_keepsOnlyLiveItems_acrossCalls", keepOnlyLive),
        ("PreviewCache/hydrated_fallsBackTo_signature_whenBoundsChange", signatureFallback),
        ("PreviewCache/hydrated_singleWindowTitleChange_fallsBackToAppIdentity", singleWindowAppIdentityFallback),
        ("PreviewCache/hydrated_multiWindowTitleChange_doesNotGuessByAppIdentity", multiWindowNoAppIdentityGuess),
        ("PreviewCache/capacity_evictsOldestSignature_too", capacityEvictsSignature),
        ("PreviewCache/staleWhileRevalidate_returnsCachedDespiteBoundsDrift", staleWhileRevalidate),
        ("PreviewCache/mostlyWhiteDetection", mostlyWhiteDetection),
        ("PreviewCache/safariBlankCapture_isRejectedWithoutExistingPreview", safariBlankCaptureIsRejectedWithoutExistingPreview),
        ("PreviewCache/safariBlankCapture_doesNotReplaceExistingPreview", safariBlankCaptureDoesNotReplaceExistingPreview),
        ("PreviewCache/blankStorm_rejectsMostlyWhiteBatch", blankStormRejectsMostlyWhiteBatch),
        ("PreviewCache/singleWhiteNonSafariCapture_isAccepted", singleWhiteNonSafariCaptureIsAccepted)
    ]

    @MainActor static func hydrated_noMatch() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1)
        let result = store.hydrated(item, liveItems: [item])
        try expectNil(result.preview)
    }

    @MainActor static func roundTrip_byWindowID() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1)
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [item])

        let result = store.hydrated(item, liveItems: [item])
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
        try expect(store.hydrated(a, liveItems: [a]).preview != nil)
        try expectNil(store.hydrated(b, liveItems: [a]).preview)
    }

    @MainActor static func signatureFallback() throws {
        let store = PreviewCacheStore()
        let original = makeItem(id: 1, pid: 100, appName: "App", title: "Doc")
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [original])

        // The window has been recreated with a new windowID (2) but same pid +
        // title; the signature path should still produce a preview.
        let respawned = makeItem(id: 2, pid: 100, appName: "App", title: "Doc")
        let result = store.hydrated(respawned, liveItems: [respawned])
        try expect(result.preview === img)
    }

    @MainActor static func singleWindowAppIdentityFallback() throws {
        let store = PreviewCacheStore()
        let original = makeItem(
            id: 1,
            pid: 200,
            appName: "Ghostty",
            title: "shell",
            bundleIdentifier: "com.mitchellh.ghostty"
        )
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [original])

        let recreated = makeItem(
            id: 20,
            pid: 200,
            appName: "Ghostty",
            title: "vim",
            bundleIdentifier: "com.mitchellh.ghostty"
        )
        let result = store.hydrated(recreated, liveItems: [recreated])
        try expect(result.preview === img)
    }

    @MainActor static func multiWindowNoAppIdentityGuess() throws {
        let store = PreviewCacheStore()
        let original = makeItem(
            id: 1,
            pid: 200,
            appName: "Ghostty",
            title: "shell",
            bundleIdentifier: "com.mitchellh.ghostty"
        )
        let img = NSImage(size: .init(width: 4, height: 4))
        store.record([1: img], liveItems: [original])

        let a = makeItem(
            id: 20,
            pid: 200,
            appName: "Ghostty",
            title: "vim A",
            bundleIdentifier: "com.mitchellh.ghostty"
        )
        let b = makeItem(
            id: 21,
            pid: 200,
            appName: "Ghostty",
            title: "vim B",
            bundleIdentifier: "com.mitchellh.ghostty"
        )
        let liveItems = [a, b]
        try expectNil(store.hydrated(a, liveItems: liveItems).preview)
        try expectNil(store.hydrated(b, liveItems: liveItems).preview)
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
        let result = store.hydrated(resized, liveItems: [resized])
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
        try expectNil(store.hydrated(a, liveItems: [a, b, c]).preview)
        try expect(store.hydrated(b, liveItems: [a, b, c]).preview != nil)
        try expect(store.hydrated(c, liveItems: [a, b, c]).preview != nil)
    }

    @MainActor static func mostlyWhiteDetection() throws {
        try expect(PreviewCacheStore.isMostlyWhite(solidImage(color: .white)))
        try expect(!PreviewCacheStore.isMostlyWhite(solidImage(color: .black)))
        try expect(!PreviewCacheStore.isMostlyWhite(solidImage(color: .systemBlue)))
    }

    @MainActor static func safariBlankCaptureDoesNotReplaceExistingPreview() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari")
        let good = solidImage(color: .systemBlue)
        let blank = solidImage(color: .white)

        let firstAccepted = store.record([1: good], liveItems: [item])
        try expect(firstAccepted[1] === good)

        let secondAccepted = store.record([1: blank], liveItems: [item])
        try expectNil(secondAccepted[1])
        try expect(store.hydrated(item, liveItems: [item]).preview === good)
    }

    @MainActor static func safariBlankCaptureIsRejectedWithoutExistingPreview() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari")
        let blank = solidImage(color: .white)

        let accepted = store.record([1: blank], liveItems: [item])

        try expectNil(accepted[1])
        try expectNil(store.hydrated(item, liveItems: [item]).preview)
    }

    @MainActor static func blankStormRejectsMostlyWhiteBatch() throws {
        let store = PreviewCacheStore()
        let a = makeItem(id: 1, appName: "Notes", bundleIdentifier: "com.apple.Notes")
        let b = makeItem(id: 2, appName: "Finder", bundleIdentifier: "com.apple.finder")
        let c = makeItem(id: 3, appName: "Mail", bundleIdentifier: "com.apple.mail")

        let accepted = store.record(
            [
                1: solidImage(color: .white),
                2: solidImage(color: .white),
                3: solidImage(color: .white)
            ],
            liveItems: [a, b, c]
        )

        try expect(accepted.isEmpty)
        try expectNil(store.hydrated(a, liveItems: [a, b, c]).preview)
        try expectNil(store.hydrated(b, liveItems: [a, b, c]).preview)
        try expectNil(store.hydrated(c, liveItems: [a, b, c]).preview)
    }

    @MainActor static func singleWhiteNonSafariCaptureIsAccepted() throws {
        let store = PreviewCacheStore()
        let item = makeItem(id: 1, appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        let blank = solidImage(color: .white)

        let accepted = store.record([1: blank], liveItems: [item])

        try expect(accepted[1] === blank)
        try expect(store.hydrated(item, liveItems: [item]).preview === blank)
    }

    private static func solidImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return image
    }
}
