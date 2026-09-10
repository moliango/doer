#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
PRODUCTS_DIR="${BUILD_DIR}/Build/Products/Release-iphoneos"
IPA_STAGING_DIR="${BUILD_DIR}/ipa"
IPA_PATH="${BUILD_DIR}/doer-unsigned.ipa"

XCODEBUILD_COMMON=(
  -configuration Release
  -sdk iphoneos
  -derivedDataPath "${BUILD_DIR}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)

build_project_scheme() {
  local project_path="$1"
  local scheme="$2"

  echo "==> Building ${scheme}"
  xcodebuild \
    -project "${ROOT_DIR}/${project_path}" \
    -scheme "${scheme}" \
    "${XCODEBUILD_COMMON[@]}" \
    build
}

cd "${ROOT_DIR}"

# Swift packages resolve as part of the app project; no Tuist-derived
# package xcodeprojs need to be built first.
build_project_scheme "Doer.xcodeproj" "Doer"

APP_PATH="${PRODUCTS_DIR}/Doer.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

rm -rf "${IPA_STAGING_DIR}" "${IPA_PATH}"
mkdir -p "${IPA_STAGING_DIR}/Payload"
cp -R "${APP_PATH}" "${IPA_STAGING_DIR}/Payload/"

(
  cd "${IPA_STAGING_DIR}"
  zip -qry "${IPA_PATH}" Payload
)

echo "==> Unsigned IPA created: ${IPA_PATH}"
