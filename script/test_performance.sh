#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-undeadbeef-performance.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun clang++ -std=c++17 -O2 -g -fobjc-arc -I "$project_root/Sources/Legacy" \
  "$project_root/Tests/PerformanceSmoke.mm" \
  "$project_root/Sources/Legacy/SDBEngine.mm" \
  "$project_root/Sources/Legacy/GuestCPU.cpp" \
  "$project_root/Sources/Legacy/GameDisplayPatch.cpp" \
  "$project_root/Sources/Legacy/SDBMetalRenderer.mm" \
  "$project_root/Sources/Legacy/SDBAudioMixer.mm" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$task_temp/PerformanceSmoke"
"$task_temp/PerformanceSmoke" "$project_root/Resources/Original" "$task_temp/save" "${1:-1800}" "${2:-metal}" "${3:-paced}"
