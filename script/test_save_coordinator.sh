#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-save-coordinator.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun clang++ -std=c++17 -O1 -g -fobjc-arc -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$project_root/Sources/Legacy" \
  "$project_root/Tests/SaveCoordinatorTests.mm" "$project_root/Sources/Legacy/SDBSaveStore.mm" \
  -framework Foundation -o "$task_temp/SaveCoordinatorTests"
"$task_temp/SaveCoordinatorTests" "$task_temp"
