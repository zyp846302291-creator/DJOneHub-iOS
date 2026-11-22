#!/bin/zsh
# DJOneHub iOS 续签脚本：重新构建并安装到 iPhone（不递增版本号）
set -eu
set -o pipefail

root="${0:A:h}"
cd "${root}"

DEVICE_ID="00008150-00043DD42E42401C"
DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
BUILD_LOG="$(mktemp -t djonehub-build.XXXXXX)"
START_TIME=$(date +%s)

cleanup() { rm -f "$BUILD_LOG"; }
trap cleanup EXIT

# 只删 DJOneHub 自己的 DerivedData 目录，且路径必须落在 DerivedData 之下。
echo "=== 清理旧编译产物 ==="
for d in "$DERIVED_ROOT"/DJOneHub-*(N/); do
  case "$d" in
    "$DERIVED_ROOT"/DJOneHub-*) rm -rf "$d" ;;
  esac
done

echo "=== Building DJOneHub iOS ==="
# -allowProvisioningUpdates：让 Xcode 自动申请/续签 provisioning profile。
# 不加的话，免费账号的 profile 过期后会报 "No profiles ... were found"。
# 完整日志写入临时文件，失败时打印真正的错误原因，绝不拿旧产物去装。
if ! xcodebuild -scheme DJOneHub -project DJOneHub.xcodeproj \
    -destination "id=${DEVICE_ID}" -configuration Debug \
    -allowProvisioningUpdates build > "$BUILD_LOG" 2>&1; then
  echo "❌ 构建失败，错误原因："
  grep -E "error:|No Accounts|BUILD FAILED" "$BUILD_LOG" | sort -u | head -20
  echo "---"
  echo "若提示 No Accounts：Xcode → Settings → Accounts 重新登录 Apple ID 后再跑。"
  exit 1
fi
grep -E "\*\* BUILD SUCCEEDED \*\*" "$BUILD_LOG"

APP_PATH=$(find "$DERIVED_ROOT" -path "*/Build/Products/Debug-iphoneos/DJOneHub.app" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "❌ 找不到编译产物"
  exit 1
fi

# 产物必须是本次构建生成的，防止把过期的旧包装到手机上。
if [ "$(stat -f %m "$APP_PATH/Info.plist")" -lt "$START_TIME" ]; then
  echo "❌ 编译产物不是本次生成的，中止安装"
  exit 1
fi
echo "App: ${APP_PATH}"

echo "=== Installing to iPhone ==="
if ! xcrun devicectl device install app --device "${DEVICE_ID}" "$APP_PATH"; then
  echo "❌ 安装失败（iPhone 是否已解锁并信任此 Mac？）"
  exit 1
fi

echo "✅ Done：DJOneHub 已重新签名安装（版本号未变）"
