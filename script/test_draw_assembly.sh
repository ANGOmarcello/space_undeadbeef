#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-undeadbeef-draws.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
# The fixture includes SDBEngine.mm but creates only Runtime. No system audio,
# GPU, save files or user preferences are opened by this test.
xcrun clang++ -std=c++17 -O1 -g -fobjc-arc -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$project_root/Sources/Legacy" \
  "$project_root/Tests/DrawAssemblyTests.mm" \
  "$project_root/Sources/Legacy/GuestCPU.cpp" \
  "$project_root/Sources/Legacy/GameDisplayPatch.cpp" \
  "$project_root/Sources/Legacy/SDBMetalRenderer.mm" \
  "$project_root/Sources/Legacy/SDBAudioMixer.mm" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$task_temp/DrawAssemblyTests"
"$task_temp/DrawAssemblyTests"
