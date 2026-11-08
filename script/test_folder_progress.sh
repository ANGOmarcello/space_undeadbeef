#!/usr/bin/env bash
# Created by Angelo Cammalleri on 08.11.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-folder-progress.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -c \
  "$project_root/Sources/Legacy/SDBSaveStore.mm" -o "$task_temp/SDBSaveStore.o"
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$task_temp/module-cache" \
  -import-objc-header "$project_root/Sources/Legacy/SDBSaveStore.h" \
  "$project_root/Sources/Host/GameFolderProgress.swift" "$project_root/Tests/FolderProgressTests.swift" \
  "$task_temp/SDBSaveStore.o" -lc++ -framework Foundation -o "$task_temp/FolderProgressTests"
"$task_temp/FolderProgressTests" "$task_temp"
