#!/usr/bin/env bash
# Run macscp-benchmark against the local OpenSSH SFTP fixture.
#
# Starts benchmark-env.sh, runs benchmarks, stops server on exit.
# Used by: make bench, make bench-full, make bench-apple-silicon
#
# Usage:
#   ./scripts/run-benchmarks.sh
#   ./scripts/run-benchmarks.sh --verify
#   MACSCP_BENCH_FULL=1 ./scripts/run-benchmarks.sh
#   MACSCP_BENCH_NETWORK=wifi ./scripts/run-benchmarks.sh --verify
#
# Environment:
#   MACSCP_BENCH_FULL=1       Full file sizes and 10k small files
#   MACSCP_BENCH_NETWORK      loopback | lan | wifi | wan (tagged in report hostInfo)
#   MACSCP_BENCH_HOST/PORT/USER/KEY  Override fixture connection (see BenchmarkConfig)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

VERIFY=0
BENCH_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --verify)
      VERIFY=1
      ;;
    *)
      BENCH_ARGS+=("${arg}")
      ;;
  esac
done

"${ROOT}/scripts/benchmark-env.sh" start

cleanup() {
  "${ROOT}/scripts/benchmark-env.sh" stop || true
}
trap cleanup EXIT

if ((${#BENCH_ARGS[@]} > 0)); then
  swift run macscp-benchmark "${BENCH_ARGS[@]}"
else
  swift run macscp-benchmark
fi

if [[ "${VERIFY}" -eq 1 ]]; then
  "${ROOT}/scripts/verify-benchmark-report.sh"
fi
