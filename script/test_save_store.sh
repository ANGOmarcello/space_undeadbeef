#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-undeadbeef-save-store.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun clang++ -std=c++17 -O1 -g -fobjc-arc -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I "$project_root/Sources/Legacy" \
  "$project_root/Sources/Legacy/SDBSaveStore.mm" "$project_root/Sources/Legacy/GuestCPU.cpp" "$project_root/Tests/SaveStoreTests.mm" \
  -framework Foundation -o "$task_temp/SaveStoreTests"
"$task_temp/SaveStoreTests" "$task_temp/saves" "$project_root/Resources/Original/psh"
