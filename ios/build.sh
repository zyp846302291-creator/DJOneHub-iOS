#!/bin/zsh
set -eu

root="${0:A:h}"
cd "${root}"

DEVICE_ID="YOUR_DEVICE_UDID"

echo "=== Building DJOneHub iOS ==="
xcodebuild -scheme DJOneHub -project DJOneHub.xcodeproj \
    -destination "id=${DEVICE_ID}" -configuration Debug \
    2>&1 | tail -3

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/DJOneHub-*/Build/Products/Debug-iphoneos -name "DJOneHub.app" -type d 2>/dev/null | head -1)
echo "App: ${APP_PATH}"

echo "=== Installing to iPhone ==="
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}" 2>&1

echo "✅ Done"
