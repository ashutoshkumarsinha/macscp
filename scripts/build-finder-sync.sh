#!/usr/bin/env bash
# Build the MacSCP Finder Sync extension (.appex) for embedding in MacSCP.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="${ROOT}/Extensions/MacSCPFinderSync"
BUILD_DIR="${ROOT}/build"
APPEX="${BUILD_DIR}/MacSCPFinderSync.appex"
SHORT_VERSION="${MACSCP_SHORT_VERSION:-0.3.0}"
BUILD_VERSION="${MACSCP_BUILD_VERSION:-${SHORT_VERSION}}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos15.0"

echo "==> Building Finder Sync extension"
rm -rf "${APPEX}"
mkdir -p "${APPEX}/Contents/MacOS"

swiftc \
  -parse-as-library \
  -O \
  -target "${TARGET}" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-name MacSCPFinderSync \
  -o "${APPEX}/Contents/MacOS/MacSCPFinderSync" \
  "${EXT_DIR}/FinderSync.swift" \
  -framework FinderSync \
  -framework Cocoa

INFO_PLIST="${BUILD_DIR}/FinderSync-Info.plist"
sed \
  -e "s/MACSCP_SHORT_VERSION/${SHORT_VERSION}/g" \
  -e "s/MACSCP_BUILD_VERSION/${BUILD_VERSION}/g" \
  -e 's/\$(PRODUCT_MODULE_NAME)/MacSCPFinderSync/g' \
  "${EXT_DIR}/Info.plist" > "${INFO_PLIST}"
cp "${INFO_PLIST}" "${APPEX}/Contents/Info.plist"

echo "    ${APPEX}"
