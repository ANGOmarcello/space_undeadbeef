#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-haptic-attachment.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -module-cache-path "$task_temp/module-cache" \
  "$project_root/Sources/Host/GameHaptics.swift" \
  "$project_root/Tests/HapticAttachmentTests.swift" -o "$task_temp/HapticAttachmentTests"
"$task_temp/HapticAttachmentTests"
