#!/usr/bin/env bash
# Build MacSCP.app (release), embed AppIcon.icns, optionally codesign, and create a DMG.
#
# Used by: make package-dmg
# See: docs/packaging.md
#
# Usage:
#   ./scripts/package-dmg.sh
#   MACSCP_SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-dmg.sh
#   MACSCP_SKIP_SIGN=1 ./scripts/package-dmg.sh
#
# Output:
#   build/MacSCP.app
#   dist/MacSCP-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

APP_NAME="MacSCP"
BUNDLE_ID="${MACSCP_BUNDLE_ID:-com.macscp.app}"
SHORT_VERSION="${MACSCP_SHORT_VERSION:-0.1.0}"
BUILD_VERSION="${MACSCP_BUILD_VERSION:-${SHORT_VERSION}}"
SIGN_IDENTITY="${MACSCP_SIGN_IDENTITY:-}"
SKIP_SIGN="${MACSCP_SKIP_SIGN:-0}"

BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DIST_DIR="${ROOT}/dist"
DMG_NAME="${APP_NAME}-${SHORT_VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

echo "==> Building release binary"
swift build -c release --product "${APP_NAME}"

ARCH="$(uname -m)"
RELEASE_BIN="${ROOT}/.build/release/${APP_NAME}"
if [[ ! -x "${RELEASE_BIN}" ]]; then
  RELEASE_BIN="${ROOT}/.build/${ARCH}-apple-macosx/release/${APP_NAME}"
fi
if [[ ! -x "${RELEASE_BIN}" ]]; then
  echo "Release binary not found for ${APP_NAME}" >&2
  exit 1
fi

echo "==> Generating App Icon (.icns + asset catalog)"
"${ROOT}/scripts/generate-app-icon.sh"
ICNS="${BUILD_DIR}/AppIcon.icns"

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${RELEASE_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ICNS}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

if command -v xcrun >/dev/null 2>&1 && xcrun actool --help >/dev/null 2>&1; then
  echo "==> Compiling asset catalog (optional Assets.car)"
  ACTOOL_OUT="${BUILD_DIR}/actool"
  rm -rf "${ACTOOL_OUT}"
  mkdir -p "${ACTOOL_OUT}"
  if xcrun actool "${ROOT}/packaging/MacSCP.xcassets" \
      --compile "${ACTOOL_OUT}" \
      --platform macosx \
      --minimum-deployment-target 15.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "${ACTOOL_OUT}/partial.plist" 2>/dev/null; then
    if [[ -f "${ACTOOL_OUT}/Assets.car" ]]; then
      cp "${ACTOOL_OUT}/Assets.car" "${APP_DIR}/Contents/Resources/Assets.car"
    fi
  else
    echo "    actool skipped (CFBundleIconFile + AppIcon.icns used)"
  fi
fi

INFO_PLIST="${BUILD_DIR}/Info.plist"
sed \
  -e "s/MACSCP_SHORT_VERSION/${SHORT_VERSION}/g" \
  -e "s/MACSCP_BUILD_VERSION/${BUILD_VERSION}/g" \
  "${ROOT}/packaging/Info.plist" > "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${INFO_PLIST}" 2>/dev/null || true
cp "${INFO_PLIST}" "${APP_DIR}/Contents/Info.plist"

if [[ "${SKIP_SIGN}" != "1" ]]; then
  if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "==> Code signing with: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime --timestamp \
      --sign "${SIGN_IDENTITY}" \
      "${APP_DIR}/Contents/MacOS/${APP_NAME}"
    codesign --force --deep --options runtime --timestamp \
      --sign "${SIGN_IDENTITY}" \
      "${APP_DIR}"
  else
    echo "==> Ad-hoc code signing (set MACSCP_SIGN_IDENTITY for distribution)"
    codesign --force --deep --sign - "${APP_DIR}" || true
  fi
else
  echo "==> Skipping code sign (MACSCP_SKIP_SIGN=1)"
fi

echo "==> Creating DMG"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

if [[ -n "${SIGN_IDENTITY}" && "${SKIP_SIGN}" != "1" ]]; then
  echo "==> Signing DMG"
  codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}" || true
fi

echo ""
echo "Done."
echo "  App: ${APP_DIR}"
echo "  DMG: ${DMG_PATH}"
echo "  Icon catalog: ${ROOT}/packaging/MacSCP.xcassets/AppIcon.appiconset"
echo "  ICNS: ${ICNS}"
