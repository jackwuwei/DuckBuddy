#!/usr/bin/env bash
# 打 iOS 安装包（dev 签名 ipa）：TEAM=<Apple 团队 ID> ios/scripts/package.sh <输出目录> [版本号] [构建号]
# 用本机钥匙串里该团队的开发证书自动签名，
# 产物可用 xcrun devicectl 或 Apple Configurator 装到已注册的设备；dev 签名过期后重装即可。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
VER=${2:-0.1.0}
BUILD=${3:-1}
TEAM=${TEAM:?请用 TEAM=<Apple 团队 ID> 指定签名团队}

"$ROOT/core/scripts/build-ios.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/ios"
xcodebuild -project DuckBuddy.xcodeproj -scheme DuckBuddy -configuration Release \
  -destination generic/platform=iOS -archivePath "$WORK/DuckBuddy.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$BUILD" \
  -quiet archive

cat > "$WORK/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$WORK/DuckBuddy.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates -quiet

cp "$WORK/export/DuckBuddy.ipa" "$OUT/DuckBuddy-$VER.ipa"
# 符号文件：崩溃报告离线符号化用
(cd "$WORK/DuckBuddy.xcarchive" && zip -qr "$OUT/DuckBuddy-$VER-ios-dSYMs.zip" dSYMs)
echo "✓ $OUT/DuckBuddy-$VER.ipa"
