#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [task-owned /private/tmp capture directory]\n' "$0" >&2
  exit 2
fi
TASK_TEMP="$(mktemp -d /private/tmp/space-undeadbeef-watch-controls.XXXXXX)"
trap 'rm -rf "$TASK_TEMP"' EXIT
cd "$PROJECT_ROOT"
xcrun clang++ -std=c++17 -O1 -g -fobjc-arc -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I Sources/Legacy Sources/Legacy/GuestCPU.cpp Sources/Legacy/GameDisplayPatch.cpp \
  Sources/Legacy/SDBMetalRenderer.mm Sources/Legacy/SDBAudioMixer.mm Sources/Legacy/SDBEngine.mm \
  Tests/WatchControlsSmoke.mm -framework Foundation -framework CoreGraphics \
  -framework ImageIO -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$TASK_TEMP/WatchControlsSmoke"
"$TASK_TEMP/WatchControlsSmoke" "$PROJECT_ROOT/Resources/Original" "$TASK_TEMP" "${1:-$TASK_TEMP/captures}"
