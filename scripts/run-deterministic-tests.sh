#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift run --disable-sandbox SwitchBladeTests
python3 scripts/test_minimized_runtime_proof.py
