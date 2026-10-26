#!/usr/bin/env bash
# Created by Angelo Cammalleri on 25.10.2026.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 || "${1:-}" == "--help" ]]; then
  printf 'Usage: %s [Resources/Original directory]\n' "$0"
  [[ $# -le 1 ]] && exit 0 || exit 2
fi
RESOURCES="${1:-$PROJECT_ROOT/Resources/Original}"
if [[ ! -d "$RESOURCES" ]]; then
  printf 'Resource directory does not exist: %s\n' "$RESOURCES" >&2
  exit 2
fi
RESOURCES="$(cd "$RESOURCES" && pwd)"
TASK_TEMP="$(mktemp -d /private/tmp/space-undeadbeef-rendering.XXXXXX)"
trap 'rm -rf "$TASK_TEMP"' EXIT

# RendererTests includes SDBEngine.mm to access its actual CPU renderer. Do not
# compile SDBEngine.mm separately: doing so would duplicate the Objective-C class.
xcrun clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I "$PROJECT_ROOT/Sources/Legacy" \
  "$PROJECT_ROOT/Tests/RendererTests.mm" \
  "$PROJECT_ROOT/Sources/Legacy/GuestCPU.cpp" \
  "$PROJECT_ROOT/Sources/Legacy/GameDisplayPatch.cpp" \
  "$PROJECT_ROOT/Sources/Legacy/SDBMetalRenderer.mm" \
  "$PROJECT_ROOT/Sources/Legacy/SDBAudioMixer.mm" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$TASK_TEMP/RendererTests"
"$TASK_TEMP/RendererTests" "$RESOURCES"
