#!/usr/bin/env bash
# Created by Angelo Cammalleri on 26.10.2026.
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
TASK_TEMP="$(mktemp -d /private/tmp/space-undeadbeef-audio.XXXXXX)"
trap 'rm -rf "$TASK_TEMP"' EXIT

xcrun clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I "$PROJECT_ROOT/Sources/Legacy" \
  "$PROJECT_ROOT/Tests/AudioMixerTests.mm" \
  "$PROJECT_ROOT/Sources/Legacy/SDBAudioMixer.mm" \
  -framework Foundation -framework AVFoundation \
  -o "$TASK_TEMP/AudioMixerTests"
# Manual rendering is configured before the mixer exists. This test never opens
# an output device or changes system sound preferences. Restricted environments
# without built-in audio components return 77 rather than making audio claims.
"$TASK_TEMP/AudioMixerTests" "$RESOURCES" "$TASK_TEMP"
