#!/bin/zsh

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/signing-config.sh"
source "$repo_root/scripts/signing-safety.sh"

switchblade_acquire_signing_lock
switchblade_cleanup_stale_build_artifacts "${TMPDIR:-/tmp}" "$repo_root/dist"

original_user_keychains="$(switchblade_capture_user_keychain_search_list)" || {
    echo "ERROR: unable to capture the original user keychain search list." >&2
    exit 1
}
switchblade_assert_user_keychain_search_list_sane

identity_name="$SWITCHBLADE_CODESIGN_IDENTITY_NAME"
support_dir="$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
keychain_password_file="$SWITCHBLADE_CODESIGN_PASSWORD_FILE"
openssl_config="$support_dir/openssl-codesign.cnf"
private_key_path="$SWITCHBLADE_CODESIGN_PRIVATE_KEY"
certificate_path="$SWITCHBLADE_CODESIGN_CERTIFICATE"
archive_path="$SWITCHBLADE_CODESIGN_ARCHIVE"
fingerprint_file="$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE"

mkdir -p "$support_dir"
switchblade_secure_signing_material_permissions

normalize_sha1() {
    tr -d ':\n\r ' | tr 'A-F' 'a-f'
}

certificate_sha1() {
    openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//' | normalize_sha1
}

generate_password() {
    openssl rand -hex 16
}

write_password_file() {
    local password="$1"
    printf '%s' "$password" > "$keychain_password_file"
    chmod 600 "$keychain_password_file"
}

archive_password_valid() {
    [[ -f "$archive_path" && -f "$keychain_password_file" ]] || return 1
    openssl pkcs12 -in "$archive_path" -passin file:"$keychain_password_file" -info -noout >/dev/null 2>&1
}

material_public_key_sha256() {
    openssl x509 -in "$certificate_path" -pubkey -noout \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | shasum -a 256 \
        | awk '{ print $1 }'
}

key_public_key_sha256() {
    openssl pkey -in "$private_key_path" -pubout -outform der 2>/dev/null \
        | shasum -a 256 \
        | awk '{ print $1 }'
}

cert_and_key_match() {
    [[ -f "$certificate_path" && -f "$private_key_path" ]] || return 1
    [[ "$(material_public_key_sha256)" == "$(key_public_key_sha256)" ]]
}

write_fingerprint_file() {
    local fingerprint="$1"
    printf '%s\n' "$fingerprint" > "$fingerprint_file"
    chmod 600 "$fingerprint_file"
}

require_explicit_reset() {
    echo "ERROR: local codesign material is in an unrecoverable or drifted state." >&2
    echo "Set SWITCHBLADE_RESET_LOCAL_CODESIGN=1 once to intentionally generate a new local cert (this will reset TCC permissions)." >&2
    exit 1
}

generate_certificate_and_key() {
    cat > "$openssl_config" <<EOF
[ req ]
default_bits = 2048
distinguished_name = dn
x509_extensions = extensions
prompt = no

[ dn ]
CN = $identity_name
O = SwitchBlade

[ extensions ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

    openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
        -config "$openssl_config" \
        -keyout "$private_key_path" \
        -out "$certificate_path" >/dev/null 2>&1

    chmod 600 "$private_key_path" "$certificate_path"
}

export_archive_from_material() {
    openssl pkcs12 -export \
        -inkey "$private_key_path" \
        -in "$certificate_path" \
        -out "$archive_path" \
        -passout file:"$keychain_password_file" >/dev/null 2>&1
    chmod 600 "$archive_path"
}

extract_material_from_archive() {
    openssl pkcs12 -in "$archive_path" -passin file:"$keychain_password_file" -clcerts -nokeys 2>/dev/null \
        | openssl x509 -out "$certificate_path" >/dev/null 2>&1
    openssl pkcs12 -in "$archive_path" -passin file:"$keychain_password_file" -nocerts -nodes 2>/dev/null \
        | openssl pkey -out "$private_key_path" >/dev/null 2>&1
    chmod 600 "$private_key_path" "$certificate_path"
}

validated_archive_fingerprint() (
    set -e
    local inspection_dir inspection_certificate inspection_key
    local certificate_public_key key_public_key

    [[ -f "$archive_path" && -f "$keychain_password_file" ]] || return 1
    inspection_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-archive-inspection.XXXXXX")"
    trap 'rm -rf "$inspection_dir"' EXIT
    inspection_certificate="$inspection_dir/certificate.pem"
    inspection_key="$inspection_dir/private-key.pem"

    openssl pkcs12 \
        -in "$archive_path" \
        -passin file:"$keychain_password_file" \
        -clcerts \
        -nokeys 2>/dev/null \
        | openssl x509 -out "$inspection_certificate" >/dev/null 2>&1
    openssl pkcs12 \
        -in "$archive_path" \
        -passin file:"$keychain_password_file" \
        -nocerts \
        -nodes 2>/dev/null \
        | openssl pkey -out "$inspection_key" >/dev/null 2>&1

    certificate_public_key="$(
        openssl x509 -in "$inspection_certificate" -pubkey -noout \
            | openssl pkey -pubin -outform der 2>/dev/null \
            | shasum -a 256 \
            | awk '{ print $1 }'
    )"
    key_public_key="$(
        openssl pkey -in "$inspection_key" -pubout -outform der 2>/dev/null \
            | shasum -a 256 \
            | awk '{ print $1 }'
    )"
    [[ -n "$certificate_public_key" && "$certificate_public_key" == "$key_public_key" ]]
    certificate_sha1 "$inspection_certificate"
)

