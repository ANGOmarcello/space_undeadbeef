#!/usr/bin/env bash
# Created by Angelo Cammalleri on 25.10.2026.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TEMP="$(mktemp -d /private/tmp/space-undeadbeef-tests.XXXXXX)"
trap 'rm -rf "$TASK_TEMP"' EXIT
cd "$PROJECT_ROOT"
xcrun clang++ -std=c++17 -O1 -g -Wall -Wextra -Wpedantic -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I Sources/Legacy Sources/Legacy/GuestCPU.cpp Tests/GuestCPUTests.cpp \
  -o "$TASK_TEMP/GuestCPUTests"
"$TASK_TEMP/GuestCPUTests"
xcrun clang++ -std=c++17 -O1 -g -fobjc-arc \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I Sources/Legacy Sources/Legacy/GuestCPU.cpp Sources/Legacy/SDBEngine.mm Tests/RuntimeSmoke.mm \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework AVFoundation \
  -o "$TASK_TEMP/RuntimeSmoke"
SDB_SMOKE_SOUND=1 "$TASK_TEMP/RuntimeSmoke" "$PROJECT_ROOT/Resources/Original" "$TASK_TEMP/captures" 160 40 600
