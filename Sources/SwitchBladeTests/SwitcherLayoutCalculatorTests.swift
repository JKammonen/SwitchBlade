import CoreGraphics
@testable import SwitchBladeCore

enum SwitcherLayoutCalculatorTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("Layout/threeItems_packIntoThreeColumns", threeItems_threeColumns),
        ("Layout/fiveItems_balancesAsThreeByTwo", fiveItems_balanced),
        ("Layout/eightItems_balancesAsFourByTwo", eightItems_balanced),
        ("Layout/panelCenteredOnScreen", panelCentered),
        ("Layout/threeItemPanel_narrowerThanMaxPanel", threeNarrower),
        ("Layout/heightCapsAt80PercentOfScreen", heightCap),
        ("Layout/zeroItems_doesNotCrash", zeroItems),
        ("Layout/tinyScreen_producesUsablePanel", tinyScreen)
    ]

    private static let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let aspect: CGFloat = 1.65
    private static let tileW: CGFloat = 220

    static func threeItems_threeColumns() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 3, tileAspectRatio: aspect))
        try expectEqual(r.columns, 3)
        try expectEqual(r.rows, 1)
    }

    static func fiveItems_balanced() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: 300, itemCount: 5, tileAspectRatio: aspect))
        try expectEqual(r.columns, 3)
        try expectEqual(r.rows, 2)
    }

    static func eightItems_balanced() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 8, tileAspectRatio: aspect))
        try expectEqual(r.columns, 4)
        try expectEqual(r.rows, 2)
        // Sanity: rows × columns must hold all items.
        try expectGreaterThanOrEqual(r.columns * r.rows, 8)
    }

    static func panelCentered() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 4, tileAspectRatio: aspect))
        try expect(abs(r.panelFrame.midX - screen.midX) < 0.5, "x not centered")
        try expect(abs(r.panelFrame.midY - screen.midY) < 0.5, "y not centered")
    }

    static func threeNarrower() throws {
        let three = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 3, tileAspectRatio: aspect))
        let many = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 12, tileAspectRatio: aspect))
        try expectLessThan(three.panelFrame.width, many.panelFrame.width)
    }

    static func heightCap() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: 140, itemCount: 200, tileAspectRatio: aspect))
        let maxAllowed = screen.height * 0.80
            + SwitcherLayoutCalculator.cardMarginY * 2
            + SwitcherLayoutCalculator.verticalSafety
            + 1
        try expectLessThanOrEqual(r.panelFrame.height, maxAllowed)
    }

    static func zeroItems() throws {
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: screen, tileMinWidth: tileW, itemCount: 0, tileAspectRatio: aspect))
        try expectGreaterThanOrEqual(r.columns, 1)
        try expectGreaterThanOrEqual(r.rows, 1)
        try expectGreaterThan(r.panelFrame.width, 0)
        try expectGreaterThan(r.panelFrame.height, 0)
    }

    static func tinyScreen() throws {
        let tiny = CGRect(x: 0, y: 0, width: 640, height: 480)
        let r = SwitcherLayoutCalculator.calculate(.init(
            visibleFrame: tiny, tileMinWidth: 220, itemCount: 5, tileAspectRatio: aspect))
        try expectGreaterThan(r.panelFrame.width, 0)
        try expectGreaterThan(r.panelFrame.height, 0)
        try expectGreaterThanOrEqual(r.columns, 1)
    }
}