material_is_trusted_and_published() {
    local fingerprint="$1"
    local login_keychain published_app requirement_output published_fingerprint
    local expected_bundle_id="${BUNDLE_ID:-com.jannekammonen.SwitchBlade}"

    login_keychain="$(switchblade_login_keychain)"
    switchblade_assert_keychain_is_in_user_search_list "$login_keychain" >/dev/null 2>&1 \
        || return 1
    switchblade_keychain_contains_certificate "$login_keychain" "$fingerprint" \
        || return 1
    switchblade_verify_codesign_certificate "$certificate_path" \
        || return 1

    published_app="$repo_root/dist/SwitchBlade.app"
    [[ -d "$published_app" ]] || return 1
    codesign --verify --deep --strict "$published_app" >/dev/null 2>&1 || return 1
    [[ "$(plutil -extract CFBundleIdentifier raw "$published_app/Contents/Info.plist" 2>/dev/null)" == "$expected_bundle_id" ]] \
        || return 1
    requirement_output="$(codesign -dv --requirements - "$published_app" 2>&1)" || return 1
    published_fingerprint="$(
        sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"$requirement_output" \
            | normalize_sha1
    )"
    [[ -n "$published_fingerprint" && "$published_fingerprint" == "$fingerprint" ]]
}

ensure_login_keychain_certificate() {
    local expected_fingerprint="$1"
    local login_keychain identity_hash
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"

    login_keychain="$(switchblade_login_keychain)"
    switchblade_assert_keychain_is_in_user_search_list "$login_keychain"

    # The login keychain carries only the public trust anchor. Cleanup is never
    # automatic here: deleting an identity also deletes its certificate, and a
    # crash between delete and re-import would break noninteractive builds.
    identity_hash="$(switchblade_find_valid_identity_hash "$login_keychain" "$expected_fingerprint")"
    if [[ -n "$identity_hash" ]]; then
        echo "ERROR: a duplicate SwitchBlade private identity exists in the login keychain." >&2
        echo "Refusing automatic deletion because it would create a crash-sensitive certificate gap." >&2
        echo "Run this explicit repair command, approve its keychain prompt, then rebuild:" >&2
        echo "  SWITCHBLADE_REMOVE_LOGIN_IDENTITY=1 \"$repo_root/scripts/remove-login-codesign-identity.sh\"" >&2
        exit 1
    fi

    if switchblade_keychain_contains_certificate "$login_keychain" "$expected_fingerprint" \
        && switchblade_verify_codesign_certificate "$certificate_path"; then
        return 0
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "ERROR: the stable local codesign certificate is absent from the login keychain or is not trusted." >&2
        echo "Run this once in an interactive terminal, approve the macOS prompt, then rebuild:" >&2
        echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$login_keychain\" \"$certificate_path\"" >&2
        exit 1
    fi

    echo "Approve the macOS prompt once to trust the stable SwitchBlade signing certificate." >&2
    "$security_bin" add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$certificate_path" >/dev/null

    if ! switchblade_keychain_contains_certificate "$login_keychain" "$expected_fingerprint" \
        || ! switchblade_verify_codesign_certificate "$certificate_path"; then
        echo "ERROR: the stable local codesign certificate is still unavailable after the trust step." >&2
        exit 1
    fi
}

if [[ "${SWITCHBLADE_RESET_LOCAL_CODESIGN:-0}" == "1" ]]; then
    rm -f \
        "$keychain_password_file" \
        "$private_key_path" \
        "$certificate_path" \
        "$archive_path" \
        "$fingerprint_file" \
        "$openssl_config"
fi

has_cert=0
has_key=0
has_archive=0
has_password=0
has_fingerprint=0
[[ -f "$certificate_path" ]] && has_cert=1
[[ -f "$private_key_path" ]] && has_key=1
[[ -f "$archive_path" ]] && has_archive=1
[[ -f "$keychain_password_file" ]] && has_password=1
[[ -f "$fingerprint_file" ]] && has_fingerprint=1

if (( ! has_cert && ! has_key && ! has_archive && (has_password || has_fingerprint) )); then
    require_explicit_reset
fi

if (( ! has_cert && ! has_key && ! has_archive )); then
    write_password_file "$(generate_password)"
    generate_certificate_and_key
    export_archive_from_material
    has_cert=1
    has_key=1
    has_archive=1
    has_password=1
fi

material_is_coherent=0
material_fingerprint=""
if (( has_cert && has_key )) && cert_and_key_match; then
    material_is_coherent=1
    material_fingerprint="$(certificate_sha1 "$certificate_path")"
