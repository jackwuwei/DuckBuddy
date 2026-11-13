#!/usr/bin/env bash
# 构建 DuckCore.xcframework 与 Swift 绑定，输出到 app/ios/DuckCore/。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
OUT=../ios/DuckCore
PROFILE=${PROFILE:-release}
FLAG=$([ "$PROFILE" = release ] && echo --release || true)
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
for t in "${TARGETS[@]}"; do rustup target add "$t" >/dev/null; cargo build $FLAG --lib --target "$t"; done

GEN=$(mktemp -d)
cargo run --quiet --bin uniffi-bindgen -- generate --library "target/aarch64-apple-ios/$PROFILE/libduck_core.a" \
  --language swift --out-dir "$GEN"
mkdir -p "$GEN/headers"
cp "$GEN"/*.h "$GEN/headers/"
cat "$GEN"/*.modulemap > "$GEN/headers/module.modulemap"

rm -rf "$OUT/DuckCoreFFI.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/$PROFILE/libduck_core.a" -headers "$GEN/headers" \
  -library "target/aarch64-apple-ios-sim/$PROFILE/libduck_core.a" -headers "$GEN/headers" \
  -output "$OUT/DuckCoreFFI.xcframework" >/dev/null
cp "$GEN/duck_core.swift" "$OUT/DuckCore.swift"
rm -rf "$GEN"
echo "✓ $OUT"
