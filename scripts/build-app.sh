#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="SwitchBlade"
bundle_id="${BUNDLE_ID:-com.jannekammonen.SwitchBlade}"
version="${APP_VERSION:-0.1.0}"
build_number="${APP_BUILD_NUMBER:-1}"
build_timestamp="${APP_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

source "$repo_root/scripts/signing-config.sh"

output_dir="$repo_root/dist"
app_bundle="$output_dir/$app_name.app"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_path="$contents_dir/Info.plist"
binary_path="$repo_root/.build/release/$app_name"

mkdir -p "$output_dir"

cd "$repo_root"
swift build -c release --product "$app_name"

rm -rf "$app_bundle"
mkdir -p "$macos_dir" "$resources_dir"

cp "$binary_path" "$macos_dir/$app_name"
chmod +x "$macos_dir/$app_name"

# Generate app icon
icon_icns="$resources_dir/AppIcon.icns"
swift "$repo_root/scripts/generate-icon.swift" "$icon_icns"

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$app_name</string>
    <key>CFBundleExecutable</key>
    <string>$app_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>SwitchBladeBuildTimestamp</key>
    <string>$build_timestamp</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>SwitchBlade uses Screen Recording to show live window previews in the app switcher.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>SwitchBlade uses Accessibility to switch and manage windows.</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
    if identity_name="$($repo_root/scripts/setup-local-codesign.sh 2>/dev/null)"; then
        if [[ -f "$SWITCHBLADE_CODESIGN_PASSWORD_FILE" ]]; then
            keychain_password="$(<"$SWITCHBLADE_CODESIGN_PASSWORD_FILE")"
            security unlock-keychain -p "$keychain_password" "$SWITCHBLADE_CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
        fi

        # Add the SwitchBlade keychain to the user search list without disturbing
        # existing entries (bash-compatible; zsh (f) flag not used here).
        existing_keychains="$(security list-keychains -d user | tr -d '"' | tr -s ' \n' ' ')"
        security list-keychains -d user -s "$SWITCHBLADE_CODESIGN_KEYCHAIN" $existing_keychains >/dev/null 2>&1 || true

        identity_hash="$(security find-identity -v -p codesigning "$SWITCHBLADE_CODESIGN_KEYCHAIN" | awk -v name="$identity_name" '$0 ~ name { print $2; exit }')"

        if [[ -n "$identity_hash" ]]; then
            codesign --force --deep --sign "$identity_hash" --keychain "$SWITCHBLADE_CODESIGN_KEYCHAIN" "$app_bundle"
            echo "Signed with identity: $identity_name"
        else
            codesign --force --deep --sign - "$app_bundle"
            echo "Warning: local identity not found, used ad-hoc signing (TCC permissions will reset on rebuild)"
        fi
    else
        codesign --force --deep --sign - "$app_bundle"
    fi
fi

echo "Built $app_bundle"
