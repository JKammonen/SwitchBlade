import AppKit
@testable import SwitchBladeCore

enum PreviewScalingPolicyTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("PreviewScalingPolicy/containsPreview_whenWindowSmallerThanTile", containsPreview_whenWindowSmallerThanTile),
        ("PreviewScalingPolicy/containsPreview_whenAspectMismatchWouldCropTooMuch", containsPreview_whenAspectMismatchWouldCropTooMuch),
        ("PreviewScalingPolicy/fillsPreview_whenWindowLargerThanTile", fillsPreview_whenWindowLargerThanTile),
        ("PreviewScalingPolicy/minimizedPlaceholderUsesSmallerIcon", minimizedPlaceholderUsesSmallerIcon),
        ("BadgeContrastPolicy/selectsReadableForeground", badgeContrastSelectsReadableForeground),
        ("BadgeContrastPolicy/honorsOpacityOverKnownBacking", badgeContrastHonorsOpacityOverKnownBacking),
        ("BadgeContrastPolicy/selectedForegroundMeetsWCAGContrast", badgeContrastMeetsWCAGContrast)
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

    @MainActor static func minimizedPlaceholderUsesSmallerIcon() throws {
        let tileSize = CGSize(width: 420, height: 255)
        let normal = PreviewScalingPolicy.placeholderIconSide(tileSize: tileSize, isMinimized: false)
        let minimized = PreviewScalingPolicy.placeholderIconSide(tileSize: tileSize, isMinimized: true)

        try expect(minimized < normal, "minimized fallback must not look like a large fake preview")
        try expect(abs(minimized - 61.2) < 0.001, "expected minimized fallback icon to stay compact")
    }

    @MainActor static func badgeContrastSelectsReadableForeground() throws {
        try expect(BadgeContrastPolicy.usesDarkForeground(red: 1, green: 1, blue: 1))
        try expect(!BadgeContrastPolicy.usesDarkForeground(red: 0, green: 0, blue: 0))
        try expect(BadgeContrastPolicy.usesDarkForeground(red: 5, green: 5, blue: 5))
        try expect(BadgeContrastPolicy.usesDarkForeground(red: 0, green: 0.86, blue: 0))
    }

    @MainActor static func badgeContrastHonorsOpacityOverKnownBacking() throws {
        let transparent = BadgeContrastPolicy.compositedOverBlack(red: 1, green: 0.5, blue: 0.25, opacity: 0)
        let half = BadgeContrastPolicy.compositedOverBlack(red: 1, green: 0.5, blue: 0.25, opacity: 0.5)
        let opaque = BadgeContrastPolicy.compositedOverBlack(red: 1, green: 0.5, blue: 0.25, opacity: 1)
        try expectEqual(transparent, BadgeColorComponents(red: 0, green: 0, blue: 0))
        try expectEqual(half, BadgeColorComponents(red: 0.5, green: 0.25, blue: 0.125))
        try expectEqual(opaque, BadgeColorComponents(red: 1, green: 0.5, blue: 0.25))
    }

    @MainActor static func badgeContrastMeetsWCAGContrast() throws {
        for color in [
            BadgeColorComponents(red: 0, green: 0, blue: 0),
            BadgeColorComponents(red: 1, green: 1, blue: 1),
            BadgeColorComponents(red: 0, green: 0.86, blue: 0),
            BadgeColorComponents(red: 0.4, green: 0.4, blue: 0.4)
        ] {
            let luminance = BadgeContrastPolicy.relativeLuminance(
                red: color.red,
                green: color.green,
                blue: color.blue
            )
            let foregroundLuminance = BadgeContrastPolicy.usesDarkForeground(
                red: color.red,
                green: color.green,
                blue: color.blue
            ) ? 0.0 : 1.0
            try expectGreaterThanOrEqual(
                BadgeContrastPolicy.contrastRatio(luminance, foregroundLuminance),
                BadgeContrastPolicy.minimumTextContrastRatio
            )
        }
    }
}
