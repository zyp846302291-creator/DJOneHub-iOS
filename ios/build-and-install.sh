#!/bin/bash
# DJOneHub 构建脚本 — 自动递增版本号、编译、安装到iPhone
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$PROJECT_DIR/DJOneHub/Resources/Info.plist"
DEVICE_ID="00008150-00043DD42E42401C"

# --- 1. 自动递增 CFBundleVersion (用 PlistBuddy，sed 对多行 plist 不可靠) ---
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEXT=$((CURRENT + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$PLIST"
SHORT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
echo "📌 版本: $SHORT_VER ($CURRENT → $NEXT)"

# --- 2. 清理缓存 + 编译 ---
cd "$PROJECT_DIR"
rm -rf ~/Library/Developer/Xcode/DerivedData/DJOneHub-bejonhphrfdxrcdxgzfqatkijtnm 2>/dev/null
xcodegen generate 2>&1 > /dev/null
echo "🔨 编译中..."
xcodebuild -project DJOneHub.xcodeproj -scheme DJOneHub \
    -destination "id=$DEVICE_ID" \
    -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD"

# --- 3. 安装到iPhone ---
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/DJOneHub-*/Build/Products/Debug-iphoneos -name "DJOneHub.app" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "❌ 找不到编译产物"
    exit 1
fi
echo "📲 安装到 iPhone..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | grep -E "installed|error|ERROR"
echo "✅ DJOneHub v$SHORT_VER ($NEXT) 已安装"