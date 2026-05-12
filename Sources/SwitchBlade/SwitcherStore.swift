import Carbon.HIToolbox
import Foundation
import SwiftUI

@MainActor
final class SwitcherStore: ObservableObject {
    @Published private(set) var items: [WindowItem] = []
    @Published private(set) var isVisible = false
    @Published private(set) var permissionState: PermissionState
    @Published var selectedID: WindowItem.ID?

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    /// True from the moment the first Cmd+Tab fires until the panel is hidden.
    /// Used so Command-release is detected even when the async show is still in flight.
    private(set) var isSwitching = false

    private let catalog: WindowCatalog
    private let activator: WindowActivator
    private let permissionService: PermissionService
    private var previewLoadTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var recentWindowIDs: [WindowItem.ID] = []
    private var previewCache: [CGWindowID: CachedPreview] = [:]
    private var previewCacheOrder: [CGWindowID] = []
    private var previewCacheBySignature: [String: CachedPreview] = [:]
    private var previewCacheBySignatureOrder: [String] = []
    private let maxCachedPreviews = 40
    /// Prevents the tile under the mouse from stealing selection when the panel first appears.
    private var hoverEnabled = false

    private struct CachedPreview {
        let image: NSImage
        let bounds: CGRect
    }

    init(catalog: WindowCatalog, activator: WindowActivator, permissionService: PermissionService) {
        self.catalog = catalog
        self.activator = activator
        self.permissionService = permissionService
        self.permissionState = permissionService.currentState()
    }

    func refreshPermissionState() {
        permissionState = permissionService.currentState()
    }

    func cycle(forward: Bool) {
        permissionState = permissionService.currentState()

        if !isVisible {
            isSwitching = true
            previewLoadTask?.cancel()
            let snapshot = catalog.snapshot()
            let orderedItems = orderedItemsForDisplay(from: snapshot)
            guard !orderedItems.isEmpty else {
                isSwitching = false
                return
            }

            items = orderedItems.map(itemWithCachedPreview)
            selectedID = items[safe: items.count > 1 ? 1 : 0]?.id
            showWithPreviews()
            return
        }

        moveSelection(forward ? 1 : -1)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else {
            return false
        }

        switch Int(event.keyCode) {
        case Int(kVK_Tab):
            moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case Int(kVK_RightArrow), Int(kVK_DownArrow):
            moveSelection(1)
            return true
        case Int(kVK_LeftArrow), Int(kVK_UpArrow):
            moveSelection(-1)
            return true
        case Int(kVK_Return), Int(kVK_Space):
            commitSelection()
            return true
        case Int(kVK_Escape):
            cancel()
            return true
        default:
            return false
        }
    }

    func hover(_ item: WindowItem) {
        guard hoverEnabled else { return }
        selectedID = item.id
    }

    func choose(_ item: WindowItem) {
        selectedID = item.id
        commitSelection()
    }

    func close(_ item: WindowItem) {
        activator.close(item)
        removeItem(withID: item.id)
    }

    func commitSelection() {
        guard let item = selectedItem else {
            cancel()
            return
        }

        rememberRecentSelection(item.id)
        hide()
        activator.activate(item)
    }

    func cancel() {
        hide()
    }

    private var selectedItem: WindowItem? {
        items.first(where: { $0.id == selectedID })
    }

    private func hide() {
        previewGeneration += 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        isVisible = false
        isSwitching = false
        hoverEnabled = false
        onHide?()
    }

    private func showWithPreviews() {
        let windowIDs = items.filter { !$0.isMinimized }.map(\.windowID)

        previewGeneration += 1
        let generation = previewGeneration

        guard !windowIDs.isEmpty else {
            hoverEnabled = false
            isVisible = true
            onShow?()
            scheduleHoverEnable(generation: generation)
            return
        }

        let initialPreviewCount = min(10, windowIDs.count)

        let catalog = self.catalog
        previewLoadTask?.cancel()

        hoverEnabled = false
        isVisible = true
        onShow?()

        scheduleHoverEnable(generation: generation)

        previewLoadTask = Task {
            let previews = await catalog.capturePreviews(
                for: windowIDs,
                maxCount: initialPreviewCount,
                maxConcurrentCaptures: 3
            )

            guard !Task.isCancelled else { return }

            self.applyPreviews(previews, generation: generation)

            let deferredWindowIDs = windowIDs.filter { previews[$0] == nil }

            if !deferredWindowIDs.isEmpty {
                let allPreviews = await catalog.capturePreviews(
                    for: deferredWindowIDs,
                    maxConcurrentCaptures: 3
                )
                guard !Task.isCancelled else { return }
                self.applyPreviews(allPreviews, generation: generation)
            }
        }
    }

