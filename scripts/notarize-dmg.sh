#!/usr/bin/env bash
# Submit a MacSCP DMG to Apple notary service and staple the ticket.
#
# Requires:
#   MACSCP_APPLE_ID          Apple ID email
#   MACSCP_APPLE_TEAM_ID     Team ID (10 chars)
#   MACSCP_APPLE_PASSWORD    App-specific password or keychain profile item
#
# Optional:
#   MACSCP_NOTARY_PROFILE    notarytool keychain profile (instead of password)
#
# Usage:
#   ./scripts/notarize-dmg.sh dist/MacSCP-0.3.0.dmg
#   MACSCP_NOTARY_PROFILE=macscp-notary ./scripts/notarize-dmg.sh dist/MacSCP-0.3.0.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-${ROOT}/dist/MacSCP-0.3.0.dmg}"

if [[ ! -f "${DMG}" ]]; then
  echo "DMG not found: ${DMG}" >&2
  echo "Run make package-dmg first." >&2
  exit 1
fi

echo "==> Submitting ${DMG} for notarization"
if [[ -n "${MACSCP_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "${DMG}" --keychain-profile "${MACSCP_NOTARY_PROFILE}" --wait
else
  : "${MACSCP_APPLE_ID:?Set MACSCP_APPLE_ID}"
  : "${MACSCP_APPLE_TEAM_ID:?Set MACSCP_APPLE_TEAM_ID}"
  : "${MACSCP_APPLE_PASSWORD:?Set MACSCP_APPLE_PASSWORD or MACSCP_NOTARY_PROFILE}"
  xcrun notarytool submit "${DMG}" \
    --apple-id "${MACSCP_APPLE_ID}" \
    --team-id "${MACSCP_APPLE_TEAM_ID}" \
    --password "${MACSCP_APPLE_PASSWORD}" \
    --wait
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

echo "Notarized and stapled: ${DMG}"
