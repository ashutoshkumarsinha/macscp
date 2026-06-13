#!/usr/bin/env bash
# Run macscp-benchmark against the local OpenSSH SFTP fixture.
#
# Starts benchmark-env.sh, runs benchmarks, stops server on exit.
# Used by: make bench, make bench-full
#
# Usage:
#   ./scripts/run-benchmarks.sh
#   MACSCP_BENCH_FULL=1 ./scripts/run-benchmarks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

"${ROOT}/scripts/benchmark-env.sh" start

cleanup() {
  "${ROOT}/scripts/benchmark-env.sh" stop || true
}
trap cleanup EXIT

swift run macscp-benchmark "$@"
