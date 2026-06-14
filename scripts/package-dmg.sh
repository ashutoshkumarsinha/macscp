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
#
# Related: scripts/generate-app-icon.sh, scripts/build-finder-sync.sh, packaging/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# --- Configuration ---

APP_NAME="MacSCP"
BUNDLE_ID="${MACSCP_BUNDLE_ID:-com.macscp.app}"
SHORT_VERSION="${MACSCP_SHORT_VERSION:-0.3.0}"
BUILD_VERSION="${MACSCP_BUILD_VERSION:-${SHORT_VERSION}}"
SIGN_IDENTITY="${MACSCP_SIGN_IDENTITY:-}"
SKIP_SIGN="${MACSCP_SKIP_SIGN:-0}"

BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DIST_DIR="${ROOT}/dist"
DMG_NAME="${APP_NAME}-${SHORT_VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# --- Build release binaries ---

echo "==> Building release binaries"
swift build -c release --product "${APP_NAME}"
swift build -c release --product macscp-cli

ARCH="$(uname -m)"
RELEASE_BIN="${ROOT}/.build/release/${APP_NAME}"
CLI_BIN="${ROOT}/.build/release/macscp-cli"
if [[ ! -x "${RELEASE_BIN}" ]]; then
  RELEASE_BIN="${ROOT}/.build/${ARCH}-apple-macosx/release/${APP_NAME}"
fi
if [[ ! -x "${CLI_BIN}" ]]; then
  CLI_BIN="${ROOT}/.build/${ARCH}-apple-macosx/release/macscp-cli"
fi
if [[ ! -x "${RELEASE_BIN}" ]]; then
  echo "Release binary not found for ${APP_NAME}" >&2
  exit 1
fi
if [[ ! -x "${CLI_BIN}" ]]; then
  echo "Release binary not found for macscp-cli" >&2
  exit 1
fi

# --- App icon and bundle assembly ---

echo "==> Generating App Icon (.icns + asset catalog)"
"${ROOT}/scripts/generate-app-icon.sh"
ICNS="${BUILD_DIR}/AppIcon.icns"

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${RELEASE_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${CLI_BIN}" "${APP_DIR}/Contents/MacOS/macscp"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}" "${APP_DIR}/Contents/MacOS/macscp"
cp "${ICNS}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# actool is optional; CFBundleIconFile + AppIcon.icns suffice when it is unavailable.
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
cp "${ROOT}/packaging/MacSCP.sdef" "${APP_DIR}/Contents/Resources/MacSCP.sdef"
cp "${ROOT}/NOTICE" "${APP_DIR}/Contents/Resources/NOTICE"

# --- Finder Sync extension ---

if [[ -x "${ROOT}/scripts/build-finder-sync.sh" ]]; then
  echo "==> Building Finder Sync extension"
  MACSCP_SHORT_VERSION="${SHORT_VERSION}" MACSCP_BUILD_VERSION="${BUILD_VERSION}" \
    "${ROOT}/scripts/build-finder-sync.sh"
  mkdir -p "${APP_DIR}/Contents/PlugIns"
  cp -R "${BUILD_DIR}/MacSCPFinderSync.appex" "${APP_DIR}/Contents/PlugIns/"
fi

# --- Code signing ---

if [[ "${SKIP_SIGN}" != "1" ]]; then
  ENTITLEMENTS="${ROOT}/packaging/MacSCP.entitlements"
  if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "==> Code signing with: ${SIGN_IDENTITY}"
    if [[ -d "${APP_DIR}/Contents/PlugIns/MacSCPFinderSync.appex" ]]; then
      codesign --force --options runtime --timestamp \
        --entitlements "${ROOT}/Extensions/MacSCPFinderSync/MacSCPFinderSync.entitlements" \
        --sign "${SIGN_IDENTITY}" \
        "${APP_DIR}/Contents/PlugIns/MacSCPFinderSync.appex"
    fi
    codesign --force --deep --options runtime --timestamp \
      --entitlements "${ENTITLEMENTS}" \
      --sign "${SIGN_IDENTITY}" \
      "${APP_DIR}/Contents/MacOS/${APP_NAME}"
    codesign --force --deep --options runtime --timestamp \
      --entitlements "${ENTITLEMENTS}" \
      --sign "${SIGN_IDENTITY}" \
      "${APP_DIR}"
  else
    echo "==> Ad-hoc code signing (set MACSCP_SIGN_IDENTITY for distribution)"
    codesign --force --deep --sign - "${APP_DIR}" || true
  fi
else
  echo "==> Skipping code sign (MACSCP_SKIP_SIGN=1)"
fi

# --- DMG creation ---

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

if [[ "${MACSCP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> Notarizing DMG (MACSCP_NOTARIZE=1)"
  "${ROOT}/scripts/notarize-dmg.sh" "${DMG_PATH}"
fi

echo ""
echo "Done."
echo "  App: ${APP_DIR}"
echo "  DMG: ${DMG_PATH}"
echo "  Icon catalog: ${ROOT}/packaging/MacSCP.xcassets/AppIcon.appiconset"
echo "  ICNS: ${ICNS}"
