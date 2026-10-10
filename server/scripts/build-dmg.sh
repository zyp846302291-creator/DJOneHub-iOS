#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-v0.1.1-preview}
DMG_NAME="DJOneHub-macOS-arm64-${VERSION}.dmg"
STAGE="${ROOT_DIR}/dist/dmg-stage"
DMG="${ROOT_DIR}/dist/${DMG_NAME}"

echo "==> 1/4 构建 Go 主程序与 libusb"
"${ROOT_DIR}/scripts/package-macos-arm64.sh" "${VERSION}"

echo "==> 2/4 构建通知助手（含自检）"
(cd "${ROOT_DIR}/macos/DJOneHubNotifier" && ./build-app.sh)

echo "==> 3/4 组装安装目录"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
ditto --norsrc --noextattr --noqtn --noacl "${ROOT_DIR}/dist/release/DJOneHub-macOS-arm64-${VERSION}" "${STAGE}/djonehub"
ditto --norsrc --noextattr --noqtn --noacl "${ROOT_DIR}/macos/DJOneHubNotifier/dist/DJOneHubNotifier.app" "${STAGE}/DJOneHubNotifier.app"
cp "${ROOT_DIR}/scripts/dmg/安装 DJOneHub.command" "${STAGE}/安装 DJOneHub.command"
cp "${ROOT_DIR}/scripts/dmg/卸载 DJOneHub.command" "${STAGE}/卸载 DJOneHub.command"
cp "${ROOT_DIR}/scripts/dmg/使用说明.txt" "${STAGE}/使用说明.txt"
chmod 755 "${STAGE}/安装 DJOneHub.command" "${STAGE}/卸载 DJOneHub.command"

echo "==> 4/4 生成 DMG"
rm -f "${DMG}"
hdiutil create -volname "DJOneHub" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
hdiutil verify "${DMG}"

echo
echo "完成：${DMG}"
