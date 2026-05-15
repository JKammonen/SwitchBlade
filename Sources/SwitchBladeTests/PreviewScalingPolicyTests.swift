import AppKit
@testable import SwitchBladeCore

enum PreviewScalingPolicyTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PreviewScalingPolicy/containsPreview_whenWindowSmallerThanTile", containsPreview_whenWindowSmallerThanTile),
        ("PreviewScalingPolicy/containsPreview_whenAspectMismatchWouldCropTooMuch", containsPreview_whenAspectMismatchWouldCropTooMuch),
        ("PreviewScalingPolicy/fillsPreview_whenWindowLargerThanTile", fillsPreview_whenWindowLargerThanTile)
    ]

    @MainActor static func containsPreview_whenWindowSmallerThanTile() throws {
        let shouldContain = PreviewScalingPolicy.shouldContainPreview(
            windowBounds: CGRect(x: 0, y: 0, width: 220, height: 160),
            tileSize: CGSize(width: 420, height: 255)
        )

        try expect(shouldContain, "expected compact utility window to stay contained in tile")
    }

    @MainActor static func containsPreview_whenAspectMismatchWouldCropTooMuch() throws {
        let shouldContain = PreviewScalingPolicy.shouldContainPreview(
            windowBounds: CGRect(x: 0, y: 0, width: 320, height: 520),
            tileSize: CGSize(width: 420, height: 255)
        )

        try expect(shouldContain, "expected tall utility window to avoid aggressive fill crop")
    }

    @MainActor static func fillsPreview_whenWindowLargerThanTile() throws {
        let shouldContain = PreviewScalingPolicy.shouldContainPreview(
            windowBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            tileSize: CGSize(width: 420, height: 255)
        )

        try expect(!shouldContain, "expected large document window to keep fill behavior")
    }
}
