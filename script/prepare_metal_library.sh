#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
# Source this helper, then prepare a headless library in the caller's mktemp dir.

sdb_prepare_metal_library() {
  local task_directory shader_root air_file
  if [[ $# != 1 || ! -d "$1" || "$1" != /* ]]; then
    printf 'Metal library preparation needs an existing absolute temporary directory.\n' >&2
    return 64
  fi
  task_directory="$(cd "$1" && pwd -P)" || return
  shader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || return
  air_file="$task_directory/SDBShaders.air"
  # Metal 2.4 uses a platform prefix on the command line. Keep its module cache
  # beside these disposable inputs rather than the repository or ~/.cache.
  if ! xcrun --sdk macosx metal -std=macos-metal2.4 \
      -fmodules-cache-path="$task_directory/metal-module-cache" \
      -c "$shader_root/Sources/Legacy/SDBShaders.metal" -o "$air_file"; then
    return 1
  fi
  # New Xcode Metal toolchains link through the metal driver; older installed
  # toolchains expose metallib separately. Both consume this same compiled AIR.
  if xcrun --sdk macosx --find metallib >/dev/null 2>&1; then
    if ! xcrun --sdk macosx metallib "$air_file" -o "$task_directory/default.metallib"; then return 1; fi
  else
    if ! xcrun --sdk macosx metal "$air_file" -o "$task_directory/default.metallib"; then return 1; fi
  fi
  rm -f "$air_file"
  export SDB_METAL_LIBRARY="$task_directory/default.metallib"
}
