#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

git diff --check

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

if rg -n 'title=.*privacy: \.public|item\.title.*privacy: \.public|displayName.*privacy: \.public|appName.*privacy: \.public|bundleIdentifier.*privacy: \.public|appIdentity.*privacy: \.public' Sources/SwitchBladeCore; then
    echo "ERROR: sensitive window/process display text is logged as public." >&2
    exit 1
fi

zsh scripts/test-signing-safety.sh
swift run SwitchBladeTests
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
