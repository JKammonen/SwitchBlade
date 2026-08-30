#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

git diff --check

proof_relevant_paths=(
    Sources/SwitchBladeCore
    Sources/SwitchBlade
    Sources/SwitchBladeTests
    .quality/test-obligations.json
    scripts/build-app.sh
    scripts/check-repo.sh
    scripts/run-deterministic-tests.sh
    scripts/test_minimized_runtime_proof.py
    scripts/verify_minimized_runtime_proof.py
)
if ! git diff --quiet -- "${proof_relevant_paths[@]}"; then
    echo "ERROR: check-repo requires relevant tracked changes to be staged so every gate verifies one tree." >&2
    exit 1
fi
untracked_relevant="$(git ls-files --others --exclude-standard -- "${proof_relevant_paths[@]}")"
if [[ -n "${untracked_relevant}" ]]; then
    echo "ERROR: check-repo found untracked behavior/test/policy files:" >&2
    echo "${untracked_relevant}" >&2
    exit 1
fi

for script in scripts/*.sh; do
    if head -n 1 "$script" | grep -Fq zsh; then
        zsh -n "$script"
    else
        bash -n "$script"
    fi
done

for test_file in Sources/SwitchBladeTests/*Tests.swift; do
    suite="$(basename "$test_file" .swift)"
    if ! grep -Fq "${suite}.all" Sources/SwitchBladeTests/main.swift; then
        echo "ERROR: ${suite} compiles but is not registered in the custom test runner." >&2
        exit 1
    fi
done

test_obligation_engine="${TEST_OBLIGATION_ENGINE:-${ROOT}/../codex-workflow-hooks/hooks/test_obligation_gate.py}"
if [[ ! -x "${test_obligation_engine}" ]]; then
    echo "ERROR: test-obligation engine missing or not executable: ${test_obligation_engine}" >&2
    exit 1
fi
/usr/bin/python3 "${test_obligation_engine}" \
    --repo "${ROOT}" \
    --all-canaries \
    --defer-runtime-proofs

if rg -n 'title=.*privacy: \.public|item\.title.*privacy: \.public|displayName.*privacy: \.public|appName.*privacy: \.public|bundleIdentifier.*privacy: \.public|appIdentity.*privacy: \.public' Sources/SwitchBladeCore; then
    echo "ERROR: sensitive window/process display text is logged as public." >&2
    exit 1
fi

zsh scripts/test-signing-safety.sh
bash scripts/run-deterministic-tests.sh
bash scripts/build-app.sh

if plutil -extract NSAppleEventsUsageDescription raw dist/SwitchBlade.app/Contents/Info.plist >/dev/null 2>&1; then
    echo "ERROR: unused NSAppleEventsUsageDescription is present in the built app." >&2
    exit 1
fi
for language in en fi; do
    strings_file="dist/SwitchBlade.app/Contents/Resources/${language}.lproj/InfoPlist.strings"
    [[ -f "$strings_file" ]]
    plutil -lint "$strings_file" >/dev/null
    grep -Fq 'NSScreenCaptureUsageDescription' "$strings_file"
done

published_timestamp="$(plutil -extract SwitchBladeBuildTimestamp raw dist/SwitchBlade.app/Contents/Info.plist)"
keychains_before="$(security list-keychains -d user)"
failure_log="$(mktemp "${TMPDIR:-/tmp}/switchblade-publish-failure.XXXXXX")"
trap 'rm -f "$failure_log"' EXIT
if APP_BUILD_TIMESTAMP="INJECTED-UNPUBLISHED-BUILD" \
    SWITCHBLADE_FAIL_BEFORE_PUBLISH=1 \
    bash scripts/build-app.sh >"$failure_log" 2>&1; then
    echo "ERROR: injected pre-publication failure unexpectedly succeeded." >&2
    exit 1
fi
grep -Fq 'injected failure before atomic app publication' "$failure_log"
[[ "$(plutil -extract SwitchBladeBuildTimestamp raw dist/SwitchBlade.app/Contents/Info.plist)" == "$published_timestamp" ]]
[[ "$(security list-keychains -d user)" == "$keychains_before" ]]
codesign --verify --deep --strict dist/SwitchBlade.app
