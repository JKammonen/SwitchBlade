import CoreGraphics
@testable import SwitchBladeCore

enum WindowActivatorTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowActivator/framesAreClose_exactMatch", framesExact),
        ("WindowActivator/framesAreClose_withinTolerance", framesWithinTolerance),
        ("WindowActivator/framesAreClose_outsideTolerance", framesOutsideTolerance),
        ("WindowActivator/framesAreClose_customTolerance", framesCustomTolerance)
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
}
