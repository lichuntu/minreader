#!/bin/bash
# 编译 MinReader 并打包成未签名 IPA
set -euo pipefail

APP_NAME=MinReader
MIN_IOS=15.0
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ---- 选最新 Xcode ----
if [ -d /Applications ]; then
  newest=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "${newest:-}" ] && [ -d "$newest/Contents/Developer" ]; then
    echo "使用 Xcode: $newest"
    (sudo xcode-select -s "$newest" 2>/dev/null) || (xcode-select -s "$newest" 2>/dev/null) || true
  fi
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "--- 环境 ---"
echo "Xcode:   $(xcodebuild -version | head -1)"
echo "SDK 版本: $(xcrun --sdk iphoneos --show-sdk-version)"

APP_DIR="build/Payload/$APP_NAME.app"
rm -rf build dist
mkdir -p "$APP_DIR" dist

SRCS=$(ls src/*.m)
echo "源文件: $SRCS"

echo "--- 1/4 编译 ---"
xcrun --sdk iphoneos clang \
  -target "arm64-apple-ios$MIN_IOS" \
  -isysroot "$SDK" \
  -fobjc-arc \
  -O2 \
  -Wall \
  -I src \
  -framework UIKit \
  -framework Foundation \
  -lz \
  -o "$APP_DIR/$APP_NAME" \
  $SRCS

echo "--- 2/4 Info.plist ---"
cp resources/Info.plist "$APP_DIR/Info.plist"
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Info.plist"
fi
plutil -lint "$APP_DIR/Info.plist"

echo "--- 3/4 图标 ---"
python3 tools/genicon.py "$APP_DIR"

echo "--- 4/4 打包 ---"
( cd build && zip -qry "../dist/$APP_NAME.ipa" Payload )

echo "=== 产物 ==="
ls -l "dist/$APP_NAME.ipa"
echo "=== IPA 内容 ==="
unzip -l "dist/$APP_NAME.ipa"
echo "=== 架构 ==="
lipo -info "$APP_DIR/$APP_NAME"
echo "=== 平台 ==="
xcrun vtool -show-build "$APP_DIR/$APP_NAME"
echo "=== 动态库依赖 ==="
otool -L "$APP_DIR/$APP_NAME" | head -10
echo "=== 完成: dist/$APP_NAME.ipa ==="
