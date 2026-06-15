#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="SwitchBlade"
bundle_id="${BUNDLE_ID:-com.jannekammonen.SwitchBlade}"
version="${APP_VERSION:-0.1.0}"
build_number="${APP_BUILD_NUMBER:-1}"
build_timestamp="${APP_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

source "$repo_root/scripts/signing-config.sh"

normalize_sha1() {
    tr -d ':\n\r ' | tr 'A-F' 'a-f'
}

certificate_sha1() {
    openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//' | normalize_sha1
}

expected_signing_fingerprint() {
    if [[ -f "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE" ]]; then
        normalize_sha1 < "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE"
        return
    fi
    certificate_sha1 "$SWITCHBLADE_CODESIGN_CERTIFICATE"
}

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

assert_expected_signature() {
    codesign --verify --deep --strict "$app_bundle" >/dev/null

    if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" == "1" ]]; then
        return 0
    fi

    local requirement_output actual_fingerprint expected_fingerprint
    requirement_output="$(codesign -dv --requirements - "$app_bundle" 2>&1)"
    actual_fingerprint="$(
        sed -n 's/.*designated => identifier "[^"]*" and certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"$requirement_output" \
            | normalize_sha1
    )"
    expected_fingerprint="$(expected_signing_fingerprint)"
    if [[ -z "$actual_fingerprint" ]] || ! grep -Fq "designated => identifier \"$bundle_id\"" <<<"$requirement_output"; then
        echo "ERROR: built app is not signed with the stable local designated requirement." >&2
        echo "$requirement_output" >&2
        exit 1
    fi
    if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
        echo "ERROR: built app was signed with the wrong local certificate fingerprint." >&2
        echo "Expected: $expected_fingerprint" >&2
        echo "Actual:   $actual_fingerprint" >&2
        echo "$requirement_output" >&2
        exit 1
    fi
}

sign_with_local_identity() {
    local expected_fingerprint="$1"
    local keychain_password
    keychain_password="$(<"$SWITCHBLADE_CODESIGN_PASSWORD_FILE")"

    (
        set +e

        local temp_dir temp_keychain identity_hash expected_fingerprint_upper
        temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-codesign.XXXXXX")"
        temp_keychain="$temp_dir/SwitchBladeCodesign.keychain"
        expected_fingerprint_upper="$(printf '%s' "$expected_fingerprint" | tr 'a-f' 'A-F')"
        local original_keychains=()
        while IFS= read -r keychain; do
            [[ -n "$keychain" ]] && original_keychains+=("$keychain")
        done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')

        restore_original_keychains() {
            if (( ${#original_keychains[@]} > 0 )); then
                security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
            else
                security list-keychains -d user -s >/dev/null 2>&1 || true
            fi
        }

        cleanup_signing_state() {
            restore_original_keychains
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
            if (( ${#original_keychains[@]} > 0 )); then
                security list-keychains -d user -s "$temp_keychain" "${original_keychains[@]}" >/dev/null
                sign_status=$?
            else
                security list-keychains -d user -s "$temp_keychain" >/dev/null
                sign_status=$?
            fi
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
            identity_hash="$(
                security find-identity -v -p codesigning "$temp_keychain" \
                    | awk -v hash="$expected_fingerprint_upper" '$2 == hash { print $2; exit }'
            )"
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

if ! command -v codesign >/dev/null 2>&1; then
    echo "ERROR: codesign is unavailable; refusing to build an unsigned app bundle." >&2
    exit 1
fi

if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" == "1" ]]; then
    codesign --force --deep --sign - "$app_bundle"
    echo "Signed ad-hoc because SWITCHBLADE_FORCE_ADHOC_SIGN=1"
elif identity_name="$($repo_root/scripts/setup-local-codesign.sh)"; then
    expected_fingerprint="$(expected_signing_fingerprint)"
    if sign_with_local_identity "$expected_fingerprint"; then
        echo "Signed with identity: $identity_name ($expected_fingerprint)"
    else
        echo "ERROR: local identity signing failed; refusing ad-hoc fallback because it would reset TCC permissions. Use SWITCHBLADE_FORCE_ADHOC_SIGN=1 only for an explicit clean repro." >&2
        exit 1
    fi
else
    echo "ERROR: local codesign setup failed; refusing ad-hoc fallback because it would reset TCC permissions. Use SWITCHBLADE_FORCE_ADHOC_SIGN=1 only for an explicit clean repro." >&2
    exit 1
fi

assert_expected_signature
assert_keychain_search_list_sane

echo "Built $app_bundle"
