#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="SwitchBlade"
bundle_id="${BUNDLE_ID:-com.jannekammonen.SwitchBlade}"
version="${APP_VERSION:-0.1.0}"
build_number="${APP_BUILD_NUMBER:-1}"
build_timestamp="${APP_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

source "$repo_root/scripts/signing-config.sh"

assert_keychain_search_list_sane() {
    local keychain_count
    keychain_count="$(security list-keychains -d user | wc -l | tr -d ' ')"
    if (( keychain_count > 3 )); then
        echo "ERROR: keychain search list has $keychain_count entries; possible build signing regression." >&2
        security list-keychains -d user >&2
        exit 1
    fi

    if security list-keychains -d user | grep -Eq '"/Users/[^"]+/Library/Application"$|"/Users/[^"]+/Library/Keychains/Support/'; then
        echo "ERROR: keychain search list contains broken SwitchBlade path fragments." >&2
        security list-keychains -d user >&2
        exit 1
    fi
}

sign_with_local_identity() {
    local identity_name="$1"
    local keychain_password
    keychain_password="$(<"$SWITCHBLADE_CODESIGN_PASSWORD_FILE")"

    (
        set +e

        local temp_dir temp_keychain identity_hash
        temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-codesign.XXXXXX")"
        temp_keychain="$temp_dir/SwitchBladeCodesign.keychain"
        local original_keychains=()
        while IFS= read -r keychain; do
            [[ -n "$keychain" ]] && original_keychains+=("$keychain")
        done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')

        cleanup_signing_state() {
            security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
            rm -rf "$temp_dir"
        }

        # EXIT trap makes the restore path run even when signing is interrupted.
        trap cleanup_signing_state EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        security create-keychain -p "$keychain_password" "$temp_keychain" >/dev/null
        local sign_status=$?
        if (( sign_status == 0 )); then
            security unlock-keychain -p "$keychain_password" "$temp_keychain" >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            security set-keychain-settings -lut 21600 "$temp_keychain" >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            security list-keychains -d user -s "$temp_keychain" "${original_keychains[@]}" >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            security import "$SWITCHBLADE_CODESIGN_ARCHIVE" \
            -k "$temp_keychain" \
            -P "$keychain_password" \
            -T /usr/bin/codesign \
            -T /usr/bin/security >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$temp_keychain" >/dev/null
            sign_status=$?
        fi

        if (( sign_status == 0 )); then
            identity_hash="$(security find-identity -v -p codesigning "$temp_keychain" | awk -v name="$identity_name" '$0 ~ name { print $2; exit }')"
            [[ -n "$identity_hash" ]]
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            codesign --force --deep --sign "$identity_hash" --keychain "$temp_keychain" "$app_bundle"
            sign_status=$?
        fi

        exit "$sign_status"
    )
}

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
    if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" == "1" ]]; then
        codesign --force --deep --sign - "$app_bundle"
        echo "Signed ad-hoc because SWITCHBLADE_FORCE_ADHOC_SIGN=1"
    elif identity_name="$($repo_root/scripts/setup-local-codesign.sh 2>/dev/null)"; then
        if sign_with_local_identity "$identity_name"; then
            echo "Signed with identity: $identity_name"
        else
            codesign --force --deep --sign - "$app_bundle"
            echo "Warning: local identity not found, used ad-hoc signing (TCC permissions will reset on rebuild)"
        fi
    else
        codesign --force --deep --sign - "$app_bundle"
        echo "Warning: local codesign setup failed, used ad-hoc signing (TCC permissions will reset on rebuild)"
    fi
fi

assert_keychain_search_list_sane

echo "Built $app_bundle"
