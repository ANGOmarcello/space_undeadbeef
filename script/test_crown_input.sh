#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-undeadbeef-crown.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
source "$project_root/script/prepare_metal_library.sh"
sdb_prepare_metal_library "$task_temp"
mkdir "$task_temp/save"

for source in SDBEngine.mm GuestCPU.cpp GameDisplayPatch.cpp SDBMetalRenderer.mm SDBAudioMixer.mm SDBSaveStore.mm; do
  options=(-std=c++17 -O2 -DSDB_HEADLESS_TESTS=1 -I "$project_root/Sources/Legacy")
  [[ "$source" != *.mm ]] || options+=(-fobjc-arc)
  xcrun clang++ "${options[@]}" -c "$project_root/Sources/Legacy/$source" -o "$task_temp/${source%.*}.o"
done
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$task_temp/module-cache" \
  -import-objc-header "$project_root/Sources/Legacy/SDBEngine.h" \
  "$project_root/Sources/Host/GameFrameClock.swift" \
  "$project_root/Sources/Host/GameHaptics.swift" \
  "$project_root/Sources/Host/GameCrownInput.swift" \
  "$project_root/Sources/Host/GameInputController.swift" \
  "$project_root/Sources/Host/GameMenuAccessibility.swift" \
  "$project_root/Sources/Host/GameLifecycle.swift" \
  "$project_root/Sources/Host/GameProgressSync.swift" \
  "$project_root/Sources/Host/GameSession.swift" \
  "$project_root/Tests/CrownInputTests.swift" \
  "$task_temp/"*.o -lc++ \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -framework Metal -framework CoreImage -framework QuartzCore \
  -o "$task_temp/CrownInputTests"
"$task_temp/CrownInputTests" "$project_root/Resources/Original" "$task_temp/save"
