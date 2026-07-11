#!/bin/zsh

if [[ -z "${ZSH_VERSION:-}" ]]; then
    exec /bin/zsh "$0" "$@"
fi

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/signing-config.sh"
source "$repo_root/scripts/signing-safety.sh"

if [[ "${SWITCHBLADE_REMOVE_LOGIN_IDENTITY:-0}" != "1" ]]; then
    echo "ERROR: this repair deletes only the exact SwitchBlade private key from the login keychain." >&2
    echo "Re-run with SWITCHBLADE_REMOVE_LOGIN_IDENTITY=1 after reading the command." >&2
    exit 1
fi

normalize_sha1() {
    tr -d ':\n\r ' | tr 'A-F' 'a-f'
}

certificate_sha1() {
    openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//' | normalize_sha1
}

security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
helper_source="$repo_root/scripts/remove-keychain-private-key.c"
helper_binary="${SWITCHBLADE_REMOVE_PRIVATE_KEY_HELPER:-$repo_root/.build/signing-tools/remove-keychain-private-key}"

switchblade_acquire_signing_lock
mkdir -p "$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
switchblade_secure_signing_material_permissions

original_user_keychains="$(switchblade_capture_user_keychain_search_list)" || {
    echo "ERROR: unable to capture the original user keychain search list." >&2
    exit 1
}
switchblade_assert_user_keychain_search_list_sane

if [[ ! -f "$SWITCHBLADE_CODESIGN_CERTIFICATE" \
   || ! -f "$SWITCHBLADE_CODESIGN_PRIVATE_KEY" \
   || ! -f "$SWITCHBLADE_CODESIGN_ARCHIVE" \
   || ! -f "$SWITCHBLADE_CODESIGN_PASSWORD_FILE" \
   || ! -f "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE" ]]; then
    echo "ERROR: the complete stable SwitchBlade recovery material is required before login-keychain repair." >&2
    exit 1
fi

expected_fingerprint="$(certificate_sha1 "$SWITCHBLADE_CODESIGN_CERTIFICATE")"
recorded_fingerprint="$(normalize_sha1 < "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE")"
if [[ "$recorded_fingerprint" != "$expected_fingerprint" ]]; then
    echo "ERROR: certificate fingerprint metadata is drifted; repair that state before touching the login keychain." >&2
    exit 1
fi
certificate_public_key="$(
    openssl x509 -in "$SWITCHBLADE_CODESIGN_CERTIFICATE" -pubkey -noout \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | shasum -a 256 \
        | awk '{ print $1 }'
)"
private_key_public_key="$(
    openssl pkey -in "$SWITCHBLADE_CODESIGN_PRIVATE_KEY" -pubout -outform der 2>/dev/null \
        | shasum -a 256 \
        | awk '{ print $1 }'
)"
if [[ -z "$certificate_public_key" || "$certificate_public_key" != "$private_key_public_key" ]]; then
    echo "ERROR: certificate and private-key recovery material do not match; refusing login-keychain repair." >&2
    exit 1
fi
if ! switchblade_archive_matches_material \
    "$SWITCHBLADE_CODESIGN_ARCHIVE" \
    "$SWITCHBLADE_CODESIGN_PASSWORD_FILE" \
    "$SWITCHBLADE_CODESIGN_CERTIFICATE" \
    "$SWITCHBLADE_CODESIGN_PRIVATE_KEY"; then
    echo "ERROR: the recovery archive does not match the canonical certificate and private key; refusing login-keychain repair." >&2
    exit 1
fi

login_keychain="$(switchblade_login_keychain)"
switchblade_assert_keychain_is_in_user_search_list "$login_keychain"

ensure_public_certificate() {
    if switchblade_keychain_contains_certificate "$login_keychain" "$expected_fingerprint" \
        && switchblade_verify_codesign_certificate "$SWITCHBLADE_CODESIGN_CERTIFICATE"; then
        return 0
    fi

    echo "macOS may ask once for permission to restore the SwitchBlade public signing certificate." >&2
    "$security_bin" add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$login_keychain" \
        "$SWITCHBLADE_CODESIGN_CERTIFICATE" >/dev/null

    switchblade_keychain_contains_certificate "$login_keychain" "$expected_fingerprint" \
        && switchblade_verify_codesign_certificate "$SWITCHBLADE_CODESIGN_CERTIFICATE"
}

# Restoring the public certificate first makes this command idempotent even if
# an older, interrupted repair removed the certificate.
ensure_public_certificate

identity_hash="$(switchblade_find_valid_identity_hash "$login_keychain" "$expected_fingerprint")"
if [[ -n "$identity_hash" ]]; then
    if [[ -z "${SWITCHBLADE_REMOVE_PRIVATE_KEY_HELPER:-}" ]]; then
        mkdir -p "$(dirname "$helper_binary")"
        xcrun clang \
            -std=c11 \
            -Wall \
            -Wextra \
            -Werror \
            -Wno-deprecated-declarations \
            -framework CoreFoundation \
            -framework Security \
            "$helper_source" \
            -o "$helper_binary"
    elif [[ ! -x "$helper_binary" ]]; then
        echo "ERROR: configured private-key removal helper is not executable: $helper_binary" >&2
        exit 1
    fi

    echo "macOS may ask once for keychain access while the exact duplicate SwitchBlade private key is removed." >&2
    "$helper_binary" "$login_keychain" "$expected_fingerprint"
fi

ensure_public_certificate
if [[ -n "$(switchblade_find_valid_identity_hash "$login_keychain" "$expected_fingerprint")" ]]; then
    echo "ERROR: the duplicate SwitchBlade private identity is still present after repair." >&2
    exit 1
fi

switchblade_assert_user_keychain_search_list_unchanged "$original_user_keychains"
switchblade_assert_user_keychain_search_list_sane
echo "SwitchBlade login-keychain state is repaired: public certificate retained, private key absent."