    private func applyPreviews(_ previews: [CGWindowID: NSImage], generation: Int) {
        guard isVisible, previewGeneration == generation else {
            return
        }

        applyPreviewsToItems(previews)
    }

    private func applyPreviewsToItems(_ previews: [CGWindowID: NSImage]) {
        cachePreviews(previews)
        items = items.map { item in
            previews[item.windowID].map { item.withPreview($0) } ?? item
        }
    }

    private func itemWithCachedPreview(_ item: WindowItem) -> WindowItem {
        if let cachedPreview = previewCache[item.windowID],
           cachedPreview.bounds.integral == item.bounds.integral {
            return item.withPreview(cachedPreview.image)
        }

        guard let cachedPreview = previewCacheBySignature[previewSignature(for: item)] else {
            return item
        }

        return item.withPreview(cachedPreview.image)
    }

    private func cachePreviews(_ previews: [CGWindowID: NSImage]) {
        guard !previews.isEmpty else { return }

        let boundsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, $0.bounds) })
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, $0) })
        for (windowID, image) in previews {
            guard let bounds = boundsByID[windowID] else { continue }
            let cachedPreview = CachedPreview(image: image, bounds: bounds)
            previewCache[windowID] = cachedPreview
            previewCacheOrder.removeAll { $0 == windowID }
            previewCacheOrder.append(windowID)

            if let item = itemsByID[windowID] {
                let signature = previewSignature(for: item)
                previewCacheBySignature[signature] = cachedPreview
                previewCacheBySignatureOrder.removeAll { $0 == signature }
                previewCacheBySignatureOrder.append(signature)
            }
        }

        let liveIDs = Set(items.map(\.windowID))
        previewCache = previewCache.filter { liveIDs.contains($0.key) }
        previewCacheOrder.removeAll { !liveIDs.contains($0) }

        let liveSignatures = Set(items.map(previewSignature(for:)))
        previewCacheBySignature = previewCacheBySignature.filter { liveSignatures.contains($0.key) }
        previewCacheBySignatureOrder.removeAll { !liveSignatures.contains($0) }

        while previewCache.count > maxCachedPreviews, !previewCacheOrder.isEmpty {
            let oldest = previewCacheOrder.removeFirst()
            previewCache.removeValue(forKey: oldest)
        }

        while previewCacheBySignature.count > maxCachedPreviews, !previewCacheBySignatureOrder.isEmpty {
            let oldest = previewCacheBySignatureOrder.removeFirst()
            previewCacheBySignature.removeValue(forKey: oldest)
        }
    }

    private func scheduleHoverEnable(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.previewGeneration == generation else { return }
            self.hoverEnabled = true
        }
    }

    private func previewSignature(for item: WindowItem) -> String {
        "\(item.pid)::\(item.displayTitle)"
    }

    private func orderedItemsForDisplay(from snapshot: [WindowItem]) -> [WindowItem] {
        guard let currentFrontmost = snapshot.first else {
            return []
        }

        let liveIDs = Set(snapshot.map(\.id))
        recentWindowIDs.removeAll { !liveIDs.contains($0) }

        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var orderedItems = [currentFrontmost]
        var seenIDs: Set<WindowItem.ID> = [currentFrontmost.id]

        for windowID in recentWindowIDs {
            guard seenIDs.insert(windowID).inserted,
                  let item = itemsByID[windowID] else {
                continue
            }

            orderedItems.append(item)
        }

        for item in snapshot where seenIDs.insert(item.id).inserted {
            orderedItems.append(item)
        }

        return orderedItems
    }

    private func rememberRecentSelection(_ selectedID: WindowItem.ID) {
        recentWindowIDs = [selectedID] + items.map(\.id).filter { $0 != selectedID }
    }

    private func removeItem(withID id: WindowItem.ID) {
        let removedIndex = items.firstIndex(where: { $0.id == id })
        items.removeAll { $0.id == id }
        recentWindowIDs.removeAll { $0 == id }

        guard !items.isEmpty else {
            cancel()
            return
        }

        if selectedID == id {
            let nextIndex = min(removedIndex ?? 0, items.count - 1)
            selectedID = items[nextIndex].id
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else {
            return
        }

        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let nextIndex = (currentIndex + delta + items.count) % items.count
        selectedID = items[nextIndex].id
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}