import AppKit
import SwiftUI

/// Per-PID cache for dominant icon colors. One app may produce many tiles
/// (e.g. ten Safari windows), and the sampling work is identical for each
/// window of the same app — compute once, share across tiles and invocations.
actor DominantColorCache {
    static let shared = DominantColorCache()
    private var cache: [pid_t: Color] = [:]

    func color(for pid: pid_t) -> Color? { cache[pid] }
    func set(_ color: Color, for pid: pid_t) { cache[pid] = color }
}

struct SwitcherView: View {
    @ObservedObject var store: SwitcherStore
    @ObservedObject private var settings = SwitchBladeSettings.shared

    private var columns: [GridItem] {
        let w = settings.tileMinWidth
        return [GridItem(.adaptive(minimum: w, maximum: w * 1.35), spacing: 10)]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.items) { item in
                            WindowTile(
                                item: item,
                                isSelected: store.selectedID == item.id,
                                settings: settings,
                                onSelect: { store.choose(item) },
                                onHover: { store.hover(item) },
                                onClose: { store.close(item) }
                            )
                        }
                    }
                    .padding(14)
                    .padding(.vertical, 6)
                }

                if let message = store.permissionState.message {
                    Text(message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }

            Button(action: store.openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.72))
            .background(Circle().fill(Color.black.opacity(0.28)))
            .help("Settings")
            .padding(.top, 16)
            .padding(.trailing, 24)
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
    let onSelect: () -> Void
    let onHover: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var appDominantColor: Color? = nil
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
        let animated = isSelected && selectionPulse
        let strength = highlightStrength
        let base = highlightOpacity * (0.78 + Double(strength) * 0.10)
        let peak = min(1.0, highlightOpacity * (1.0 + Double(strength) * 0.20))
        let baseWidth = 1.8 + strength * 2.6
        let peakWidth = baseWidth + strength * 0.8

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
        if settings.reducedMotion {
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

    // Effective badge background: app icon dominant color (if enabled) or fixed setting.
    private var effectiveBadgeBackground: some ShapeStyle {
        let base: Color = settings.badgeUseAppColor ? (appDominantColor ?? settings.badgeColor) : settings.badgeColor
        return base.opacity(settings.badgeOpacity)
    }

    var body: some View {
        // GeometryReader gives us an explicit width so aspectRatio is applied
        // outside, and the image fills the known frame exactly — no collapse.
        GeometryReader { geo in
            ZStack(alignment: settings.badgePosition == .top ? .top : .bottom) {
                if let preview = item.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: settings.previewMode == .blurredPreviews ? 10 : 0)
                        .clipped()
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
                        .foregroundStyle(.white)
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

                // Close button
                if isHovered || isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 20, height: 20)
                                    .background(Color.black.opacity(0.5), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? selectionAccent.opacity(selectionVisualState.borderOpacity) : Color.white.opacity(0.08),
                        lineWidth: isSelected ? selectionVisualState.borderWidth : 1
                    )
            }
            .scaleEffect(isSelected ? selectionVisualState.scale : 1.0)
            .offset(y: isSelected ? selectionVisualState.yOffset : 0)
            .rotationEffect(isSelected ? selectionVisualState.rotation : .degrees(0))
        }
        // aspectRatio on the outer GeometryReader placeholder drives the height.
        .aspectRatio(SwitcherLayout.tileAspectRatio, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0; if $0 { onHover() } }
        .onTapGesture(perform: onSelect)
        .animation(settings.reducedMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: isSelected)
        .task(id: "\(item.id)-\(isSelected)-\(settings.selectionEffect.rawValue)") {
            selectionPulse = false

            guard isSelected, !settings.reducedMotion else { return }

            while !Task.isCancelled {
                withAnimation(selectionAnimation) {
                    selectionPulse = true
                }

                try? await Task.sleep(nanoseconds: selectionPulseDurationNanoseconds)
                if Task.isCancelled { break }

                withAnimation(selectionAnimation) {
                    selectionPulse = false
                }

                try? await Task.sleep(nanoseconds: selectionPulseDurationNanoseconds)
            }

            selectionPulse = false
        }
        .task(id: settings.badgeUseAppColor ? Int(item.pid) : 0) {
            guard settings.badgeUseAppColor, let icon = item.icon else {
                appDominantColor = nil
                return
            }
            if let cached = await DominantColorCache.shared.color(for: item.pid) {
                appDominantColor = cached
                return
            }
            // Run off the main thread, and only when the setting is enabled.
            let color = await Task.detached(priority: .utility) {
                Self.dominantColor(from: icon)
            }.value
            if let color {
                await DominantColorCache.shared.set(color, for: item.pid)
            }
            appDominantColor = color
        }
    }

    /// Samples the average color of non-transparent pixels in a scaled-down version of the icon.
    /// Marked nonisolated so it can run on a background thread via Task.detached.
    nonisolated static func dominantColor(from image: NSImage) -> Color? {
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
        return Color(red: r / count * factor, green: g / count * factor, blue: b / count * factor)
    }

    /// Placeholder shown when no preview image is available. The app icon is
    /// rendered both as a soft tinted backdrop (so the tile takes on the app's
    /// color and doesn't read as "broken") and as a large foreground glyph.
    /// Sized via GeometryReader so the icon scales with the tile, which keeps
    /// the visual proportions consistent regardless of tileMinWidth.
    private var placeholderFill: some View {
        GeometryReader { geo in
            let iconSide = min(geo.size.width, geo.size.height) * 0.42
            ZStack {
                // Soft gradient base so even icon-less items still look intentional.
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.22, blue: 0.32),
                        Color(red: 0.08, green: 0.10, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
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
}
