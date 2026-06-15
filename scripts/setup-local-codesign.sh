#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/signing-config.sh"

identity_name="$SWITCHBLADE_CODESIGN_IDENTITY_NAME"
support_dir="$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
keychain_password_file="$SWITCHBLADE_CODESIGN_PASSWORD_FILE"
openssl_config="$support_dir/openssl-codesign.cnf"
private_key_path="$SWITCHBLADE_CODESIGN_PRIVATE_KEY"
certificate_path="$SWITCHBLADE_CODESIGN_CERTIFICATE"
archive_path="$SWITCHBLADE_CODESIGN_ARCHIVE"
fingerprint_file="$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE"

mkdir -p "$support_dir"

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
    openssl pkcs12 -in "$archive_path" -passin pass:"$(<"$keychain_password_file")" -info -noout >/dev/null 2>&1
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
    local password="$1"
    openssl pkcs12 -export \
        -inkey "$private_key_path" \
        -in "$certificate_path" \
        -out "$archive_path" \
        -passout pass:"$password" >/dev/null 2>&1
    chmod 600 "$archive_path"
}

extract_material_from_archive() {
    local password="$1"
    openssl pkcs12 -in "$archive_path" -passin pass:"$password" -clcerts -nokeys 2>/dev/null \
        | openssl x509 -out "$certificate_path" >/dev/null 2>&1
    openssl pkcs12 -in "$archive_path" -passin pass:"$password" -nocerts -nodes 2>/dev/null \
        | openssl pkey -out "$private_key_path" >/dev/null 2>&1
    chmod 600 "$private_key_path" "$certificate_path"
}

validate_archive_identity() {
    local expected_fingerprint="$1"
    local password="$2"
    (
        local temp_dir temp_keychain identity_hash expected_fingerprint_upper
        temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-codesign-validate.XXXXXX")"
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

        cleanup_validation() {
            restore_original_keychains
            rm -rf "$temp_dir"
        }

        trap cleanup_validation EXIT

        security create-keychain -p "$password" "$temp_keychain" >/dev/null
        security unlock-keychain -p "$password" "$temp_keychain" >/dev/null
        security set-keychain-settings -lut 21600 "$temp_keychain" >/dev/null
        if (( ${#original_keychains[@]} > 0 )); then
            security list-keychains -d user -s "$temp_keychain" "${original_keychains[@]}" >/dev/null
        else
            security list-keychains -d user -s "$temp_keychain" >/dev/null
        fi
        security import "$archive_path" \
            -k "$temp_keychain" \
            -P "$password" \
            -T /usr/bin/codesign \
            -T /usr/bin/security >/dev/null
        security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$temp_keychain" >/dev/null
        identity_hash="$(security find-identity -v -p codesigning "$temp_keychain" | awk -v hash="$expected_fingerprint_upper" '$2 == hash { print $2; exit }')"
        [[ -n "$identity_hash" ]]
    )
}

ensure_trusted_codesign_cert() {
    local expected_fingerprint="$1"
    local password="$2"

    if validate_archive_identity "$expected_fingerprint" "$password"; then
        return 0
    fi

    if security verify-cert -c "$certificate_path" -p codesigning >/dev/null 2>&1; then
        echo "ERROR: local codesign archive exists but does not resolve to a valid codesigning identity." >&2
        exit 1
    fi

    local login_keychain
    login_keychain="$(security login-keychain 2>/dev/null || true)"
    login_keychain="$(sed 's/^[[:space:]]*"//; s/"$//' <<<"$login_keychain")"
    if [[ -z "$login_keychain" ]]; then
        login_keychain="$HOME/Library/Keychains/login.keychain-db"
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "ERROR: local codesign cert is not trusted for code signing." >&2
        echo "Run this once in an interactive terminal, approve the macOS prompt, then rebuild:" >&2
        echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$login_keychain\" \"$certificate_path\"" >&2
        exit 1
    fi

    echo "Local codesign cert is not yet trusted for code signing. Approve the macOS prompt once to keep TCC stable across rebuilds." >&2
    security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$certificate_path" >/dev/null

    if ! validate_archive_identity "$expected_fingerprint" "$password"; then
        echo "ERROR: local codesign cert still is not a valid codesigning identity after the trust step." >&2
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

if (( has_archive && has_password )) && archive_password_valid; then
    archive_password="$(<"$keychain_password_file")"
else
    archive_password=""
fi

if (( has_archive && ! has_password )); then
    if (( has_cert && has_key )); then
        archive_password="$(generate_password)"
        write_password_file "$archive_password"
        has_password=1
        export_archive_from_material "$archive_password"
    else
        require_explicit_reset
    fi
fi

if (( has_archive && has_password )) && [[ -z "$archive_password" ]]; then
    if (( has_cert && has_key )); then
        archive_password="$(generate_password)"
        write_password_file "$archive_password"
        export_archive_from_material "$archive_password"
    else
        require_explicit_reset
    fi
fi

if (( has_archive )) && [[ -n "$archive_password" ]] && (( ! has_cert || ! has_key )); then
    extract_material_from_archive "$archive_password"
    has_cert=1
    has_key=1
fi

if (( has_cert && has_key )) && ! cert_and_key_match; then
    if (( has_archive )) && [[ -n "$archive_password" ]]; then
        extract_material_from_archive "$archive_password"
        if ! cert_and_key_match; then
            require_explicit_reset
        fi
    else
        require_explicit_reset
    fi
fi

if (( ! has_cert && ! has_key && ! has_archive )); then
    archive_password="$(generate_password)"
    write_password_file "$archive_password"
    generate_certificate_and_key
    export_archive_from_material "$archive_password"
    has_cert=1
    has_key=1
    has_archive=1
    has_password=1
fi

if (( ! has_cert || ! has_key )); then
    require_explicit_reset
fi

current_fingerprint="$(certificate_sha1 "$certificate_path")"
if (( has_fingerprint )); then
    recorded_fingerprint="$(normalize_sha1 < "$fingerprint_file")"
    if [[ "$recorded_fingerprint" != "$current_fingerprint" ]]; then
        require_explicit_reset
    fi
else
    write_fingerprint_file "$current_fingerprint"
fi

if (( ! has_password )); then
    archive_password="$(generate_password)"
    write_password_file "$archive_password"
    has_password=1
fi

if [[ -z "${archive_password:-}" ]]; then
    archive_password="$(<"$keychain_password_file")"
fi

if (( ! has_archive )) || ! archive_password_valid; then
    export_archive_from_material "$archive_password"
fi

ensure_trusted_codesign_cert "$current_fingerprint" "$archive_password"

echo "$identity_name"
