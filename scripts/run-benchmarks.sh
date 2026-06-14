#!/usr/bin/env bash
# Run macscp-benchmark against the local OpenSSH SFTP fixture.
#
# Builds and runs the release macscp-benchmark binary (debug skews small-file timings).
# Starts benchmark-env.sh unless the subcommand is cloud-backends (WebDAV/S3 only).
#
# Usage:
#   ./scripts/run-benchmarks.sh
#   ./scripts/run-benchmarks.sh --verify
#   ./scripts/run-benchmarks.sh pool-connect
#   ./scripts/run-benchmarks.sh --keep-server multiplex-spike
#   MACSCP_BENCH_FULL=1 ./scripts/run-benchmarks.sh
#
# Flags:
#   --verify       Run verify-benchmark-report.sh after the benchmark
#   --keep-server  Leave the SFTP fixture running on exit
#
# Environment:
#   MACSCP_BENCH_FULL=1       Full file sizes and 10k small files
#   MACSCP_BENCH_NETWORK      loopback | lan | wifi | wan (tagged in report hostInfo)
#   MACSCP_BENCH_HOST/PORT/USER/KEY  Override fixture connection (see BenchmarkConfig)
#   MACSCP_BENCH_KEEP_SERVER=1        Same as --keep-server
#
# Subcommands (passed to macscp-benchmark):
#   upload-spike, profile-upload, pool-connect, multiplex-spike, proxy-command, cloud-backends
#
# Related: benchmark-env.sh, benchmark-cloud-env.sh, verify-benchmark-report.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
BENCHMARK_BIN="${ROOT}/.build/release/macscp-benchmark"

# --- Parse arguments ---

VERIFY=0
KEEP_SERVER=0
BENCH_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --verify)
      VERIFY=1
      ;;
    --keep-server)
      KEEP_SERVER=1
      ;;
    *)
      BENCH_ARGS+=("${arg}")
      ;;
  esac
done

if [[ "${MACSCP_BENCH_KEEP_SERVER:-0}" == "1" ]]; then
  KEEP_SERVER=1
fi

SUBCOMMAND="${BENCH_ARGS[0]:-}"
NEEDS_SFTP=1
if [[ "${SUBCOMMAND}" == "cloud-backends" ]]; then
  NEEDS_SFTP=0
fi

# --- Build release benchmark harness ---

swift build -c release --product macscp-benchmark

# --- Start SFTP fixture when required ---

if [[ "${NEEDS_SFTP}" -eq 1 ]]; then
  "${ROOT}/scripts/benchmark-env.sh" start
fi

cleanup() {
  if [[ "${NEEDS_SFTP}" -eq 1 && "${KEEP_SERVER}" -eq 0 ]]; then
    "${ROOT}/scripts/benchmark-env.sh" stop || true
  fi
}
if [[ "${NEEDS_SFTP}" -eq 1 ]]; then
  trap cleanup EXIT
fi

# --- Run benchmarks ---

if ((${#BENCH_ARGS[@]} > 0)); then
  "${BENCHMARK_BIN}" "${BENCH_ARGS[@]}"
else
  "${BENCHMARK_BIN}"
fi

# --- Optional pass-criteria check ---

if [[ "${VERIFY}" -eq 1 ]]; then
  "${ROOT}/scripts/verify-benchmark-report.sh"
fi
