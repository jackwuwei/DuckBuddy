#!/usr/bin/env bash
# 打 Android 安装包（release APK）：android/scripts/package.sh <输出目录> [版本号] [构建号]
# 用本机 ~/.android/debug.keystore 签名：同一台 Mac 打出的包可以互相覆盖升级；
# 上架商店前需要换成正式签名。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
VER=${2:-0.1.0}
BUILD=${3:-1}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export JAVA_HOME=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}

"$ROOT/core/scripts/build-android.sh"

cd "$ROOT/android"
./gradlew --no-daemon -q :app:assembleRelease -PappVersionName="$VER" -PappVersionCode="$BUILD"
cp app/build/outputs/apk/release/app-release.apk "$OUT/DuckBuddy-$VER.apk"
echo "✓ $OUT/DuckBuddy-$VER.apk"
