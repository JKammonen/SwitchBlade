import CoreGraphics
@testable import SwitchBladeCore

enum WindowActivatorTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowActivator/framesAreClose_exactMatch", framesExact),
        ("WindowActivator/framesAreClose_withinTolerance", framesWithinTolerance),
        ("WindowActivator/framesAreClose_outsideTolerance", framesOutsideTolerance),
        ("WindowActivator/framesAreClose_customTolerance", framesCustomTolerance),
        ("WindowActivator/snapFrame_halvesVisibleFrame", snapFrame_halvesVisibleFrame),
        ("WindowActivator/bestVisibleFrame_prefersLargestIntersection", bestVisibleFrame_prefersLargestIntersection)
    ]

    static func framesExact() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        try expect(WindowActivator.framesAreClose(a, a))
    }

    static func framesWithinTolerance() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 105, y: 195, width: 803, height: 597)  // <12 pt drift on each axis
        try expect(WindowActivator.framesAreClose(a, b))
    }

    static func framesOutsideTolerance() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        // 20-pt shift in x alone — should fail with default tolerance 12.
        let b = CGRect(x: 120, y: 200, width: 800, height: 600)
        try expect(!WindowActivator.framesAreClose(a, b))
    }

    static func framesCustomTolerance() throws {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 30, y: 0, width: 100, height: 100)
        try expect(!WindowActivator.framesAreClose(a, b, tolerance: 10))
        try expect(WindowActivator.framesAreClose(a, b, tolerance: 50))
    }

    static func snapFrame_halvesVisibleFrame() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1240, height: 860)
        let visibleFrame = CGRect(x: 20, y: 40, width: 1200, height: 800)

        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .left),
            CGRect(x: 20, y: 20, width: 600, height: 800)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .right),
            CGRect(x: 620, y: 20, width: 600, height: 800)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .top),
            CGRect(x: 20, y: 20, width: 1200, height: 400)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .bottom),
            CGRect(x: 20, y: 420, width: 1200, height: 400)
        )
    }

    static func bestVisibleFrame_prefersLargestIntersection() throws {
        let primary = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        let secondary = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 700)
        )
        let spanningWindow = CGRect(x: 850, y: 100, width: 500, height: 400)

        let chosen = WindowActivator.bestScreen(
            for: spanningWindow,
            candidates: [primary, secondary]
        )

        try expectEqual(chosen, secondary)
    }
}
