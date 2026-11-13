#!/usr/bin/env bash
# 演示模式截图（Android）：每页 × 窗口，用于与设计稿对照。需要已启动的模拟器（如 Pixel Fold）。
# 用法：scripts/screenshots.sh <输出目录> [页面...]；WINDOWS="name:WxH ..."（full = 不限制）
set -euo pipefail
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
OUT=${1:?输出目录}; shift || true
PAGES=${*:-connect setup drive status policy gamepad settings}
WINDOWS=${WINDOWS:-"phone-portrait:390x844 phone-landscape:844x390 full:full"}
mkdir -p "$OUT"
for page in $PAGES; do
  for w in $WINDOWS; do
    name=${w%%:*}; size=${w##*:}
    args=(--ez demo true)
    [ "$page" != connect ] && args+=(--es route "$page")
    [ "$size" != full ] && args+=(--es window "$size")
    "$ADB" shell am force-stop robot.duckbuddy.microduck
    "$ADB" shell am start -n robot.duckbuddy.microduck/.MainActivity "${args[@]}" >/dev/null
    sleep "${WAIT:-4}"
    "$ADB" shell screencap -p /sdcard/duck.png 2>/dev/null; "$ADB" pull -q /sdcard/duck.png "$OUT/$page-$name.png" >/dev/null
    echo "$OUT/$page-$name.png"
  done
done
