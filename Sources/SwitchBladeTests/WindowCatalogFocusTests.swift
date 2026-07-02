import CoreGraphics
@testable import SwitchBladeCore

/// Pure matching/reordering halves of the AX focused-window normalization.
/// The AX read itself needs real windows and stays out of unit scope.
enum WindowCatalogFocusTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("CatalogFocus/focusedWindowMatch_uniqueTitleWins", uniqueTitleWins),
        ("CatalogFocus/focusedWindowMatch_frameDisambiguatesDuplicateTitles", frameDisambiguates),
        ("CatalogFocus/focusedWindowMatch_ambiguousDuplicatesReturnNil", ambiguousReturnsNil),
        ("CatalogFocus/focusedWindowMatch_singleSiblingReturnsIt", singleSiblingReturnsIt),
        ("CatalogFocus/promotingWindow_movesFocusedBeforeSiblings", promotingMovesFocused),
        ("CatalogFocus/promotingWindow_noopWhenAlreadyLeading", promotingNoop)
    ]

    @MainActor static func uniqueTitleWins() throws {
        let items = [
            makeItem(id: 1, pid: 100, title: "Draft A"),
            makeItem(id: 2, pid: 100, title: "Draft B"),
            makeItem(id: 9, pid: 200, title: "Other")
        ]
        let match = WindowCatalog.focusedWindowMatch(
            in: items, pid: 100, focusedTitle: "Draft B", focusedFrame: nil
        )
        try expectEqual(match?.id, 2)
    }

    @MainActor static func frameDisambiguates() throws {
        let items = [
            makeItem(id: 1, pid: 100, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            makeItem(id: 2, pid: 100, title: "Doc", bounds: CGRect(x: 900, y: 100, width: 700, height: 500))
        ]
        let match = WindowCatalog.focusedWindowMatch(
            in: items,
            pid: 100,
            focusedTitle: "Doc",
            focusedFrame: CGRect(x: 902, y: 98, width: 700, height: 500)
        )
        try expectEqual(match?.id, 2)
    }

    @MainActor static func ambiguousReturnsNil() throws {
        let items = [
            makeItem(id: 1, pid: 100, title: "Doc", bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            makeItem(id: 2, pid: 100, title: "Doc", bounds: CGRect(x: 4, y: 2, width: 800, height: 600))
        ]
        // Same title, overlapping frames, no way to tell them apart — a wrong
        // guess would bake the wrong "active window" into MRU state.
        let match = WindowCatalog.focusedWindowMatch(
            in: items,
            pid: 100,
            focusedTitle: "Doc",
            focusedFrame: CGRect(x: 1, y: 1, width: 800, height: 600)
        )
        try expectEqual(match?.id, nil)
    }

    @MainActor static func singleSiblingReturnsIt() throws {
        let items = [
            makeItem(id: 1, pid: 100, title: "Only"),
            makeItem(id: 9, pid: 200, title: "Other")
        ]
        let match = WindowCatalog.focusedWindowMatch(
            in: items, pid: 100, focusedTitle: "Stale Title", focusedFrame: nil
        )
        try expectEqual(match?.id, 1)
    }

    @MainActor static func promotingMovesFocused() throws {
        let items = [
            makeItem(id: 9, pid: 200),
            makeItem(id: 1, pid: 100),
            makeItem(id: 2, pid: 100),
            makeItem(id: 8, pid: 300)
        ]
        let reordered = WindowCatalog.promotingWindow(2, in: items, beforeSiblingsOf: 100)
        try expectEqual(reordered.map(\.id), [9, 2, 1, 8])
    }

    @MainActor static func promotingNoop() throws {
        let items = [
            makeItem(id: 9, pid: 200),
            makeItem(id: 1, pid: 100),
            makeItem(id: 2, pid: 100)
        ]
        let reordered = WindowCatalog.promotingWindow(1, in: items, beforeSiblingsOf: 100)
        try expectEqual(reordered.map(\.id), [9, 1, 2])
    }
}
