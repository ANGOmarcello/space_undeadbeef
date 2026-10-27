#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-native-controls.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -D SDB_NATIVE_POLICY_TEST \
  -module-cache-path "$task_temp/module-cache" \
  "$project_root/Sources/Host/GameInputController.swift" \
  "$project_root/Sources/Host/GameMenuAccessibility.swift" \
  "$project_root/Tests/NativeControlsPolicyTests.swift" \
  -o "$task_temp/NativeControlsPolicyTests"
"$task_temp/NativeControlsPolicyTests"
