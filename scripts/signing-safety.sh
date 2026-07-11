#!/bin/zsh

# Shared signing-safety primitives. Both signing entry points source this file.
# The global user keychain search list is observed and verified, never mutated.

switchblade_acquire_signing_lock() {
    local lock_timeout="${SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS:-120}"
    if [[ ! "$lock_timeout" =~ '^[0-9]+$' ]]; then
        echo "ERROR: SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS must be a whole number." >&2
        return 1
    fi

    if [[ ! -x /usr/bin/lockf ]]; then
        echo "ERROR: /usr/bin/lockf is unavailable; refusing an unlocked signing operation." >&2
        return 1
    fi

    mkdir -p "$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
    typeset -g SWITCHBLADE_SIGNING_LOCK_FD
    exec {SWITCHBLADE_SIGNING_LOCK_FD}>>"$SWITCHBLADE_SIGNING_LOCK_FILE"

    if ! /usr/bin/lockf \
        -t "$lock_timeout" \
        "$SWITCHBLADE_SIGNING_LOCK_FD"; then
        echo "ERROR: timed out waiting for the SwitchBlade signing lock." >&2
        exec {SWITCHBLADE_SIGNING_LOCK_FD}>&-
        unset SWITCHBLADE_SIGNING_LOCK_FD
        return 1
    fi
}

switchblade_secure_signing_material_permissions() {
    local support_dir="$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
    local expected_uid actual_uid material_path

    expected_uid="$(id -u)"
    actual_uid="$(stat -f '%u' "$support_dir")" || {
        echo "ERROR: unable to inspect signing support directory ownership." >&2
        return 1
    }
    if [[ "$actual_uid" != "$expected_uid" ]]; then
        echo "ERROR: signing support directory is not owned by the current user." >&2
        return 1
    fi
    chmod 700 "$support_dir"

    for material_path in \
        "$SWITCHBLADE_CODESIGN_PASSWORD_FILE" \
        "$SWITCHBLADE_CODESIGN_PRIVATE_KEY" \
        "$SWITCHBLADE_CODESIGN_CERTIFICATE" \
        "$SWITCHBLADE_CODESIGN_ARCHIVE" \
        "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE"; do
        [[ -e "$material_path" || -L "$material_path" ]] || continue
        if [[ -L "$material_path" || ! -f "$material_path" ]]; then
            echo "ERROR: signing material must be a regular non-symlink file: $material_path" >&2
            return 1
        fi
        chmod 600 "$material_path"
    done
}

switchblade_cleanup_stale_build_artifacts() {
    local temp_root="$1"
    local output_dir="$2"
    local expected_uid candidate actual_uid
    local -a candidates

    expected_uid="$(id -u)"
    temp_root="${temp_root%/}"
    output_dir="${output_dir%/}"

    setopt local_options null_glob
    candidates=(
        "$temp_root"/switchblade-codesign.*(N/)
        "$temp_root"/switchblade-codesign-validate.*(N/)
        "$temp_root"/switchblade-archive-inspection.*(N/)
        "$output_dir"/.SwitchBlade.app.staging.*(N/)
    )

    for candidate in "${candidates[@]}"; do
        if [[ -L "$candidate" || ! -d "$candidate" ]]; then
            continue
        fi
        actual_uid="$(stat -f '%u' "$candidate" 2>/dev/null || true)"
        if [[ "$actual_uid" != "$expected_uid" ]]; then
            echo "WARNING: refusing to remove a stale signing artifact owned by another user: $candidate" >&2
            continue
        fi
        rm -rf "$candidate"
    done
}

switchblade_cleanup_stale_signing_test_artifacts() {
    local temp_root="$1"
    local expected_uid candidate actual_uid owner_pid
    local -a candidates

    expected_uid="$(id -u)"
    temp_root="${temp_root%/}"
    setopt local_options null_glob
    candidates=("$temp_root"/switchblade-signing-safety-test.*(N/))

    for candidate in "${candidates[@]}"; do
        if [[ -L "$candidate" || ! -d "$candidate" ]]; then
            continue
        fi
        actual_uid="$(stat -f '%u' "$candidate" 2>/dev/null || true)"
        [[ "$actual_uid" == "$expected_uid" ]] || continue

        owner_pid=""
        if [[ -f "$candidate/owner.pid" && ! -L "$candidate/owner.pid" ]]; then
            owner_pid="$(<"$candidate/owner.pid")"
        fi
        if [[ "$owner_pid" =~ '^[0-9]+$' ]] && kill -0 "$owner_pid" 2>/dev/null; then
            continue
        fi
        rm -rf "$candidate"
    done
}

switchblade_capture_user_keychain_search_list() {
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
    "$security_bin" list-keychains -d user
}

switchblade_assert_user_keychain_search_list_unchanged() {
    local expected="$1"
    local actual
    actual="$(switchblade_capture_user_keychain_search_list)" || {
        echo "ERROR: unable to read the final user keychain search list." >&2
        return 1
    }

    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: signing changed the global user keychain search list." >&2
        echo "Expected:" >&2
        print -r -- "$expected" >&2
        echo "Actual:" >&2
        print -r -- "$actual" >&2
        return 1
    fi
}

