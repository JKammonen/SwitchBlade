import AppKit
import Carbon.HIToolbox
@testable import SwitchBladeCore

enum SwitcherStoreTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        // cycle / show
        ("Store/cycle_whenNotVisible_showsPanel", cycle_showsPanel),
        ("Store/cycle_whenNotVisible_emptySnapshot_doesNotShow", cycle_emptyNoShow),
        ("Store/cycle_whenNotVisible_preselectsSecondItem", cycle_preselectsSecond),
        ("Store/cycle_whenNotVisible_singleItem_selectsIt", cycle_singleItem),
        ("Store/cycle_whenVisible_movesForward", cycle_visibleForward),
        ("Store/cycle_whenVisible_movesBackward_wraps", cycle_visibleBackwardWraps),
        ("Store/cycle_selectionWrapsAtEnd", cycle_selectionWraps),
        // ordering
        ("Store/ordering_putsFrontmostAppFirst", ordering_frontmost),
        ("Store/ordering_recentlyUsedAfterFrontmost", ordering_recent),
        // handleKeyDown
        ("Store/handleKeyDown_whenNotVisible_false", handleKeyDown_notVisible),
        ("Store/handleKeyDown_tab_forward", handleKeyDown_tabForward),
        ("Store/handleKeyDown_shiftTab_backward", handleKeyDown_shiftTabBackward),
        ("Store/handleKeyDown_arrows_move", handleKeyDown_arrows),
        ("Store/handleKeyDown_return_commits", handleKeyDown_returnCommits),
        ("Store/handleKeyDown_escape_cancels", handleKeyDown_escape),
        ("Store/handleKeyDown_unknownKey_false", handleKeyDown_unknown),
        // commit / cancel
        ("Store/commitSelection_activatesAndHides", commit_activates),
        ("Store/commitSelection_withNoSelection_hides", commit_noSelection),
        ("Store/cancel_hidesWithoutActivating", cancel_hides),
        // close
        ("Store/close_callsActivator_removesFromItems", close_callsActivator),
        ("Store/close_lastItem_hidesPanel", close_lastItem),
        ("Store/close_selectedItem_picksNeighbor", close_picksNeighbor),
        // hover
        ("Store/hover_isIgnoredImmediatelyAfterShow", hover_ignoredInitially),
        // choose
        ("Store/choose_setsSelectionAndCommits", choose_commits)
    ]

    // MARK: cycle / show

    @MainActor static func cycle_showsPanel() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }

        store.cycle(forward: true)

        try expect(store.isVisible)
        try expectEqual(store.items.count, 3)
        try expectEqual(catalog.visibleSnapshotCount, 1)
        try expectEqual(onShowCalls, 1)
    }

    @MainActor static func cycle_emptyNoShow() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = []
        var onShowCalls = 0
        store.onShow = { onShowCalls += 1 }

        store.cycle(forward: true)

        try expect(!store.isVisible)
        try expect(store.items.isEmpty)
        try expectEqual(onShowCalls, 0)
    }

    @MainActor static func cycle_preselectsSecond() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        try expectEqual(store.selectedID, 2)
    }

    @MainActor static func cycle_singleItem() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [makeItem(id: 1, isFrontmostApp: true)]
        store.cycle(forward: true)
        try expectEqual(store.selectedID, 1)
    }

    @MainActor static func cycle_visibleForward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)              // selected = 2
        store.cycle(forward: true)
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func cycle_visibleBackwardWraps() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)              // selected = 2
        store.cycle(forward: false)             // → 1
        store.cycle(forward: false)             // wraps → 3
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func cycle_selectionWraps() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)              // selected = 2
        store.cycle(forward: true)              // wraps → 1
        try expectEqual(store.selectedID, 1)
        store.cycle(forward: true)              // → 2
        try expectEqual(store.selectedID, 2)
    }

    // MARK: ordering

    @MainActor static func ordering_frontmost() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, appName: "Other"),
            makeItem(id: 2, appName: "Front", isFrontmostApp: true),
            makeItem(id: 3, appName: "Another")
        ]
        store.cycle(forward: true)
        try expectEqual(store.items.first?.id, 2)
    }

    @MainActor static func ordering_recent() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        store.selectedID = 3
        store.commitSelection()
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 3)

        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        try expectEqual(store.items.map(\.id), [1, 3, 2])
    }

    // MARK: handleKeyDown

    @MainActor static func handleKeyDown_notVisible() async throws {
        let (store, _, _, _) = makeStore()
        try expect(store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab)) == false)
    }

    @MainActor static func handleKeyDown_tabForward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab))
        try expect(handled)
        try expectEqual(store.selectedID, 3)
    }

    @MainActor static func handleKeyDown_shiftTabBackward() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Tab, modifiers: .shift))
        try expect(handled)
        try expectEqual(store.selectedID, 1)
    }

    @MainActor static func handleKeyDown_arrows() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_RightArrow))
        try expectEqual(store.selectedID, 3)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_LeftArrow))
        try expectEqual(store.selectedID, 2)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_DownArrow))
        try expectEqual(store.selectedID, 3)
        _ = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_UpArrow))
        try expectEqual(store.selectedID, 2)
    }

    @MainActor static func handleKeyDown_returnCommits() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Return))
        try expect(handled)
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 2)
    }

    @MainActor static func handleKeyDown_escape() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)
        let handled = store.handleKeyDown(makeKeyDownEvent(keyCode: kVK_Escape))
        try expect(handled)
        try expect(!store.isVisible)
        try expect(activator.activatedItems.isEmpty)
    }

    @MainActor static func handleKeyDown_unknown() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)
        try expect(store.handleKeyDown(makeKeyDownEvent(keyCode: 0)) == false)
    }

    // MARK: commit / cancel

    @MainActor static func commit_activates() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)
        store.selectedID = 1

        store.commitSelection()
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.map(\.id), [1])
    }

    @MainActor static func commit_noSelection() async throws {
        let (store, _, activator, _) = makeStore()
        store.commitSelection()
        await runPendingMainTasks()
        try expect(!store.isVisible)
        try expect(activator.activatedItems.isEmpty)
    }

    @MainActor static func cancel_hides() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)
        var onHideCalls = 0
        store.onHide = { onHideCalls += 1 }

        store.cancel()
        await runPendingMainTasks()

        try expect(!store.isVisible)
        try expectEqual(onHideCalls, 1)
        try expect(activator.activatedItems.isEmpty)
    }

    // MARK: close

    @MainActor static func close_callsActivator() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        let toClose = store.items.first(where: { $0.id == 2 })!

        store.close(toClose)

        try expectEqual(activator.closedItems.map(\.id), [2])
        try expectEqual(store.items.map(\.id), [1, 3])
    }

    @MainActor static func close_lastItem() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [makeItem(id: 1, isFrontmostApp: true)]
        store.cycle(forward: true)
        store.close(store.items[0])
        try expect(store.items.isEmpty)
        try expect(!store.isVisible)
    }

    @MainActor static func close_picksNeighbor() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        store.selectedID = 2
        let toClose = store.items.first(where: { $0.id == 2 })!
        store.close(toClose)
        try expectNotNil(store.selectedID)
        try expect(store.selectedID != 2)
    }

    // MARK: hover

    @MainActor static func hover_ignoredInitially() async throws {
        let (store, catalog, _, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2)
        ]
        store.cycle(forward: true)
        let originalSelection = store.selectedID

        // hoverEnabled is false until scheduleHoverEnable fires after 200 ms.
        store.hover(store.items[1])
        try expectEqual(store.selectedID, originalSelection)
    }

    // MARK: choose

    @MainActor static func choose_commits() async throws {
        let (store, catalog, activator, _) = makeStore()
        catalog.visibleItems = [
            makeItem(id: 1, isFrontmostApp: true),
            makeItem(id: 2),
            makeItem(id: 3)
        ]
        store.cycle(forward: true)
        let target = store.items.first(where: { $0.id == 3 })!

        store.choose(target)
        try expect(!store.isVisible)
        await runPendingMainTasks()
        try expectEqual(activator.activatedItems.last?.id, 3)
    }
}
