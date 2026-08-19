import AppKit
import SwiftUI

/// Per-app-identity cache for dominant icon colors. One app may produce many
/// tiles (e.g. ten Safari windows), and the sampling work is identical for each
/// window of the same app — compute once, share across tiles and invocations.
struct BadgeColorComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

actor DominantColorCache {
    static let shared = DominantColorCache()
    // Keyed by app identity (bundle id, else app name) rather than pid: the OS
    // recycles pids, so a pid key could hand a freshly-launched app the dead
    // app's tint. Bounded so a long session can't grow the cache without limit.
    private var cache = LRUDictionary<String, BadgeColorComponents>(capacity: 64)

    func color(for identity: String) -> BadgeColorComponents? { cache[identity] }
    func set(_ color: BadgeColorComponents, for identity: String) { cache[identity] = color }
}

enum PreviewScalingPolicy {
    static let containedPreviewInset: CGFloat = 12
    static let minimumVisibleFractionForFill: CGFloat = 0.78
    static let placeholderIconFraction: CGFloat = 0.42
    static let minimizedPlaceholderIconFraction: CGFloat = 0.24

    /// Small windows like Calculator look wrong when forced to fill the whole
    /// tile: the preview gets enlarged and cropped as if it were a large
    /// document window. Keep previews contained when the source window is
    /// already smaller than the available tile canvas, or when forcing fill
    /// would crop too much due to an aspect-ratio mismatch.
    static func shouldContainPreview(windowBounds: CGRect, tileSize: CGSize) -> Bool {
        let availableWidth = max(1, tileSize.width - containedPreviewInset * 2)
        let availableHeight = max(1, tileSize.height - containedPreviewInset * 2)
        if windowBounds.width <= availableWidth && windowBounds.height <= availableHeight {
            return true
        }

        let windowAspectRatio = max(windowBounds.width, 1) / max(windowBounds.height, 1)
        let tileAspectRatio = max(tileSize.width, 1) / max(tileSize.height, 1)
        let visibleFractionWhenFilled = min(windowAspectRatio, tileAspectRatio) / max(windowAspectRatio, tileAspectRatio)
        return visibleFractionWhenFilled < minimumVisibleFractionForFill
    }

    static func placeholderIconSide(tileSize: CGSize, isMinimized: Bool) -> CGFloat {
        min(tileSize.width, tileSize.height) * (isMinimized ? minimizedPlaceholderIconFraction : placeholderIconFraction)
    }
}

enum BadgeContrastPolicy {
    static let minimumTextContrastRatio = 4.5

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func linearizedSRGB(_ value: Double) -> Double {
        let component = unit(value)
        return component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linearizedSRGB(red)
            + 0.7152 * linearizedSRGB(green)
            + 0.0722 * linearizedSRGB(blue)
    }

    static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func usesDarkForeground(red: Double, green: Double, blue: Double) -> Bool {
        let background = relativeLuminance(red: red, green: green, blue: blue)
        let blackContrast = contrastRatio(background, 0)
        let whiteContrast = contrastRatio(background, 1)
        return blackContrast >= whiteContrast
    }

    /// Render the configured alpha over an opaque black badge backing. The
    /// preview below the badge is therefore no longer an unknown contrast input,
    /// while the full 0...100% control range still changes the color contribution.
    static func compositedOverBlack(
        red: Double,
        green: Double,
        blue: Double,
        opacity: Double
    ) -> BadgeColorComponents {
        let alpha = unit(opacity)
        return BadgeColorComponents(
            red: unit(red) * alpha,
            green: unit(green) * alpha,
            blue: unit(blue) * alpha
        )
    }
}

struct SwitcherView: View {
    @ObservedObject var store: SwitcherStore
    @ObservedObject private var settings = SwitchBladeSettings.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @AccessibilityFocusState private var accessibilityFocusedWindowID: WindowItem.ID?

