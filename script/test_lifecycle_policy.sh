#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-lifecycle.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$task_temp/module-cache" \
  "$project_root/Sources/Host/GameLifecycle.swift" "$project_root/Tests/LifecyclePolicyTests.swift" \
  -o "$task_temp/LifecyclePolicyTests"
"$task_temp/LifecyclePolicyTests"
