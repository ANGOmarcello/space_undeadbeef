#!/usr/bin/env bash
# Created by Angelo Cammalleri on 25.10.2026.
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--build-only) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${SPACE_UNDEADBEEF_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/SpaceUndeadbeef-Restoration-macOS}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/SpaceUndeadbeef.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/SpaceUndeadbeef"

# Stop only this checkout's built instance; other apps and checkouts are untouched.
for pid in $(pgrep -x SpaceUndeadbeef 2>/dev/null || true); do
  executable="$(ps -p "$pid" -o comm=)"
  if [ "$executable" = "$APP_BINARY" ]; then
    if [ "$MODE" = --build-only ]; then
      echo "This build product is running. Stop its instance or choose another SPACE_UNDEADBEEF_DERIVED_DATA path." >&2
      exit 1
    fi
    kill -TERM "$pid"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  fi
done

xcodebuild -project "$PROJECT_ROOT/SPACE UNDEADBEEF.xcodeproj" \
  -scheme 'SPACE UNDEADBEEF macOS' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build

case "$MODE" in
  --build-only) ;;
  --debug) lldb -- "$APP_BINARY" ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "SpaceUndeadbeef"'
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x SpaceUndeadbeef >/dev/null
    ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
