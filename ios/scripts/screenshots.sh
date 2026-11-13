#!/usr/bin/env bash
# 演示模式截图：每页 × 多种窗口（手机竖 / 横、iPhone Duo 外屏 / 内屏、iPad），用于与设计稿对照。
# 用法：scripts/screenshots.sh <输出目录> [页面...]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?输出目录}; shift || true
PAGES=${*:-connect setup drive status policy gamepad settings}
BUILD=${BUILD_DIR:-$(mktemp -d)}
DEVICE=${DEVICE:-"iPad Pro 13-inch (M4)"}
xcodebuild -project DuckBuddy.xcodeproj -target DuckBuddy -configuration Debug -sdk iphonesimulator -arch arm64 \
  SYMROOT="$BUILD" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$BUILD/Debug-iphonesimulator/DuckBuddy.app"
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
mkdir -p "$OUT"
# 名称:窗口  （phone=设计稿 390×844 / 844×390；duo-cover≈5.4" 外屏；duo-open≈7.6" 内屏；ipad=不限制）
WINDOWS=${WINDOWS:-"phone-portrait:390x844 phone-landscape:844x390 duo-cover:375x812 duo-open:820x904 ipad:full"}
for page in $PAGES; do
  for w in $WINDOWS; do
    name=${w%%:*}; size=${w##*:}
    args=(-demo)
    [ "$page" != connect ] && args+=(-route "$page")
    [ "$size" != full ] && args+=(-simulateWindow "$size")
    xcrun simctl terminate "$UDID" ai.pollen.duckbuddy 2>/dev/null || true
    xcrun simctl launch "$UDID" ai.pollen.duckbuddy "${args[@]}" "${EXTRA_ARGS[@]:-}" >/dev/null
    sleep "${WAIT:-3}"
    xcrun simctl io "$UDID" screenshot "$OUT/$page-$name.png" >/dev/null 2>&1
    echo "$OUT/$page-$name.png"
  done
done
