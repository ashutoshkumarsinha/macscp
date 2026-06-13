#!/usr/bin/env bash
# Generate macOS App Icon sizes for Assets.xcassets and AppIcon.icns from the master PNG.
# Crops non-square masters to a center square, then writes all required slots.
#
# Used by: make icon
# See: docs/packaging.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${MACSCP_ICON_MASTER:-${ROOT}/Resources/AppIcon/MacSCP-AppIcon-1024.png}"
ICONSET="${ROOT}/packaging/MacSCP.xcassets/AppIcon.appiconset"
ICNS_OUT="${MACSCP_ICNS_OUT:-${ROOT}/build/AppIcon.icns}"
WORK_DIR="${ROOT}/build/icon-work"
WORK_ICONSET="${ROOT}/build/AppIcon.iconset"

if [[ ! -f "${MASTER}" ]]; then
  echo "Master icon not found: ${MASTER}" >&2
  exit 1
fi

mkdir -p "${ICONSET}" "${WORK_DIR}" "${WORK_ICONSET}" "$(dirname "${ICNS_OUT}")"
rm -f "${WORK_ICONSET}"/*

SQUARE="${WORK_DIR}/master-square.png"
cp "${MASTER}" "${SQUARE}"

WIDTH="$(sips -g pixelWidth "${SQUARE}" | awk '/pixelWidth/{print $2}')"
HEIGHT="$(sips -g pixelHeight "${SQUARE}" | awk '/pixelHeight/{print $2}')"
SIDE="${WIDTH}"
if (( HEIGHT < WIDTH )); then SIDE="${HEIGHT}"; fi

if (( WIDTH != HEIGHT )); then
  echo "Cropping master ${WIDTH}x${HEIGHT} → square ${SIDE}x${SIDE}"
  sips -c "${SIDE}" "${SIDE}" "${SQUARE}" --out "${SQUARE}" >/dev/null
fi

sips -z 1024 1024 "${SQUARE}" --out "${ICONSET}/AppIcon-1024.png" >/dev/null
cp "${ICONSET}/AppIcon-1024.png" "${ROOT}/Resources/AppIcon/MacSCP-AppIcon-1024.png"

echo "Generating App Icon sizes in ${ICONSET} …"

make_size() {
  local size="$1"
  local name="$2"
  sips -z "${size}" "${size}" "${ICONSET}/AppIcon-1024.png" --out "${ICONSET}/${name}" >/dev/null
  cp "${ICONSET}/${name}" "${WORK_ICONSET}/${name}"
}

make_size 16  icon_16x16.png
make_size 32  icon_16x16@2x.png
make_size 32  icon_32x32.png
make_size 64  icon_32x32@2x.png
make_size 128 icon_128x128.png
make_size 256 icon_128x128@2x.png
make_size 256 icon_256x256.png
make_size 512 icon_256x256@2x.png
make_size 512 icon_512x512.png
cp "${ICONSET}/AppIcon-1024.png" "${WORK_ICONSET}/icon_512x512@2x.png"

iconutil -c icns "${WORK_ICONSET}" -o "${ICNS_OUT}"
echo "AppIcon.icns → ${ICNS_OUT}"
echo "Asset catalog (1024pt slot: AppIcon-1024.png) → ${ICONSET}"
echo "Square master → ${ROOT}/Resources/AppIcon/MacSCP-AppIcon-1024.png"
