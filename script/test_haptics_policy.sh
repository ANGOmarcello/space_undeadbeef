#!/bin/bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d /private/tmp/space-undeadbeef-haptics.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT

xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$task_tmp/module-cache" \
    "$project_root/Sources/Host/GameHaptics.swift" \
    "$project_root/Tests/HapticsPolicyTests.swift" \
    -o "$task_tmp/HapticsPolicyTests"
"$task_tmp/HapticsPolicyTests"
