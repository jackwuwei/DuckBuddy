#!/usr/bin/env bash
# 构建各 ABI 的 libduck_core.so 与 Kotlin 绑定，输出到 app/android/app/src/main/{jniLibs,java}。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
NDK=${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}
HOST=$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)
BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
API=26
PROFILE=${PROFILE:-release}
FLAG=$([ "$PROFILE" = release ] && echo --release || true)
ANDROID=../android/app/src/main
# macOS 自带 bash 3.2 没有关联数组：三元组 目标:ABI:编译器前缀
for spec in aarch64-linux-android:arm64-v8a:aarch64-linux-android \
            armv7-linux-androideabi:armeabi-v7a:armv7a-linux-androideabi \
            x86_64-linux-android:x86_64:x86_64-linux-android; do
  IFS=: read -r t abi cc <<< "$spec"
  rustup target add "$t" >/dev/null
  up=$(echo "$t" | tr 'a-z-' 'A-Z_')
  export "CARGO_TARGET_${up}_LINKER=$BIN/${cc}${API}-clang"
  low=$(echo "$t" | tr '-' '_')
  export "CC_${low}=$BIN/${cc}${API}-clang"
  export "AR_${low}=$BIN/llvm-ar"
  cargo build $FLAG --lib --target "$t"
  mkdir -p "$ANDROID/jniLibs/$abi"
  cp "target/$t/$PROFILE/libduck_core.so" "$ANDROID/jniLibs/$abi/"
done
cargo run --quiet --bin uniffi-bindgen -- generate --library "target/aarch64-linux-android/$PROFILE/libduck_core.so" \
  --language kotlin --out-dir "$ANDROID/java"
echo "✓ $ANDROID"
