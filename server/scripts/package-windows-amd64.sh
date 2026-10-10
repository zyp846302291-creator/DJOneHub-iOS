#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-v1.2.10}
PACKAGE_NAME="DJOneHub-Windows-amd64-${VERSION}"
STAGE_ROOT="${ROOT_DIR}/dist/release"
STAGE_DIR="${STAGE_ROOT}/${PACKAGE_NAME}"
ARCHIVE="${STAGE_ROOT}/${PACKAGE_NAME}.zip"
CHECKSUM="${ARCHIVE}.sha256"
BUILD_ROOT="${TMPDIR:-/tmp}/djonehub-windows-package"

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required to build the Windows package." >&2
  exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "zip is required to build the Windows package." >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}" "${BUILD_ROOT}" "${STAGE_ROOT}"

cd "${ROOT_DIR}"
GOCACHE="${BUILD_ROOT}/go-cache" CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
  go build -trimpath -buildvcs=false -ldflags="-s -w -H=windowsgui" \
  -o "${STAGE_DIR}/DJOneHub.exe" ./cmd/djonehub-macos

cp "${ROOT_DIR}/windows/install.ps1" "${STAGE_DIR}/install.ps1"
cp "${ROOT_DIR}/windows/uninstall.ps1" "${STAGE_DIR}/uninstall.ps1"
cp "${ROOT_DIR}/windows/Install DJOneHub.cmd" "${STAGE_DIR}/Install DJOneHub.cmd"
cp "${ROOT_DIR}/windows/Stop DJOneHub.cmd" "${STAGE_DIR}/Stop DJOneHub.cmd"
cp "${ROOT_DIR}/windows/README-Windows.txt" "${STAGE_DIR}/README-Windows.txt"
cp "${ROOT_DIR}/LICENSE" "${STAGE_DIR}/LICENSE"
cp "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${STAGE_DIR}/THIRD_PARTY_NOTICES.md"

if find "${STAGE_DIR}" -type f \( -name '*.ko' -o -name '*.armv7' \) | grep -q .; then
  echo "Public package unexpectedly contains a module-side runtime." >&2
  exit 1
fi

rm -f "${ARCHIVE}" "${CHECKSUM}"
(
  cd "${STAGE_ROOT}"
  zip -q -r "$(basename -- "${ARCHIVE}")" "${PACKAGE_NAME}"
  shasum -a 256 "$(basename -- "${ARCHIVE}")" >"$(basename -- "${CHECKSUM}")"
)

echo "Release directory: ${STAGE_DIR}"
echo "Release archive:   ${ARCHIVE}"
echo "Checksum:          ${CHECKSUM}"
