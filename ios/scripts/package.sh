#!/usr/bin/env bash
# 打 iOS 安装包（未签名 ipa）：ios/scripts/package.sh <输出目录> [版本号] [构建号]
# 不需要证书和团队；装到设备前要用自己的证书重签（如 AltStore、Sideloadly 或 codesign + 描述文件）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
VER=${2:-0.1.0}
BUILD=${3:-1}

"$ROOT/core/scripts/build-ios.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/ios"
xcodebuild -project DuckBuddy.xcodeproj -scheme DuckBuddy -configuration Release \
  -destination generic/platform=iOS -archivePath "$WORK/DuckBuddy.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$BUILD" \
  -quiet archive

# ipa 就是 Payload/<App>.app 的 zip
mkdir -p "$WORK/ipa/Payload"
ditto "$WORK/DuckBuddy.xcarchive/Products/Applications/DuckBuddy.app" "$WORK/ipa/Payload/DuckBuddy.app"
rm -f "$OUT/DuckBuddy-$VER.ipa"
(cd "$WORK/ipa" && zip -qry "$OUT/DuckBuddy-$VER.ipa" Payload)
echo "✓ $OUT/DuckBuddy-$VER.ipa"
