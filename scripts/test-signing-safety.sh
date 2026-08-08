#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/signing-safety.sh"

if [[ "${1:-}" == "--lock-worker" ]]; then
    worker="$2"
    duration="$3"
    source "$repo_root/scripts/signing-safety.sh"
    switchblade_acquire_signing_lock
    print -r -- "${worker}:start" >> "$SWITCHBLADE_SIGNING_TEST_EVENTS"
    sleep "$duration"
    print -r -- "${worker}:end" >> "$SWITCHBLADE_SIGNING_TEST_EVENTS"
    exit 0
fi

if [[ "${1:-}" == "--orphan-lock-worker" ]]; then
    source "$repo_root/scripts/signing-safety.sh"
    switchblade_acquire_signing_lock
    /bin/sleep 0.35 &
    child_pid=$!
    print -r -- "$child_pid" > "$SWITCHBLADE_SIGNING_TEST_CHILD_PID"
    print -r -- "ready" > "$SWITCHBLADE_SIGNING_TEST_READY"
    wait "$child_pid"
    exit 0
fi

if [[ "${1:-}" == "--lock-probe" ]]; then
    source "$repo_root/scripts/signing-safety.sh"
    switchblade_acquire_signing_lock
    exit 0
fi

switchblade_cleanup_stale_signing_test_artifacts "${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-signing-safety-test.XXXXXX")"
print -r -- "$$" > "$tmp_dir/owner.pid"
private_key_test_keychain=""
cleanup_test_state() {
    if [[ -n "$private_key_test_keychain" ]]; then
        /usr/bin/security delete-keychain "$private_key_test_keychain" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup_test_state EXIT

export SWITCHBLADE_CODESIGN_SUPPORT_DIR="$tmp_dir/support"
export SWITCHBLADE_SIGNING_LOCK_FILE="$tmp_dir/signing.lock"
export SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS=5
source "$repo_root/scripts/signing-safety.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_security="$tmp_dir/security"
state_file="$tmp_dir/keychains.txt"
events_file="$tmp_dir/events.txt"

cat > "$fake_security" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$*" == "list-keychains -d user" ]]; then
    cat "$SWITCHBLADE_FAKE_KEYCHAIN_STATE"
    exit 0
fi
if [[ "$*" == "login-keychain" ]]; then
    print -r -- '    "/Users/test/Library/Keychains/login.keychain-db"'
    exit 0
fi
if [[ "${1:-}" == "find-identity" ]]; then
    print -r -- '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "SwitchBlade Local Codesign"'
    print -r -- '     1 valid identities found'
    exit 0
fi
if [[ "${1:-}" == "find-certificate" ]]; then
    print -r -- 'SHA-1 hash: 0123456789ABCDEF0123456789ABCDEF01234567'
    exit 0
fi
echo "unexpected fake security invocation: $*" >&2
exit 2
EOF
chmod +x "$fake_security"

export SWITCHBLADE_SECURITY_BIN="$fake_security"
export SWITCHBLADE_FAKE_KEYCHAIN_STATE="$state_file"
print -r -- '    "/Users/test/Library/Keychains/login.keychain-db"' > "$state_file"

baseline="$(switchblade_capture_user_keychain_search_list)"
switchblade_assert_user_keychain_search_list_unchanged "$baseline"
switchblade_assert_user_keychain_search_list_sane
login_keychain="$(switchblade_login_keychain)"
try_expected="/Users/test/Library/Keychains/login.keychain-db"
[[ "$login_keychain" == "$try_expected" ]] || fail "login keychain path was parsed incorrectly"
switchblade_assert_keychain_is_in_user_search_list "$login_keychain"
identity_hash="$(switchblade_find_valid_identity_hash "$login_keychain" 0123456789abcdef0123456789abcdef01234567)"
[[ "$identity_hash" == "0123456789ABCDEF0123456789ABCDEF01234567" ]] \
    || fail "expected signing identity was not selected by exact fingerprint"
switchblade_keychain_contains_certificate "$login_keychain" 0123456789abcdef0123456789abcdef01234567 \
    || fail "expected certificate was not selected by exact fingerprint"

material_dir="$tmp_dir/material"
mkdir -p "$material_dir"
export SWITCHBLADE_CODESIGN_SUPPORT_DIR="$material_dir"
export SWITCHBLADE_CODESIGN_PASSWORD_FILE="$material_dir/password.txt"
export SWITCHBLADE_CODESIGN_PRIVATE_KEY="$material_dir/private-key.pem"
export SWITCHBLADE_CODESIGN_CERTIFICATE="$material_dir/certificate.pem"
export SWITCHBLADE_CODESIGN_ARCHIVE="$material_dir/identity.p12"
export SWITCHBLADE_CODESIGN_FINGERPRINT_FILE="$material_dir/fingerprint.txt"
touch \
    "$SWITCHBLADE_CODESIGN_PASSWORD_FILE" \
    "$SWITCHBLADE_CODESIGN_PRIVATE_KEY" \
    "$SWITCHBLADE_CODESIGN_CERTIFICATE" \
    "$SWITCHBLADE_CODESIGN_ARCHIVE" \
    "$SWITCHBLADE_CODESIGN_FINGERPRINT_FILE"
chmod 755 "$material_dir"
chmod 644 "$material_dir"/*
switchblade_secure_signing_material_permissions
[[ "$(stat -f '%Lp' "$material_dir")" == "700" ]] || fail "support directory permissions were not normalized"
for material in "$material_dir"/*; do
    [[ "$(stat -f '%Lp' "$material")" == "600" ]] || fail "signing material permissions were not normalized"
done

archive_test_dir="$tmp_dir/archive-material"
mkdir -p "$archive_test_dir"
openssl req -new -newkey rsa:2048 -x509 -sha256 -days 1 -nodes \
    -subj '/CN=SwitchBlade Test A' \
    -keyout "$archive_test_dir/a.key" \
    -out "$archive_test_dir/a.pem" >/dev/null 2>&1
openssl pkcs12 -export \
    -inkey "$archive_test_dir/a.key" \
    -in "$archive_test_dir/a.pem" \
    -out "$archive_test_dir/a.p12" \
    -passout pass:test-password >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -x509 -sha256 -days 1 -nodes \
    -subj '/CN=SwitchBlade Test B' \
    -keyout "$archive_test_dir/b.key" \
    -out "$archive_test_dir/b.pem" >/dev/null 2>&1
openssl pkcs12 -export \
    -inkey "$archive_test_dir/b.key" \
    -in "$archive_test_dir/b.pem" \
    -out "$archive_test_dir/b.p12" \
    -passout pass:test-password >/dev/null 2>&1
print -r -- test-password > "$archive_test_dir/password.txt"
chmod 600 "$archive_test_dir/password.txt"
switchblade_archive_matches_material \
    "$archive_test_dir/a.p12" "$archive_test_dir/password.txt" "$archive_test_dir/a.pem" "$archive_test_dir/a.key" \
    || fail "matching archive and material were rejected"
if switchblade_archive_matches_material \
    "$archive_test_dir/b.p12" "$archive_test_dir/password.txt" "$archive_test_dir/a.pem" "$archive_test_dir/a.key"; then
    fail "drifted but decryptable archive was accepted"
fi

setup_fake_security="$tmp_dir/setup-security"
cat > "$setup_fake_security" <<'EOF'
#!/bin/zsh
set -euo pipefail
case "${1:-}" in
    list-keychains)
        cat "$SWITCHBLADE_FAKE_KEYCHAIN_STATE"
        ;;
    login-keychain)
        print -r -- '    "/Users/test/Library/Keychains/login.keychain-db"'
        ;;
    find-identity)
        print -r -- '     0 valid identities found'
        ;;
    find-certificate)
        print -r -- "SHA-1 hash: $SWITCHBLADE_FAKE_FINGERPRINT"
        ;;
    verify-cert)
        [[ " $* " == *" -p codeSign "* ]] || {
            echo "verify-cert did not request the exact codeSign policy: $*" >&2
            exit 3
        }
        print -r -- '...certificate verification successful.'
        ;;
    *)
        echo "unexpected setup fake security invocation: $*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$setup_fake_security"

fingerprint_a="$(openssl x509 -in "$archive_test_dir/a.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
fingerprint_b="$(openssl x509 -in "$archive_test_dir/b.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
recovery_dir="$tmp_dir/recovery-ordering"
mkdir -p "$recovery_dir"
cp "$archive_test_dir/b.key" "$recovery_dir/private-key.pem"
cp "$archive_test_dir/b.pem" "$recovery_dir/certificate.pem"
cp "$archive_test_dir/a.p12" "$recovery_dir/identity.p12"
cp "$archive_test_dir/password.txt" "$recovery_dir/password.txt"
print -r -- "$fingerprint_a" > "$recovery_dir/fingerprint.txt"
archive_a_before="$(shasum -a 256 "$recovery_dir/identity.p12" | awk '{ print $1 }')"
SWITCHBLADE_SECURITY_BIN="$setup_fake_security" \
SWITCHBLADE_FAKE_FINGERPRINT="$(printf '%s' "$fingerprint_a" | tr 'a-f' 'A-F')" \
SWITCHBLADE_CODESIGN_SUPPORT_DIR="$recovery_dir" \
SWITCHBLADE_CODESIGN_PRIVATE_KEY="$recovery_dir/private-key.pem" \
SWITCHBLADE_CODESIGN_CERTIFICATE="$recovery_dir/certificate.pem" \
SWITCHBLADE_CODESIGN_ARCHIVE="$recovery_dir/identity.p12" \
SWITCHBLADE_CODESIGN_PASSWORD_FILE="$recovery_dir/password.txt" \
SWITCHBLADE_CODESIGN_FINGERPRINT_FILE="$recovery_dir/fingerprint.txt" \
SWITCHBLADE_SIGNING_LOCK_FILE="$recovery_dir/signing.lock" \
    "$repo_root/scripts/setup-local-codesign.sh" >/dev/null
recovered_fingerprint="$(openssl x509 -in "$recovery_dir/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
[[ "$recovered_fingerprint" == "$fingerprint_a" ]] \
    || fail "recorded archive identity was not restored before material reconciliation"
[[ "$(shasum -a 256 "$recovery_dir/identity.p12" | awk '{ print $1 }')" == "$archive_a_before" ]] \
    || fail "last recoverable archive was overwritten before fingerprint resolution"
switchblade_archive_matches_material \
    "$recovery_dir/identity.p12" \
    "$recovery_dir/password.txt" \
    "$recovery_dir/certificate.pem" \
    "$recovery_dir/private-key.pem" \
    || fail "restored material no longer matches its recovery archive"

missing_fingerprint_dir="$tmp_dir/missing-fingerprint-conflict"
mkdir -p "$missing_fingerprint_dir"
cp "$archive_test_dir/b.key" "$missing_fingerprint_dir/private-key.pem"
cp "$archive_test_dir/b.pem" "$missing_fingerprint_dir/certificate.pem"
cp "$archive_test_dir/a.p12" "$missing_fingerprint_dir/identity.p12"
cp "$archive_test_dir/password.txt" "$missing_fingerprint_dir/password.txt"
missing_fingerprint_before="$(
    shasum -a 256 \
        "$missing_fingerprint_dir/private-key.pem" \
        "$missing_fingerprint_dir/certificate.pem" \
        "$missing_fingerprint_dir/identity.p12" \
        "$missing_fingerprint_dir/password.txt" \
        | shasum -a 256 \
        | awk '{ print $1 }'
)"
if SWITCHBLADE_SECURITY_BIN="$setup_fake_security" \
    SWITCHBLADE_FAKE_FINGERPRINT="$(printf '%s' "$fingerprint_b" | tr 'a-f' 'A-F')" \
    SWITCHBLADE_CODESIGN_SUPPORT_DIR="$missing_fingerprint_dir" \
    SWITCHBLADE_CODESIGN_PRIVATE_KEY="$missing_fingerprint_dir/private-key.pem" \
    SWITCHBLADE_CODESIGN_CERTIFICATE="$missing_fingerprint_dir/certificate.pem" \
    SWITCHBLADE_CODESIGN_ARCHIVE="$missing_fingerprint_dir/identity.p12" \
    SWITCHBLADE_CODESIGN_PASSWORD_FILE="$missing_fingerprint_dir/password.txt" \
    SWITCHBLADE_CODESIGN_FINGERPRINT_FILE="$missing_fingerprint_dir/fingerprint.txt" \
    SWITCHBLADE_SIGNING_LOCK_FILE="$missing_fingerprint_dir/signing.lock" \
        "$repo_root/scripts/setup-local-codesign.sh" >/dev/null 2>&1; then
    fail "missing fingerprint caused conflicting recovery sources to be guessed"
fi
[[ ! -e "$missing_fingerprint_dir/fingerprint.txt" ]] \
    || fail "rejected missing-fingerprint conflict created metadata"
[[ "$(
    shasum -a 256 \
        "$missing_fingerprint_dir/private-key.pem" \
        "$missing_fingerprint_dir/certificate.pem" \
        "$missing_fingerprint_dir/identity.p12" \
        "$missing_fingerprint_dir/password.txt" \
        | shasum -a 256 \
        | awk '{ print $1 }'
)" == "$missing_fingerprint_before" ]] \
    || fail "missing-fingerprint conflict mutated a recovery source"

unpublished_dir="$tmp_dir/unpublished-fingerprint"
mkdir -p "$unpublished_dir"
cp "$archive_test_dir/b.key" "$unpublished_dir/private-key.pem"
cp "$archive_test_dir/b.pem" "$unpublished_dir/certificate.pem"
cp "$archive_test_dir/b.p12" "$unpublished_dir/identity.p12"
cp "$archive_test_dir/password.txt" "$unpublished_dir/password.txt"
print -r -- "$fingerprint_a" > "$unpublished_dir/fingerprint.txt"
unpublished_before="$(
    shasum -a 256 \
        "$unpublished_dir/private-key.pem" \
        "$unpublished_dir/certificate.pem" \
        "$unpublished_dir/identity.p12" \
        "$unpublished_dir/password.txt" \
        "$unpublished_dir/fingerprint.txt" \
        | shasum -a 256 \
        | awk '{ print $1 }'
)"
if SWITCHBLADE_REPAIR_CODESIGN_FINGERPRINT=1 \
    SWITCHBLADE_SECURITY_BIN="$setup_fake_security" \
    SWITCHBLADE_FAKE_FINGERPRINT="$(printf '%s' "$fingerprint_b" | tr 'a-f' 'A-F')" \
    SWITCHBLADE_CODESIGN_SUPPORT_DIR="$unpublished_dir" \
    SWITCHBLADE_CODESIGN_PRIVATE_KEY="$unpublished_dir/private-key.pem" \
    SWITCHBLADE_CODESIGN_CERTIFICATE="$unpublished_dir/certificate.pem" \
    SWITCHBLADE_CODESIGN_ARCHIVE="$unpublished_dir/identity.p12" \
    SWITCHBLADE_CODESIGN_PASSWORD_FILE="$unpublished_dir/password.txt" \
    SWITCHBLADE_CODESIGN_FINGERPRINT_FILE="$unpublished_dir/fingerprint.txt" \
    SWITCHBLADE_SIGNING_LOCK_FILE="$unpublished_dir/signing.lock" \
        "$repo_root/scripts/setup-local-codesign.sh" >/dev/null 2>&1; then
    fail "fingerprint repair accepted coherent but unpublished identity material"
fi
[[ "$(<"$unpublished_dir/fingerprint.txt")" == "$fingerprint_a" ]] \
    || fail "rejected fingerprint repair still rewrote metadata"
[[ "$(shasum -a 256 "$unpublished_dir/private-key.pem" "$unpublished_dir/certificate.pem" "$unpublished_dir/identity.p12" "$unpublished_dir/password.txt" "$unpublished_dir/fingerprint.txt" | shasum -a 256 | awk '{ print $1 }')" == "$unpublished_before" ]] \
    || fail "rejected fingerprint repair mutated recovery material"

stale_temp_root="$tmp_dir/stale-temp"
stale_output_dir="$tmp_dir/stale-output"
mkdir -p \
    "$stale_temp_root/switchblade-codesign.orphan" \
    "$stale_temp_root/switchblade-codesign-validate.orphan" \
    "$stale_temp_root/switchblade-archive-inspection.orphan" \
    "$stale_output_dir/.SwitchBlade.app.staging.orphan"
switchblade_cleanup_stale_build_artifacts "$stale_temp_root" "$stale_output_dir"
[[ ! -e "$stale_temp_root/switchblade-codesign.orphan" ]] || fail "stale temporary keychain directory was not removed"
[[ ! -e "$stale_temp_root/switchblade-codesign-validate.orphan" ]] || fail "legacy signing-validation directory was not removed"
[[ ! -e "$stale_temp_root/switchblade-archive-inspection.orphan" ]] || fail "stale archive-inspection directory was not removed"
[[ ! -e "$stale_output_dir/.SwitchBlade.app.staging.orphan" ]] || fail "stale staged app bundle was not removed"

stale_test_root="$tmp_dir/stale-test-root"
mkdir -p \
    "$stale_test_root/switchblade-signing-safety-test.stale" \
    "$stale_test_root/switchblade-signing-safety-test.active"
print -r -- 999999 > "$stale_test_root/switchblade-signing-safety-test.stale/owner.pid"
print -r -- "$$" > "$stale_test_root/switchblade-signing-safety-test.active/owner.pid"
switchblade_cleanup_stale_signing_test_artifacts "$stale_test_root"
[[ ! -e "$stale_test_root/switchblade-signing-safety-test.stale" ]] \
    || fail "stale signing-test directory was not removed"
[[ -d "$stale_test_root/switchblade-signing-safety-test.active" ]] \
    || fail "active signing-test directory was removed"

export SWITCHBLADE_CODESIGN_SUPPORT_DIR="$tmp_dir/support"
export SWITCHBLADE_SIGNING_LOCK_FILE="$tmp_dir/signing.lock"

print -r -- '    "/tmp/switchblade-codesign.123/SwitchBladeCodesign.keychain"' >> "$state_file"
if switchblade_assert_user_keychain_search_list_unchanged "$baseline" >/dev/null 2>&1; then
    fail "exact search-list comparison accepted a changed list"
fi
if switchblade_assert_user_keychain_search_list_sane >/dev/null 2>&1; then
    fail "sanity check accepted a stale SwitchBlade keychain"
fi

print -r -- '    "/Users/test/Library/Keychains/login.keychain-db"' > "$state_file"
export SWITCHBLADE_SIGNING_TEST_EVENTS="$events_file"
"$repo_root/scripts/test-signing-safety.sh" --lock-worker first 0.15 &
first_pid=$!
for _ in {1..100}; do
    [[ -f "$events_file" ]] && grep -Fqx 'first:start' "$events_file" && break
    sleep 0.01
done
grep -Fqx 'first:start' "$events_file" || fail "first signing worker did not start"
SWITCHBLADE_SIGNING_LOCK_FD=1 \
    "$repo_root/scripts/test-signing-safety.sh" --lock-worker second 0.01 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

expected_events=$'first:start\nfirst:end\nsecond:start\nsecond:end'
actual_events="$(cat "$events_file")"
[[ "$actual_events" == "$expected_events" ]] || {
    echo "Expected serialized events:" >&2
    print -r -- "$expected_events" >&2
    echo "Actual events:" >&2
    print -r -- "$actual_events" >&2
    fail "signing lock did not serialize workers"
}

ready_file="$tmp_dir/orphan-ready"
child_pid_file="$tmp_dir/orphan-child-pid"
export SWITCHBLADE_SIGNING_TEST_READY="$ready_file"
export SWITCHBLADE_SIGNING_TEST_CHILD_PID="$child_pid_file"
"$repo_root/scripts/test-signing-safety.sh" --orphan-lock-worker &
orphan_parent=$!
for _ in {1..100}; do
    [[ -f "$ready_file" && -f "$child_pid_file" ]] && break
    sleep 0.01
done
[[ -f "$ready_file" && -f "$child_pid_file" ]] || fail "orphan lock worker did not start"
orphan_child="$(<"$child_pid_file")"
kill -TERM "$orphan_parent"
wait "$orphan_parent" 2>/dev/null || true
kill -0 "$orphan_child" 2>/dev/null || fail "orphan child exited before lock-lifetime probe"

if SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS=0 \
    "$repo_root/scripts/test-signing-safety.sh" --lock-probe >/dev/null 2>&1; then
    fail "lock was released while a child of the terminated owner was still running"
fi

invalid_timeout_output="$tmp_dir/invalid-timeout.txt"
if SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS=0.05 \
    "$repo_root/scripts/test-signing-safety.sh" --lock-probe >"$invalid_timeout_output" 2>&1; then
    fail "fractional lock timeout was accepted"
fi
grep -Fq 'must be a whole number' "$invalid_timeout_output" \
    || fail "invalid lock timeout did not fail for the expected reason"
for _ in {1..100}; do
    ! kill -0 "$orphan_child" 2>/dev/null && break
    sleep 0.01
done
if ! SWITCHBLADE_SIGNING_LOCK_TIMEOUT_SECONDS=1 \
    "$repo_root/scripts/test-signing-safety.sh" --lock-probe; then
    fail "lock was not released after the inherited child descriptor closed"
fi

if rg -n 'list-keychains[^\n]*-s' \
    "$repo_root/scripts/build-app.sh" \
    "$repo_root/scripts/remove-login-codesign-identity.sh" \
    "$repo_root/scripts/setup-local-codesign.sh" \
    "$repo_root/scripts/signing-safety.sh" >/dev/null; then
    fail "signing code still mutates a keychain search list"
fi

if rg -n 'verify-cert' \
    "$repo_root/scripts/setup-local-codesign.sh" \
    "$repo_root/scripts/remove-login-codesign-identity.sh" >/dev/null; then
    fail "codesign trust checks bypass the centralized fail-closed verifier"
fi

policy_failure_security="$tmp_dir/policy-failure-security"
cat > "$policy_failure_security" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "verify-cert" ]]; then
    print -u2 -- '*** policy creation failed for codeSign'
    print -r -- '...certificate verification successful.'
    exit 0
fi
exit 2
EOF
chmod +x "$policy_failure_security"
if SWITCHBLADE_SECURITY_BIN="$policy_failure_security" \
    switchblade_verify_codesign_certificate "$archive_test_dir/a.pem" >/dev/null 2>&1; then
    fail "policy-creation failure was accepted because security exited zero"
fi

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-deprecated-declarations \
    -framework CoreFoundation \
    -framework Security \
    "$repo_root/scripts/sign-app-with-keychain.c" \
    -o "$tmp_dir/sign-app-with-keychain"
xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-deprecated-declarations \
    -framework CoreFoundation \
    -framework Security \
    "$repo_root/scripts/remove-keychain-private-key.c" \
    -o "$tmp_dir/remove-keychain-private-key"
xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    "$repo_root/scripts/atomic-replace.c" \
    -o "$tmp_dir/atomic-replace"

atomic_test_dir="$tmp_dir/atomic-replace-test"
mkdir -p "$atomic_test_dir/staged" "$atomic_test_dir/current"
print -r -- new > "$atomic_test_dir/staged/version"
print -r -- old > "$atomic_test_dir/current/version"
"$tmp_dir/atomic-replace" "$atomic_test_dir/staged" "$atomic_test_dir/current"
[[ "$(<"$atomic_test_dir/current/version")" == "new" ]] || fail "atomic replace did not publish staged bundle"
[[ "$(<"$atomic_test_dir/staged/version")" == "old" ]] || fail "atomic replace did not preserve prior bundle at staging path"
rm -rf "$atomic_test_dir/staged" "$atomic_test_dir/current"
mkdir -p "$atomic_test_dir/staged"
print -r -- first > "$atomic_test_dir/staged/version"
"$tmp_dir/atomic-replace" "$atomic_test_dir/staged" "$atomic_test_dir/current"
[[ "$(<"$atomic_test_dir/current/version")" == "first" ]] || fail "initial atomic publish failed"

private_key_test_keychain="$tmp_dir/private-key-removal.keychain"
empty_archive="$archive_test_dir/a-empty.p12"
transient_test_password="switchblade-transient-test"
# Match build-app.sh: this archive is consumed by macOS security import, so it
# must be emitted by the system OpenSSL rather than a PATH-selected Homebrew one.
/usr/bin/openssl pkcs12 -export \
    -inkey "$archive_test_dir/a.key" \
    -in "$archive_test_dir/a.pem" \
    -out "$empty_archive" \
    -passout pass:"$transient_test_password" >/dev/null 2>&1
test_fingerprint="$(
    openssl x509 -in "$archive_test_dir/a.pem" -noout -fingerprint -sha1 \
        | sed 's/.*=//; s/://g'
)"
real_search_list_before="$(/usr/bin/security list-keychains -d user)"
/usr/bin/security create-keychain -p "$transient_test_password" "$private_key_test_keychain" >/dev/null
/usr/bin/security unlock-keychain -p "$transient_test_password" "$private_key_test_keychain" >/dev/null
/usr/bin/security import "$empty_archive" -k "$private_key_test_keychain" -P "$transient_test_password" -A >/dev/null
"$tmp_dir/remove-keychain-private-key" "$private_key_test_keychain" "$test_fingerprint"
/usr/bin/security find-certificate -Z "$private_key_test_keychain" >/dev/null \
    || fail "private-key-only repair removed the public certificate"
set +e
"$tmp_dir/remove-keychain-private-key" "$private_key_test_keychain" "$test_fingerprint" >/dev/null 2>&1
second_removal_status=$?
set -e
[[ "$second_removal_status" == "2" ]] || fail "private-key-only repair left the identity usable"
[[ "$(/usr/bin/security list-keychains -d user)" == "$real_search_list_before" ]] \
    || fail "private-key-only repair changed the global keychain search list"
/usr/bin/security delete-keychain "$private_key_test_keychain" >/dev/null
private_key_test_keychain=""

if "$repo_root/scripts/remove-login-codesign-identity.sh" >/dev/null 2>&1; then
    fail "login-keychain repair ran without its explicit opt-in"
fi

echo "Signing safety tests passed"
