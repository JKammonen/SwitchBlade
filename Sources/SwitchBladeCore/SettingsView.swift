import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SwitchBladeSettings
    var permissionState: PermissionState? = nil
    var onOpenPermissionSettings: ((PermissionKind) -> Void)? = nil

    private var relevantMissingPermissions: [PermissionKind] {
        permissionState?.missingPermissions(for: settings.previewMode) ?? []
    }

    static func objectSelectorWidthBinding(settings: SwitchBladeSettings) -> Binding<Double> {
        Binding(
            get: { settings.selectorWidthFraction },
            set: { newValue in settings.selectorWidthFraction = newValue }
        )
    }

    private var hiddenAppRuleSummary: String {
        let counts = settings.hiddenAppRuleCounts
        return String(
            format: L10n.tr(.hiddenAppsParsedSummary),
            counts.substring,
            counts.exact
        )
    }

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

                if !relevantMissingPermissions.isEmpty {
                    group(title: L10n.tr(.settingsPermissions)) {
                        ForEach(relevantMissingPermissions, id: \.rawValue) { permission in
                            permissionRecoveryRow(permission)
                        }
                    }
                }

                group(title: L10n.tr(.settingsBehavior)) {
                    statusRow(
                        L10n.tr(.fieldLaunchAtLogin),
                        status: settings.launchAtLoginStatus.title,
                        statusColor: settings.launchAtLoginStatus.isFailure ? .red : .secondary
                    ) {
                        HStack(spacing: 8) {
                            if settings.launchAtLoginStatus == .requiresApproval {
                                Button(L10n.tr(.actionOpenLoginItemsSettings)) {
                                    LaunchAtLoginController.openSystemSettings()
                                }
                                .controlSize(.small)
                            }
                            Toggle("", isOn: $settings.launchAtLogin)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!settings.launchAtLoginStatus.allowsUserToggle)
                                .accessibilityLabel(Text(L10n.tr(.fieldLaunchAtLogin)))
                        }
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
                    VStack(alignment: .leading, spacing: 5) {
                        row(L10n.tr(.fieldHiddenApps)) {
                            TextField("", text: $settings.hiddenAppsText)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 180, idealWidth: 230)
                        }
                        Text(L10n.tr(.fieldHiddenAppsHelp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(L10n.tr(.fieldHiddenAppsHelp)))
                            .padding(.horizontal, 12)
                        Text(hiddenAppRuleSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
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
                    if let conflict = settings.shortcutConflict {
                        Text(conflict.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                            .accessibilityLabel(Text(conflict.message))
                    }
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
                        .disabled(!settings.doubleModifierSwitchEnabled)
                        .opacity(settings.doubleModifierSwitchEnabled ? 1 : 0.45)
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
                    sliderRow(L10n.tr(.fieldColorStrength), value: $settings.badgeOpacity, in: 0.0...1.0, unit: "%", scale: 100)
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
                    sliderRow(L10n.tr(.fieldWidth), value: $settings.tileMinWidth, in: 140...380, unit: "pt", scale: 1)
                }

                group(title: L10n.tr(.settingsObjectSelector)) {
                    sliderRow(
                        L10n.tr(.fieldMaxWidth),
                        value: Self.objectSelectorWidthBinding(settings: settings),
                        in: 0.5...0.95,
                        unit: "%",
                        scale: 100
                    )
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
                    Button(L10n.tr(.fieldResetAppearance)) {
                        settings.resetAppearanceDefaults()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 380, idealWidth: 420, maxWidth: .infinity)
        .frame(minHeight: 420, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - helpers

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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

    private func permissionRecoveryRow(_ permission: PermissionKind) -> some View {
        HStack(spacing: 12) {
            Text(permission.title)
                .font(.body)
            Spacer(minLength: 12)
            Button(L10n.tr(.permissionActionOpenSettings)) {
                onOpenPermissionSettings?(permission)
            }
            .disabled(onOpenPermissionSettings == nil)
            .accessibilityLabel(Text(
                String(format: L10n.tr(.menuOpenPermissionSettings), permission.title)
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            trailing()
                .accessibilityLabel(Text(label))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
    }

    private func statusRow<Content: View>(
        _ label: String,
        status: String,
        statusColor: Color,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 50)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, unit: String, scale: Double) -> some View {
        let step: Double = unit == "%" ? 0.05 : 1
        return HStack(spacing: 10) {
            Text(label)
                .font(.body)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(Text(label))
            Text("\(Int(value.wrappedValue * scale))\(unit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
    }

    private func divider() -> some View {
        Divider().padding(.leading, 12)
    }
}
