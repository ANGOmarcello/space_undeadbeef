#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 3 || "${1:-}" == "--help" ]]; then
  printf 'Usage: %s [watch|metal] [SDBEngine.mm source] [SDBMetalRenderer.mm source]\n' "$0"
  [[ $# -le 3 ]] && exit 0 || exit 64
fi
backend="${1:-watch}"
engine_source="${2:-$project_root/Sources/Legacy/SDBEngine.mm}"
metal_source="${3:-$project_root/Sources/Legacy/SDBMetalRenderer.mm}"
if [[ "$backend" != watch && "$backend" != metal ]]; then
  printf 'Backend must be watch or metal.\n' >&2
  exit 64
fi
for source_path in "$engine_source" "$metal_source"; do
  if [[ ! -f "$source_path" || "$source_path" != /* ]]; then
    printf 'Source must be an existing absolute path: %s\n' "$source_path" >&2
    exit 64
  fi
done
task_temp="$(mktemp -d /private/tmp/space-undeadbeef-equivalence.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT

# The fixture includes exactly one selected engine translation unit. Optional
# source overrides let the caller compare independently exported baseline/current
# implementations with identical inputs; stdout contains no paths or timestamps.
xcrun clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I "$project_root/Sources/Legacy" "-DSDB_ENGINE_SOURCE=\"$engine_source\"" \
  "$project_root/Tests/PerformanceEquivalence.mm" \
  "$project_root/Sources/Legacy/GuestCPU.cpp" \
  "$project_root/Sources/Legacy/GameDisplayPatch.cpp" \
  "$metal_source" "$project_root/Sources/Legacy/SDBAudioMixer.mm" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$task_temp/PerformanceEquivalence"
"$task_temp/PerformanceEquivalence" "$project_root/Resources/Original" "$task_temp/save" "$backend"
