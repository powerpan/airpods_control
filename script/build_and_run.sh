#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="run"
SIMULATE=0
for argument in "$@"; do
  case "$argument" in
    --simulate) SIMULATE=1 ;;
    run|--verify|--debug|--logs|--telemetry|--build-only) MODE="$argument" ;;
    *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry|--build-only] [--simulate]" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" != "--build-only" ]]; then
  pkill -x AirPodsMotionLab >/dev/null 2>&1 || true
fi
mkdir -p build
xcodebuild -quiet -project AirPodsMotionLab.xcodeproj -scheme AirPodsMotionLab \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/build/ModuleCache" build 2>&1 | tee build/build.log

APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/AirPodsMotionLab.app"
case "$MODE" in
  --build-only) exit 0 ;;
  --debug)
    if [[ "$SIMULATE" == 1 ]]; then
      exec lldb -- "$APP_BUNDLE/Contents/MacOS/AirPodsMotionLab" --simulate
    else
      exec lldb -- "$APP_BUNDLE/Contents/MacOS/AirPodsMotionLab"
    fi
    ;;
esac
if [[ "$SIMULATE" == 1 ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --simulate
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify)
    sleep 2
    pgrep -x AirPodsMotionLab >/dev/null
    echo "AirPodsMotionLab launched."
    ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "AirPodsMotionLab"'
    ;;
esac
