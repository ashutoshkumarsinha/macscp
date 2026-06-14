#!/usr/bin/env bash
# Update Homebrew cask metadata for a release DMG (sha256 + version).
#
# Usage:
#   ./scripts/prepare-homebrew-release.sh 0.3.0
#   ./scripts/prepare-homebrew-release.sh 0.3.0 dist/MacSCP-0.3.0.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: $0 <version> [dmg-path]}"
DMG="${2:-${ROOT}/dist/MacSCP-${VERSION}.dmg}"
CASK="${ROOT}/packaging/homebrew/Casks/macscp.rb"

if [[ ! -f "${DMG}" ]]; then
  echo "DMG not found: ${DMG}" >&2
  echo "Run: make package-dmg MACSCP_SHORT_VERSION=${VERSION}" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
RELEASE_URL="https://github.com/ashutoshkumarsinha/macscp/releases/download/v${VERSION}/MacSCP-${VERSION}.dmg"

python3 - <<PY
from pathlib import Path
import re

cask = Path("${CASK}")
text = cask.read_text()
text = re.sub(r'version "[^"]+"', f'version "${VERSION}"', text, count=1)
text = re.sub(r'sha256 :no_check', f'sha256 "${SHA256}"', text, count=1)
text = re.sub(
    r'url "[^"]+"',
    f'url "{RELEASE_URL}"',
    text,
    count=1,
)
cask.write_text(text)
PY

echo "Updated ${CASK}"
echo "  version ${VERSION}"
echo "  sha256  ${SHA256}"
echo "  url     ${RELEASE_URL}"