switchblade_login_keychain() {
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
    local login_keychain

    login_keychain="$("$security_bin" login-keychain 2>/dev/null || true)"
    login_keychain="$(sed 's/^[[:space:]]*"//; s/"$//' <<<"$login_keychain")"
    if [[ -z "$login_keychain" ]]; then
        login_keychain="$HOME/Library/Keychains/login.keychain-db"
    fi
    print -r -- "$login_keychain"
}

switchblade_assert_keychain_is_in_user_search_list() {
    local expected_path="$1"
    local current keychain

    current="$(switchblade_capture_user_keychain_search_list)" || return 1
    while IFS= read -r keychain; do
        keychain="${keychain#${keychain%%[![:space:]]*}}"
        keychain="${keychain#\"}"
        keychain="${keychain%\"}"
        if [[ "$keychain" == "$expected_path" ]]; then
            return 0
        fi
    done <<< "$current"

    echo "ERROR: the login keychain is not in the user search list; refusing to mutate the list." >&2
    echo "Expected login keychain: $expected_path" >&2
    return 1
}

switchblade_find_valid_identity_hash() {
    local keychain_path="$1"
    local expected_fingerprint="$2"
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
    local expected_upper

    expected_upper="$(printf '%s' "$expected_fingerprint" | tr 'a-f' 'A-F')"
    "$security_bin" find-identity -v -p codesigning "$keychain_path" \
        | awk -v hash="$expected_upper" '$2 == hash { print $2; exit }'
}

switchblade_keychain_contains_certificate() {
    local keychain_path="$1"
    local expected_fingerprint="$2"
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
    local expected_upper

    expected_upper="$(printf '%s' "$expected_fingerprint" | tr 'a-f' 'A-F')"
    "$security_bin" find-certificate -a -Z "$keychain_path" 2>/dev/null \
        | awk -v hash="$expected_upper" '$1 == "SHA-1" && $2 == "hash:" && $3 == hash { found = 1 } END { exit(found ? 0 : 1) }'
}

switchblade_verify_codesign_certificate() {
    local certificate_path="$1"
    local security_bin="${SWITCHBLADE_SECURITY_BIN:-/usr/bin/security}"
    local output

    # `security verify-cert` silently falls back to the basic policy when given
    # an unknown policy name and can still exit zero. Use the documented
    # case-sensitive `codeSign` policy and reject that fallback diagnostic even
    # if a future typo reaches this helper.
    if ! output="$("$security_bin" verify-cert -c "$certificate_path" -p codeSign 2>&1)"; then
        print -r -- "$output" >&2
        return 1
    fi
    if print -r -- "$output" | grep -Fq 'policy creation failed'; then
        echo "ERROR: code-sign certificate verification fell back from its requested policy." >&2
        print -r -- "$output" >&2
        return 1
    fi
}

switchblade_archive_matches_material() {
    local archive_path="$1"
    local password_file="$2"
    local certificate_path="$3"
    local private_key_path="$4"
    local archive_certificate_sha1 certificate_sha1
    local archive_public_key_sha256 private_key_public_sha256

    [[ -f "$archive_path" && -f "$password_file" && -f "$certificate_path" && -f "$private_key_path" ]] || return 1
    archive_certificate_sha1="$(
        openssl pkcs12 -in "$archive_path" -passin file:"$password_file" -clcerts -nokeys 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/.*=//' \
            | tr -d ':\n\r ' \
            | tr 'A-F' 'a-f'
    )" || return 1
    certificate_sha1="$(
        openssl x509 -in "$certificate_path" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/.*=//' \
            | tr -d ':\n\r ' \
            | tr 'A-F' 'a-f'
    )" || return 1
    archive_public_key_sha256="$(
        openssl pkcs12 -in "$archive_path" -passin file:"$password_file" -nocerts -nodes 2>/dev/null \
            | openssl pkey -pubout -outform der 2>/dev/null \
            | shasum -a 256 \
            | awk '{ print $1 }'
    )" || return 1
    private_key_public_sha256="$(
        openssl pkey -in "$private_key_path" -pubout -outform der 2>/dev/null \
            | shasum -a 256 \
            | awk '{ print $1 }'
    )" || return 1

    [[ -n "$archive_certificate_sha1" && "$archive_certificate_sha1" == "$certificate_sha1" ]] \
        && [[ -n "$archive_public_key_sha256" && "$archive_public_key_sha256" == "$private_key_public_sha256" ]]
}

switchblade_assert_user_keychain_search_list_sane() {
    local current
    current="$(switchblade_capture_user_keychain_search_list)" || {
        echo "ERROR: unable to inspect the user keychain search list." >&2
        return 1
    }

    if print -r -- "$current" | grep -Eq \
        'SwitchBladeCodesign|switchblade-codesign|"/Users/[^\"]+/Library/Application"$|"/Users/[^\"]+/Library/Keychains/Support/'; then
        echo "ERROR: user keychain search list contains a stale SwitchBlade or broken path entry." >&2
        print -r -- "$current" >&2
        return 1
    fi
}