fi

archive_is_recoverable=0
archive_fingerprint=""
if (( has_archive && has_password )); then
    if archive_fingerprint="$(validated_archive_fingerprint)"; then
        archive_is_recoverable=1
    fi
fi

recorded_fingerprint=""
repair_fingerprint_metadata=0
if (( has_fingerprint )); then
    recorded_fingerprint="$(normalize_sha1 < "$fingerprint_file")"
    if [[ ! "$recorded_fingerprint" =~ '^[0-9a-f]{40}$' ]]; then
        if [[ "${SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT:-0}" == "1" ]] \
            && (( material_is_coherent && archive_is_recoverable )) \
            && [[ "$material_fingerprint" == "$archive_fingerprint" ]] \
            && material_is_trusted_and_published "$material_fingerprint"; then
            recorded_fingerprint="$material_fingerprint"
            repair_fingerprint_metadata=1
        else
            echo "ERROR: local codesign fingerprint metadata is malformed; refusing to change signing material." >&2
            echo "SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT=1 can repair it only when certificate, key, archive, trust, and the published app all prove the same identity." >&2
            exit 1
        fi
    fi
fi

canonical_fingerprint=""
if (( has_fingerprint )); then
    if (( archive_is_recoverable )) && [[ "$archive_fingerprint" == "$recorded_fingerprint" ]]; then
        canonical_fingerprint="$recorded_fingerprint"
        if (( ! material_is_coherent )) || [[ "$material_fingerprint" != "$canonical_fingerprint" ]]; then
            extract_material_from_archive
            material_is_coherent=1
            material_fingerprint="$(certificate_sha1 "$certificate_path")"
        fi
    elif (( material_is_coherent )) && [[ "$material_fingerprint" == "$recorded_fingerprint" ]]; then
        canonical_fingerprint="$recorded_fingerprint"
    elif [[ "${SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT:-0}" == "1" ]] \
        && (( material_is_coherent && archive_is_recoverable )) \
        && [[ "$material_fingerprint" == "$archive_fingerprint" ]] \
        && material_is_trusted_and_published "$material_fingerprint"; then
        canonical_fingerprint="$material_fingerprint"
        repair_fingerprint_metadata=1
    else
        echo "ERROR: no recoverable certificate/key/archive set matches the recorded codesign fingerprint." >&2
        echo "No signing material was overwritten. Use SWITCHBLADE_RESET_LOCAL_CODESIGN=1 only if intentional identity rotation and TCC reset are acceptable." >&2
        if [[ "${SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT:-0}" != "1" ]]; then
            echo "SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT=1 is accepted only when the coherent material is already both trusted and used by the published app." >&2
        fi
        exit 1
    fi
elif (( archive_is_recoverable )); then
    if (( material_is_coherent )) && [[ "$material_fingerprint" != "$archive_fingerprint" ]]; then
        if material_is_trusted_and_published "$material_fingerprint"; then
            canonical_fingerprint="$material_fingerprint"
        else
            echo "ERROR: fingerprint metadata is missing and the recoverable archive conflicts with the coherent certificate/key." >&2
            echo "Neither source was overwritten because the canonical identity cannot be proven from the trusted published app." >&2
            exit 1
        fi
    else
        canonical_fingerprint="$archive_fingerprint"
    fi
    if (( ! material_is_coherent )) || [[ "$material_fingerprint" != "$canonical_fingerprint" ]]; then
        extract_material_from_archive
        material_is_coherent=1
        material_fingerprint="$(certificate_sha1 "$certificate_path")"
    fi
elif (( material_is_coherent )); then
    canonical_fingerprint="$material_fingerprint"
else
    require_explicit_reset
fi

if (( ! material_is_coherent )) || [[ "$material_fingerprint" != "$canonical_fingerprint" ]]; then
    echo "ERROR: canonical codesign recovery did not produce a coherent certificate and private key." >&2
    exit 1
fi

if (( ! has_password )) || (( has_archive && ! archive_is_recoverable )); then
    write_password_file "$(generate_password)"
    has_password=1
fi

if (( ! archive_is_recoverable )) \
    || [[ "$archive_fingerprint" != "$canonical_fingerprint" ]] \
    || ! switchblade_archive_matches_material \
        "$archive_path" \
        "$keychain_password_file" \
        "$certificate_path" \
        "$private_key_path"; then
    export_archive_from_material
    archive_fingerprint="$(validated_archive_fingerprint)"
    if [[ "$archive_fingerprint" != "$canonical_fingerprint" ]]; then
        echo "ERROR: regenerated codesign archive does not match the canonical fingerprint." >&2
        exit 1
    fi
fi

if (( ! has_fingerprint || repair_fingerprint_metadata )); then
    write_fingerprint_file "$canonical_fingerprint"
fi

ensure_login_keychain_certificate "$canonical_fingerprint"

switchblade_assert_user_keychain_search_list_unchanged "$original_user_keychains"
switchblade_assert_user_keychain_search_list_sane

echo "$identity_name"
