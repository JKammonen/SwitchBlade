import Foundation
@testable import SwitchBladeCore

enum MRUPersistenceTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("MRU/commit_persistsBundleIDOrder", commit_persistsOrder),
        ("MRU/restart_seedsOrderFromPersisted", restart_seedsOrder),
        ("MRU/persistedList_capsAt30", persistedListCaps),
        ("MRU/itemsWithoutBundleID_areSkipped", noBundleSkipped)
    ]

    @MainActor static func commit_persistsOrder() async throws {
        let ud = makeIsolatedUserDefaults()
        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "com.example.frontmost"),
            makeItem(id: 2, pid: 200, bundleIdentifier: "com.example.second"),
            makeItem(id: 3, pid: 300, bundleIdentifier: "com.example.third")
        ]
        let (store, _, activator, _) = makeStore(catalog: catalog, userDefaults: ud)

        store.cycle(forward: true)
        store.selectedID = 3
        store.commitSelection()
        await runPendingMainTasks()

        try expectEqual(activator.activatedItems.last?.id, 3)
        let persisted = ud.array(forKey: "sb_recentBundleIDs") as? [String]
        try expectEqual(persisted?.first, "com.example.third")
    }

    @MainActor static func restart_seedsOrder() async throws {
        let ud = makeIsolatedUserDefaults()
        // Simulate prior-session selection of "com.example.b" → list is ["com.example.b"]
        ud.set(["com.example.b"], forKey: "sb_recentBundleIDs")

        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "com.example.a"),
            makeItem(id: 2, pid: 200, bundleIdentifier: "com.example.c"),
            makeItem(id: 3, pid: 300, bundleIdentifier: "com.example.b")
        ]
        let (store, _, _, _) = makeStore(catalog: catalog, userDefaults: ud)

        store.cycle(forward: true)

        // Frontmost comes first, then the persisted-MRU bundle (b → id 3),
        // then the rest in snapshot order.
        try expectEqual(store.items.map(\.id), [1, 3, 2])
    }

    @MainActor static func persistedListCaps() async throws {
        let ud = makeIsolatedUserDefaults()
        // Pre-load 35 stale bundle IDs to force the cap.
        let stale = (0..<35).map { "com.example.stale\($0)" }
        ud.set(stale, forKey: "sb_recentBundleIDs")

        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "com.example.new")
        ]
        let (store, _, _, _) = makeStore(catalog: catalog, userDefaults: ud)
        store.cycle(forward: true)
        store.selectedID = 1
        store.commitSelection()
        await runPendingMainTasks()

        let persisted = ud.array(forKey: "sb_recentBundleIDs") as? [String] ?? []
        try expectLessThanOrEqual(persisted.count, 30)
        try expectEqual(persisted.first, "com.example.new")
    }

    @MainActor static func noBundleSkipped() async throws {
        let ud = makeIsolatedUserDefaults()
        let catalog = MockWindowCatalog()
        catalog.visibleItems = [
            makeItem(id: 1, pid: 100, isFrontmostApp: true, bundleIdentifier: "com.example.a"),
            makeItem(id: 2, pid: 200, bundleIdentifier: nil)
        ]
        let (store, _, _, _) = makeStore(catalog: catalog, userDefaults: ud)
        store.cycle(forward: true)
        store.selectedID = 2  // no bundleIdentifier
        store.commitSelection()
        await runPendingMainTasks()

        // Selection of an item without bundleID must not crash and must not
        // pollute the persisted list with an empty string.
        let persisted = ud.array(forKey: "sb_recentBundleIDs") as? [String] ?? []
        try expect(!persisted.contains(""))
    }
}
