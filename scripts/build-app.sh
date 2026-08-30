#!/bin/zsh

if [[ -z "${ZSH_VERSION:-}" ]]; then
    exec /bin/zsh "$0" "$@"
fi

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="SwitchBlade"
bundle_id="${BUNDLE_ID:-com.jannekammonen.SwitchBlade}"
version="${APP_VERSION:-0.1.0}"
build_number="${APP_BUILD_NUMBER:-1}"
build_timestamp="${APP_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
source_head="$(git -C "$repo_root" rev-parse HEAD)"
source_tree="$(git -C "$repo_root" write-tree)"
source_state="staged"
source_paths=(
    Package.swift
    Package.resolved
    Sources/SwitchBlade
    Sources/SwitchBladeCore
    scripts/build-app.sh
    scripts/signing-config.sh
    scripts/signing-safety.sh
    scripts/setup-local-codesign.sh
    scripts/sign-app-with-keychain.c
    scripts/atomic-replace.c
    scripts/generate-icon.swift
    scripts/verify_minimized_runtime_proof.py
)
if ! git -C "$repo_root" diff --quiet -- "${source_paths[@]}"; then
    source_state="working-copy"
fi
untracked_source_paths="$(
    git -C "$repo_root" ls-files --others --exclude-standard -- "${source_paths[@]}"
)"
if [[ -n "$untracked_source_paths" ]]; then
    source_state="working-copy"
fi

source "$repo_root/scripts/signing-config.sh"
source "$repo_root/scripts/signing-safety.sh"

original_user_keychains="$(switchblade_capture_user_keychain_search_list)" || {
    echo "ERROR: unable to capture the original user keychain search list." >&2
    exit 1
}
switchblade_assert_user_keychain_search_list_sane

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

sign_with_explicit_identity() {
    local expected_fingerprint="$1"
    local transient_password="switchblade-transient"

    (
        set +e

        local temp_dir temp_keychain temp_archive sign_status cleanup_status
        temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-codesign.XXXXXX")" || exit 1
        temp_keychain="$temp_dir/SwitchBladeCodesign.keychain"
        temp_archive="$temp_dir/identity.p12"

        cleanup_signing_state() {
            security delete-keychain "$temp_keychain" >/dev/null 2>&1 || true
            rm -rf "$temp_dir"
        }

        trap cleanup_signing_state EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        # The temporary keychain and temporary archive live in a mode-0700
        # directory. This fixed disposable value is not a persistent secret;
        # the actual archive password never appears in process arguments.
        security create-keychain -p "$transient_password" "$temp_keychain" >/dev/null
        sign_status=$?
        if (( sign_status == 0 )); then
            security unlock-keychain -p "$transient_password" "$temp_keychain" >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            security set-keychain-settings -lut 21600 "$temp_keychain" >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            # security import rejects PKCS#12 archives produced by some newer
            # Homebrew OpenSSL versions. Use macOS's matching system exporter
            # for the short-lived archive that is handed back to Security.framework.
            /usr/bin/openssl pkcs12 -export \
                -inkey "$SWITCHBLADE_CODESIGN_PRIVATE_KEY" \
                -in "$SWITCHBLADE_CODESIGN_CERTIFICATE" \
                -out "$temp_archive" \
                -passout pass:"$transient_password" >/dev/null 2>&1
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            chmod 600 "$temp_archive"
            # The key is broadly accessible only inside this short-lived,
            # unlisted keychain so the local helper can use its explicit
            # identity without a SecurityAgent prompt.
            security import "$temp_archive" \
                -k "$temp_keychain" \
                -P "$transient_password" \
                -A >/dev/null
            sign_status=$?
        fi
        if (( sign_status == 0 )); then
            "$signing_helper_binary" "$temp_keychain" "$expected_fingerprint" "$app_bundle"
            sign_status=$?
        fi

        trap - EXIT HUP INT TERM
        cleanup_signing_state
        cleanup_status=$?
        (( cleanup_status == 0 )) || exit "$cleanup_status"
        exit "$sign_status"
    )
}

