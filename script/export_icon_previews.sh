#!/usr/bin/env bash
# Created by Angelo Cammalleri on 29.10.2026.
# Review renders are kept outside the source tree unless explicitly requested.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "usage: $0 output-directory" >&2
  exit 2
fi
icon_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon_developer="$(xcode-select -p)"
icon_renderer="${icon_developer%/Developer}/Applications/Icon Composer.app/Contents/Executables/ictool"
icon_reviews="$1"
mkdir -p "$icon_reviews"
render() {
  "$icon_renderer" "$icon_root/Icon Composer/SpaceUndeadbeef.icon" --export-image \
    --output-file "$icon_reviews/$1-$2-$3.png" --platform "$1" --rendition "$2" \
    --width "$3" --height "$3" --scale 1 --design-generation 27 >/dev/null
}
for icon_platform in iOS macOS; do
  for icon_rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    render "$icon_platform" "$icon_rendition" 1024
    render "$icon_platform" "$icon_rendition" 64
  done
done
render watchOS Default 1088
render watchOS Default 64
printf 'Icon Composer previews: %s\n' "$icon_reviews"
