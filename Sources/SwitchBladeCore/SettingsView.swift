import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SwitchBladeSettings

    private var badgeColorBinding: Binding<Color> {
        Binding(
            get: { settings.badgeColor },
            set: { color in
                if let ns = NSColor(color).usingColorSpace(.sRGB) {
                    settings.badgeRed   = ns.redComponent
                    settings.badgeGreen = ns.greenComponent
                    settings.badgeBlue  = ns.blueComponent
                }
            }
        )
    }

    private var bgColorBinding: Binding<Color> {
        Binding(
            get: { settings.backgroundColor },
            set: { color in
                if let ns = NSColor(color).usingColorSpace(.sRGB) {
                    settings.bgRed   = ns.redComponent
                    settings.bgGreen = ns.greenComponent
                    settings.bgBlue  = ns.blueComponent
                }
            }
        )
    }

    private var highlightColorBinding: Binding<Color> {
        Binding(
            get: { settings.highlightColor },
            set: { color in
                if let ns = NSColor(color).usingColorSpace(.sRGB) {
                    settings.highlightRed   = ns.redComponent
                    settings.highlightGreen = ns.greenComponent
                    settings.highlightBlue  = ns.blueComponent
                }
            }
        )
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                group(title: L10n.tr(.settingsLanguage)) {
                    row(L10n.tr(.fieldLanguage)) {
                        Picker("", selection: $settings.language) {
                            ForEach(AppLanguage.allCases, id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                group(title: L10n.tr(.settingsBehavior)) {
                    row(L10n.tr(.fieldLaunchAtLogin)) {
                        Toggle("", isOn: $settings.launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider()
                    row(L10n.tr(.fieldShowMenuBarIcon)) {
                        Toggle("", isOn: $settings.showMenuBarIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider()
                    row(L10n.tr(.fieldWindowScope)) {
                        Picker("", selection: $settings.windowScope) {
                            ForEach(SBWindowScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldSortOrder)) {
                        Picker("", selection: $settings.sortOrder) {
                            ForEach(SBSortOrder.allCases) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldReducedMotion)) {
                        Toggle("", isOn: $settings.reducedMotion)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                group(title: L10n.tr(.settingsPrivacy)) {
                    row(L10n.tr(.fieldPreviewMode)) {
                        Picker("", selection: $settings.previewMode) {
                            ForEach(SBPreviewMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldHiddenApps)) {
                        TextField("", text: $settings.hiddenAppsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                    }
                }

                group(title: L10n.tr(.settingsHotkey)) {
                    row(L10n.tr(.fieldModifier)) {
                        Picker("", selection: $settings.modifier) {
                            ForEach(SBModifier.allCases) { m in Text(m.title).tag(m) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldTriggerKey)) {
                        Picker("", selection: $settings.triggerKey) {
                            ForEach(SBTriggerKey.allCases) { k in Text(k.title).tag(k) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    Text(L10n.tr(.fieldActiveCombo, "\(settings.modifier.title) + \(settings.triggerKey.title)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    divider()
                    row(L10n.tr(.fieldDoubleModifierSwitch)) {
                        Toggle("", isOn: $settings.doubleModifierSwitchEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider()
                    row(L10n.tr(.fieldDoubleModifier)) {
                        Picker("", selection: $settings.doubleModifier) {
                            ForEach(SBModifier.allCases) { m in Text(m.title).tag(m) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                group(title: L10n.tr(.settingsBackground)) {
                    row(L10n.tr(.fieldColor)) {
                        ColorPicker("", selection: bgColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize()
                    }
                    divider()
                    sliderRow(L10n.tr(.fieldOpacity), value: $settings.backgroundOpacity, in: 0.0...1.0, unit: "%", scale: 100)
                }

                group(title: L10n.tr(.settingsBadgeBar)) {
                    row(L10n.tr(.fieldPosition)) {
                        Picker("", selection: $settings.badgePosition) {
                            ForEach(SBBadgePosition.allCases) { p in Text(p.title).tag(p) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldAppIconColor)) {
                        Toggle("", isOn: $settings.badgeUseAppColor)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider()
                    row(L10n.tr(.fieldColor)) {
                        ColorPicker("", selection: badgeColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize()
                            .disabled(settings.badgeUseAppColor)
                            .opacity(settings.badgeUseAppColor ? 0.4 : 1)
                    }
                    divider()
                    sliderRow(L10n.tr(.fieldOpacity), value: $settings.badgeOpacity, in: 0.0...1.0, unit: "%", scale: 100)
                    divider()
                    sliderRow(L10n.tr(.fieldIconSize), value: $settings.badgeIconSize, in: 12...32, unit: "pt", scale: 1)
                    divider()
                    sliderRow(L10n.tr(.fieldTextSize), value: $settings.badgeFontSize, in: 9...16, unit: "pt", scale: 1)
                    divider()
                    sliderRow(L10n.tr(.fieldVerticalPadding), value: $settings.badgeVerticalPadding, in: 2...14, unit: "pt", scale: 1)
                }

                group(title: L10n.tr(.settingsSelection)) {
                    row(L10n.tr(.fieldAnimation)) {
                        Picker("", selection: $settings.selectionEffect) {
                            ForEach(SBSelectionEffect.allCases) { effect in
                                Text(effect.title).tag(effect)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldHighlightColor)) {
                        ColorPicker("", selection: highlightColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize()
                    }
                    divider()
                    sliderRow(L10n.tr(.fieldStrength), value: $settings.highlightStrength, in: 0.2...1.0, unit: "%", scale: 100)
                    divider()
                    sliderRow(L10n.tr(.fieldOpacity), value: $settings.highlightOpacity, in: 0.15...1.0, unit: "%", scale: 100)
                }

                group(title: L10n.tr(.settingsPreviewSize)) {
                    sliderRow(L10n.tr(.fieldMinWidth), value: $settings.tileMinWidth, in: 140...380, unit: "pt", scale: 1)
                }

                group(title: L10n.tr(.settingsAdvanced)) {
                    row(L10n.tr(.fieldPerformanceLogging)) {
                        Picker("", selection: $settings.performanceLogging) {
                            ForEach(SBPerformanceLogging.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider()
                    row(L10n.tr(.fieldResetAppearance)) {
                        Button(L10n.tr(.fieldResetAppearance)) {
                            settings.resetAppearanceDefaults()
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: 720)
    }

    // MARK: - helpers

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .padding(.bottom, 14)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, unit: String, scale: Double) -> some View {
        let step: Double = unit == "%" ? 0.05 : 1
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue * scale))\(unit)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func divider() -> some View {
        Divider().padding(.leading, 12)
    }
}