output_dir="$repo_root/dist"
final_app_bundle="$output_dir/$app_name.app"
staging_app_bundle="$output_dir/.$app_name.app.staging.$$"
app_bundle="$staging_app_bundle"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_path="$contents_dir/Info.plist"
binary_path="$repo_root/.build/release/$app_name"
signing_helper_source="$repo_root/scripts/sign-app-with-keychain.c"
signing_helper_binary="$repo_root/.build/signing-tools/sign-app-with-keychain"
atomic_replace_source="$repo_root/scripts/atomic-replace.c"
atomic_replace_binary="$repo_root/.build/signing-tools/atomic-replace"

identity_name=""
expected_fingerprint=""
if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" != "1" ]]; then
    identity_name="$($repo_root/scripts/setup-local-codesign.sh)" || {
        echo "ERROR: local codesign setup failed; refusing ad-hoc fallback because it would reset TCC permissions. Use SWITCHBLADE_FORCE_ADHOC_SIGN=1 only for an explicit clean repro." >&2
        exit 1
    }
    expected_fingerprint="$(expected_signing_fingerprint)"
fi

switchblade_acquire_signing_lock

mkdir -p "$output_dir"
switchblade_secure_signing_material_permissions
switchblade_cleanup_stale_build_artifacts "${TMPDIR:-/tmp}" "$output_dir"

cleanup_staging_bundle() {
    rm -rf "$staging_app_bundle"
}

cleanup_staging_bundle
trap cleanup_staging_bundle EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$(dirname "$signing_helper_binary")"
if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" != "1" ]]; then
    xcrun clang \
        -std=c11 \
        -Wall \
        -Wextra \
        -Werror \
        -Wno-deprecated-declarations \
        -framework CoreFoundation \
        -framework Security \
        "$signing_helper_source" \
        -o "$signing_helper_binary"
fi
xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    "$atomic_replace_source" \
    -o "$atomic_replace_binary"

cd "$repo_root"
swift build -c release --product "$app_name"

mkdir -p "$macos_dir" "$resources_dir/en.lproj" "$resources_dir/fi.lproj"

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
    <key>SwitchBladeSourceHead</key>
    <string>$source_head</string>
    <key>SwitchBladeSourceState</key>
    <string>$source_state</string>
    <key>SwitchBladeSourceTree</key>
    <string>$source_tree</string>
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
</dict>
</plist>
EOF

cat > "$resources_dir/en.lproj/InfoPlist.strings" <<'EOF'
"NSScreenCaptureUsageDescription" = "SwitchBlade uses Screen Recording to show live window previews in the app switcher.";
EOF

cat > "$resources_dir/fi.lproj/InfoPlist.strings" <<'EOF'
"NSScreenCaptureUsageDescription" = "SwitchBlade käyttää näytön tallennusta ikkunoiden elävien esikatselujen näyttämiseen.";
EOF

if ! command -v codesign >/dev/null 2>&1; then
    echo "ERROR: codesign is unavailable; refusing to build an unsigned app bundle." >&2
    exit 1
fi

if [[ "${SWITCHBLADE_FORCE_ADHOC_SIGN:-0}" == "1" ]]; then
    codesign --force --deep --sign - "$app_bundle"
    echo "Signed ad-hoc because SWITCHBLADE_FORCE_ADHOC_SIGN=1"
else
    if sign_with_explicit_identity "$expected_fingerprint"; then
        echo "Signed with identity: $identity_name ($expected_fingerprint)"
    else
        echo "ERROR: stable local identity signing failed; refusing ad-hoc fallback because it would reset TCC permissions. Use SWITCHBLADE_FORCE_ADHOC_SIGN=1 only for an explicit clean repro." >&2
        exit 1
    fi
fi

assert_expected_signature
switchblade_assert_user_keychain_search_list_unchanged "$original_user_keychains"
switchblade_assert_user_keychain_search_list_sane
if [[ "${SWITCHBLADE_FAIL_BEFORE_PUBLISH:-0}" == "1" ]]; then
    echo "ERROR: injected failure before atomic app publication." >&2
    exit 1
fi
"$atomic_replace_binary" "$staging_app_bundle" "$final_app_bundle"
rm -rf "$staging_app_bundle"
trap - EXIT HUP INT TERM

echo "Built $final_app_bundle"
