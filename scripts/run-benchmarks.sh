#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

"${ROOT}/scripts/benchmark-env.sh" start

cleanup() {
  "${ROOT}/scripts/benchmark-env.sh" stop || true
}
trap cleanup EXIT

swift run macscp-benchmark "$@"
