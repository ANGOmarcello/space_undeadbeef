#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-engine-audio-gate.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
source "$project_root/script/prepare_metal_library.sh"
sdb_prepare_metal_library "$task_temp"
xcrun clang++ -DSDB_HEADLESS_TESTS=1 -std=c++17 -O1 -g -fobjc-arc -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I "$project_root/Sources/Legacy" \
  "$project_root/Tests/EngineAudioGateTests.mm" "$project_root/Sources/Legacy/SDBSaveStore.mm" \
  "$project_root/Sources/Legacy/GuestCPU.cpp" "$project_root/Sources/Legacy/GameDisplayPatch.cpp" \
  "$project_root/Sources/Legacy/SDBAudioMixer.mm" "$project_root/Sources/Legacy/SDBMetalRenderer.mm" \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework AVFoundation \
  -framework Metal -framework CoreImage -framework QuartzCore -o "$task_temp/EngineAudioGateTests"
"$task_temp/EngineAudioGateTests" "$project_root/Resources/Original" "$task_temp/save"