    static func gridColumns(tileWidth: CGFloat, count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(tileWidth), spacing: SwitcherLayoutCalculator.gap),
            count: max(1, count)
        )
    }

    private var columns: [GridItem] {
        Self.gridColumns(tileWidth: store.panelTileWidth, count: store.panelColumnCount)
    }

    private var effectiveReduceMotion: Bool {
        settings.reducedMotion || systemReduceMotion
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: store.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.95))
                .background(Circle().fill(Color.black.opacity(0.72)))
                .help(L10n.tr(.tooltipSettings))
                .accessibilityLabel(L10n.tr(.tooltipSettings))
            }
            .frame(height: SwitcherLayoutCalculator.headerHeight)
            .padding(.horizontal, SwitcherLayoutCalculator.gridPadX)

            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: true) {
                    LazyVGrid(
                        columns: columns,
                        alignment: .center,
                        spacing: SwitcherLayoutCalculator.gap
                    ) {
                        ForEach(store.items) { item in
                            WindowTile(
                                item: item,
                                isSelected: store.selectedID == item.id,
                                settings: settings,
                                reduceMotion: effectiveReduceMotion,
                                differentiateWithoutColor: differentiateWithoutColor,
                                onSelect: { store.choose(item) },
                                onHover: { store.hover(item) },
                                onSnap: { edge in store.snap(item, to: edge) },
                                onClose: { store.close(item) }
                            )
                            .id(item.id)
                            .accessibilityFocused($accessibilityFocusedWindowID, equals: item.id)
                        }
                    }
                    .padding(SwitcherLayoutCalculator.gridPadX)
                    .padding(.vertical, 6)
                }
                .onChange(of: store.selectedID) { _, selectedID in
                    guard let selectedID else { return }
                    accessibilityFocusedWindowID = selectedID
                    withAnimation(effectiveReduceMotion ? nil : .easeInOut(duration: 0.12)) {
                        scrollProxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }

            if let permission = store.primaryMissingPermission {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button(L10n.tr(.permissionActionOpenSettingsShort)) {
                        store.openPrimaryPermissionSettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.bold))
                    .fixedSize()
                    .accessibilityHint(store.permissionMessage ?? permission.title)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: SwitcherLayoutCalculator.permissionFooterHeight - 10)
                .background(
                    Color.black.opacity(0.76),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        // Panel is sized to exactly fit the content + cardMargin padding outside.
        // No fixedSize or maxHeight tricks needed — NSPanel height is authoritative.
        //
        // Background and border are drawn as GPU-rendered Shape fills rather than
        // via clipShape (which uses a CGContext software mask and produces jagged
        // edges). Grid content has 14 pt inset on all sides so it never reaches
        // the 20 pt corner area — clipShape is not needed.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flat fill — the CAShapeLayer mask in SwitcherPanelController clips this
        // to the rounded card shape with proper GPU antialiasing.
        .background(settings.backgroundColor.opacity(settings.backgroundOpacity))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct WindowTile: View {
    let item: WindowItem
    let isSelected: Bool
    let settings: SwitchBladeSettings
    let reduceMotion: Bool
    let differentiateWithoutColor: Bool
    let onSelect: () -> Void
    let onHover: () -> Void
    let onSnap: (WindowSnapEdge) -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var appDominantColor: BadgeColorComponents? = nil
    @State private var selectionPulse = false

    private struct SelectionVisualState {
        let scale: CGFloat
        let yOffset: CGFloat
        let rotation: Angle
        let borderOpacity: Double
        let borderWidth: CGFloat
    }

    private var selectionAccent: Color {
        settings.highlightColor
    }

    private var highlightStrength: CGFloat {
        CGFloat(settings.highlightStrength)
    }

    private var highlightOpacity: Double {
        settings.highlightOpacity
    }

    private var selectionVisualState: SelectionVisualState {
        let animated = isSelected && selectionPulse && !reduceMotion
        let strength = highlightStrength
        let base = highlightOpacity * (0.78 + Double(strength) * 0.10)
        let peak = min(1.0, highlightOpacity * (1.0 + Double(strength) * 0.20))
        let baseWidth = 1.8 + strength * 2.6
        let peakWidth = baseWidth + strength * 0.8
        if reduceMotion {
            return SelectionVisualState(
                scale: 1.0,
                yOffset: 0,
                rotation: .degrees(0),
                borderOpacity: base,
                borderWidth: baseWidth
            )
        }

        switch settings.selectionEffect {
        case .pump:
            return SelectionVisualState(
                scale: animated ? (1.004 + strength * 0.014) : 1.0,
                yOffset: 0,
                rotation: .degrees(0),
                borderOpacity: animated ? peak : base,
                borderWidth: animated ? peakWidth : baseWidth
            )
        case .breathe:
            return SelectionVisualState(
                scale: animated ? (1.003 + strength * 0.010) : 0.998,
                yOffset: 0,
                rotation: .degrees(0),
                borderOpacity: animated ? peak : base,
                borderWidth: animated ? peakWidth : baseWidth
            )
        case .bounce:
            return SelectionVisualState(
                scale: animated ? (1.003 + strength * 0.010) : 1.0,
                yOffset: animated ? -(1.5 + strength * 3.0) : 0,
                rotation: .degrees(0),
                borderOpacity: animated ? peak : base,
                borderWidth: animated ? peakWidth : baseWidth
            )
        case .float:
            return SelectionVisualState(
                scale: animated ? (1.002 + strength * 0.006) : 1.0,
                yOffset: animated ? -(1.0 + strength * 2.2) : 0,
                rotation: .degrees(0),
                borderOpacity: animated ? peak : base,
                borderWidth: animated ? peakWidth : baseWidth
            )
        case .wobble:
            return SelectionVisualState(
                scale: animated ? (1.002 + strength * 0.006) : 1.0,
                yOffset: 0,
                rotation: .degrees(animated ? (0.35 + Double(strength) * 1.0) : 0),
                borderOpacity: animated ? peak : base,
                borderWidth: animated ? peakWidth : baseWidth
            )
        }
    }

    private var selectionAnimation: Animation {
        if reduceMotion {
            return .linear(duration: 0.01)
        }

        switch settings.selectionEffect {
        case .pump:
            return .easeInOut(duration: 0.62)
        case .breathe:
            return .easeInOut(duration: 1.10)
        case .bounce:
            return .interpolatingSpring(stiffness: 220, damping: 14)
        case .float:
            return .easeInOut(duration: 0.92)
        case .wobble:
            return .easeInOut(duration: 0.72)
        }
    }

    private var selectionPulseDurationNanoseconds: UInt64 {
        switch settings.selectionEffect {
        case .pump:
            return 620_000_000
        case .breathe:
            return 1_100_000_000
        case .bounce:
            return 700_000_000
        case .float:
            return 920_000_000
        case .wobble:
            return 720_000_000
        }
    }

    private var effectiveBadgeComponents: BadgeColorComponents {
        let fixed = BadgeColorComponents(
            red: settings.badgeRed,
            green: settings.badgeGreen,
            blue: settings.badgeBlue
        )
        let base = settings.badgeUseAppColor ? (appDominantColor ?? fixed) : fixed
        return BadgeContrastPolicy.compositedOverBlack(
            red: base.red,
            green: base.green,
            blue: base.blue,
            opacity: settings.badgeOpacity
        )
    }

    // Opaque final color: preview pixels cannot weaken the measured contrast.
    private var effectiveBadgeBackground: Color {
        effectiveBadgeComponents.color
    }

    private var badgeForeground: Color {
        let background = effectiveBadgeComponents
        return BadgeContrastPolicy.usesDarkForeground(
            red: background.red,
            green: background.green,
            blue: background.blue
        ) ? .black : .white
    }

    private var tileAccessibilityLabel: String {
        var parts = [item.displayTitle]
        if item.subtitle != item.displayTitle {
            parts.append(item.subtitle)
        }
        if item.isMinimized {
            parts.append(L10n.tr(.windowStateMinimized))
        }
        return parts.joined(separator: ", ")
    }

    private var selectionBorder: some View {
        let color = isSelected
            ? selectionAccent.opacity(selectionVisualState.borderOpacity)
            : Color.white.opacity(0.08)
        let width = isSelected ? selectionVisualState.borderWidth : 1
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(color, lineWidth: width)
    }

    var body: some View {
        // GeometryReader gives us an explicit width so aspectRatio is applied
        // outside, and the image fills the known frame exactly — no collapse.
        GeometryReader { geo in
            let containsPreview = PreviewScalingPolicy.shouldContainPreview(
                windowBounds: item.bounds,
                tileSize: geo.size
            )

            ZStack(alignment: settings.badgePosition == .top ? .top : .bottom) {
                if let preview = item.preview {
                    previewBackdrop
                        .frame(width: geo.size.width, height: geo.size.height)

                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: containsPreview ? .fit : .fill)
                        .frame(
                            width: containsPreview
                                ? max(1, geo.size.width - PreviewScalingPolicy.containedPreviewInset * 2)
                                : geo.size.width,
                            height: containsPreview
                                ? max(1, geo.size.height - PreviewScalingPolicy.containedPreviewInset * 2)
                                : geo.size.height
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: settings.previewMode == .blurredPreviews ? 10 : 0)
                        .clipped()
                } else if item.isMinimized {
                    minimizedPlaceholderFill
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    placeholderFill
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // Badge bar
                HStack(spacing: 6) {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: settings.badgeIconSize, height: settings.badgeIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(item.displayTitle)
                        .font(.system(size: settings.badgeFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(badgeForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, settings.badgeVerticalPadding)
                .background(effectiveBadgeBackground)

                // Minimized indicator — top-left chip. Always visible while the
                // window is minimized so a user can tell at a glance which tiles
                // would un-minimize on selection.
                if item.isMinimized {
                    VStack {
                        HStack {
                            Image(systemName: "dock.rectangle")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                }

                selectionMarker
                tileActionControls
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(selectionBorder)
            .scaleEffect(isSelected ? selectionVisualState.scale : 1.0)
            .offset(y: isSelected ? selectionVisualState.yOffset : 0)
            .rotationEffect(isSelected ? selectionVisualState.rotation : .degrees(0))
            .zIndex(isSelected ? 1 : 0)
        }
        // aspectRatio on the outer GeometryReader placeholder drives the height.
        .aspectRatio(SwitcherLayout.tileAspectRatio, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0; if $0 { onHover() } }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if !item.isApplicationFallback {
                snapMenuItems
            }
        }
        .modifier(WindowTileAccessibilityModifier(
            label: tileAccessibilityLabel,
            hint: L10n.tr(
                item.isApplicationFallback
                    ? .accessibilityApplicationTileHint
                    : .accessibilityWindowTileHint
            ),
            isSelected: isSelected,
            allowsWindowActions: !item.isApplicationFallback,
            onSelect: onSelect,
            onClose: onClose,
            onSnap: onSnap
        ))
        .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: isSelected)
        .task(id: "\(item.id)-\(isSelected)-\(settings.selectionEffect.rawValue)") {
            selectionPulse = false

            guard isSelected, !reduceMotion else { return }

            withAnimation(selectionAnimation) {
                selectionPulse = true
            }

            try? await Task.sleep(nanoseconds: selectionPulseDurationNanoseconds)
            guard !Task.isCancelled else { return }

            withAnimation(selectionAnimation) {
                selectionPulse = false
            }
        }
        // Re-run keyed on the same identity the cache uses, so a tile reused for
        // a different app (or the same app after a relaunch) resolves the right
        // entry instead of missing on a stale pid key.
        .task(id: settings.badgeUseAppColor ? (item.bundleIdentifier ?? item.appName) : "") {
            guard settings.badgeUseAppColor, let icon = item.icon else {
                appDominantColor = nil
                return
            }
            let identity = item.bundleIdentifier ?? item.appName
            if let cached = await DominantColorCache.shared.color(for: identity) {
                appDominantColor = cached
                return
            }
            // Run off the main thread, and only when the setting is enabled.
            let color = await Task.detached(priority: .utility) {
                Self.dominantColor(from: icon)
            }.value
            if let color {
                await DominantColorCache.shared.set(color, for: identity)
            }
            appDominantColor = color
        }
    }

    @ViewBuilder
    private var selectionMarker: some View {
        if isSelected && differentiateWithoutColor {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.75))
                }
            }
            .padding(7)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var tileActionControls: some View {
        if !item.isApplicationFallback, isHovered || isSelected {
            VStack {
                HStack {
                    Spacer()
                    Menu {
                        snapMenuItems
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .help(L10n.tr(.actionSnapWindow))
                    .accessibilityLabel(L10n.tr(.actionSnapWindow))
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr(.actionCloseWindow))
                    .accessibilityLabel(L10n.tr(.actionCloseWindow))
                }
                Spacer()
            }
            .padding(6)
        }
    }

    /// Samples the average color of non-transparent pixels in a scaled-down version of the icon.
    /// Marked nonisolated so it can run on a background thread via Task.detached.
    nonisolated static func dominantColor(from image: NSImage) -> BadgeColorComponents? {
        let side = 12
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for i in 0 ..< side * side {
            let a = Double(pixels[i * 4 + 3])
            guard a > 30 else { continue }  // skip near-transparent pixels
            r += Double(pixels[i * 4    ]) / 255.0
            g += Double(pixels[i * 4 + 1]) / 255.0
            b += Double(pixels[i * 4 + 2]) / 255.0
            count += 1
        }
        guard count > 0 else { return nil }
        // Darken slightly so white text stays readable.
        let factor = 0.55
        return BadgeColorComponents(
            red: r / count * factor,
            green: g / count * factor,
            blue: b / count * factor
        )
    }

    /// Placeholder shown when no preview image is available. The app icon is
    /// rendered both as a soft tinted backdrop (so the tile takes on the app's
    /// color and doesn't read as "broken") and as a large foreground glyph.
    /// Sized via GeometryReader so the icon scales with the tile, which keeps
    /// the visual proportions consistent regardless of tileMinWidth.
    private var previewBackdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.13, green: 0.14, blue: 0.18),
                Color(red: 0.07, green: 0.08, blue: 0.11)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var placeholderFill: some View {
        GeometryReader { geo in
            let iconSide = PreviewScalingPolicy.placeholderIconSide(tileSize: geo.size, isMinimized: false)
            ZStack {
                // Soft gradient base so even icon-less items still look intentional.
                previewBackdrop
                // Tinted backdrop derived from the app icon — bleeds the icon
                // color into the background so the tile feels "this app's tile",
                // not a generic placeholder.
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.18)
                        .blur(radius: 24)
                        .clipped()
                }
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSide, height: iconSide)
                        .clipShape(RoundedRectangle(cornerRadius: iconSide * 0.22, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
                }
            }
        }
    }

    private var minimizedPlaceholderFill: some View {
        GeometryReader { geo in
            let iconSide = PreviewScalingPolicy.placeholderIconSide(tileSize: geo.size, isMinimized: true)
            ZStack {
                previewBackdrop
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.12)
                        .blur(radius: 28)
                        .clipped()
                }

                VStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        if let icon = item.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: iconSide, height: iconSide)
                                .clipShape(RoundedRectangle(cornerRadius: iconSide * 0.22, style: .continuous))
                        }
                        Image(systemName: "dock.rectangle")
                            .font(.system(size: max(10, iconSide * 0.22), weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(5)
                            .background(Color.black.opacity(0.62), in: Circle())
                            .offset(x: iconSide * 0.14, y: iconSide * 0.14)
                    }
                    Text(L10n.tr(.windowStateMinimized))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.74))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.38), in: Capsule())
                }
                .padding(.top, settings.badgePosition == .top ? 26 : 0)
                .padding(.bottom, settings.badgePosition == .bottom ? 26 : 0)
            }
        }
    }

    @ViewBuilder
    private var snapMenuItems: some View {
        ForEach(WindowSnapEdge.allCases) { edge in
            Button {
                onSnap(edge)
            } label: {
                Label(edge.title, systemImage: edge.symbolName)
            }
        }
    }
}

private struct WindowTileAccessibilityModifier: ViewModifier {
    let label: String
    let hint: String
    let isSelected: Bool
    let allowsWindowActions: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onSnap: (WindowSnapEdge) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction { onSelect() }

        if allowsWindowActions {
            base
                .accessibilityAction(named: Text(L10n.tr(.actionCloseWindow)), onClose)
                .accessibilityAction(named: snapTitle(.left)) { onSnap(.left) }
                .accessibilityAction(named: snapTitle(.right)) { onSnap(.right) }
                .accessibilityAction(named: snapTitle(.top)) { onSnap(.top) }
                .accessibilityAction(named: snapTitle(.bottom)) { onSnap(.bottom) }
        } else {
            base
        }
    }

    private func snapTitle(_ edge: WindowSnapEdge) -> Text {
        Text("\(L10n.tr(.actionSnapWindow)): \(edge.title)")
    }
}
