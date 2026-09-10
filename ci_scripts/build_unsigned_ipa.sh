#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
PRODUCTS_DIR="${BUILD_DIR}/Build/Products/Release-iphoneos"
IPA_STAGING_DIR="${BUILD_DIR}/ipa"
IPA_PATH="${BUILD_DIR}/doer-unsigned.ipa"

cd "${ROOT_DIR}"

XCODEBUILD_ARGS=(
  -workspace "${ROOT_DIR}/Doer.xcworkspace"
  -scheme Doer
  -configuration Release
  -sdk iphoneos
  -destination 'generic/platform=iOS'
  -derivedDataPath "${BUILD_DIR}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
  CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-1}"
  COMPILER_INDEX_STORE_ENABLE=NO
)

echo "==> Building Doer"
if [[ "${CI:-}" == "true" ]]; then
  echo "==> Compiling DoH (swift-nio / BoringSSL); this often takes 15+ minutes"
  xcodebuild "${XCODEBUILD_ARGS[@]}" build 2>&1 | python3 -u -c '
import sys
skip = (
    "SwiftDriverJobDiscovery",
    "SwiftExplicitDependencyGeneratePcm",
    "builtin-Swift-Compilation",
    "builtin-SwiftDriver",
    "builtin-copy",
    "builtin-swiftHeaderTool",
    "appintentsmetadataprocessor",
    "Constructing build description",
    "note: Emitting module",
)
for line in sys.stdin:
    lower = line.lower()
    if "error:" in lower or "fatal error" in lower or "** build" in lower:
        sys.stdout.write(line)
        sys.stdout.flush()
        continue
    if any(token in line for token in skip):
        continue
    sys.stdout.write(line)
    sys.stdout.flush()
'
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
fi

APP_PATH="${PRODUCTS_DIR}/Doer.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  find "${BUILD_DIR}" -name 'Doer.app' -print >&2 || true
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
