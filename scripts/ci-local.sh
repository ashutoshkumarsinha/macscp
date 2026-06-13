#!/usr/bin/env bash
# Run the same checks as GitHub Actions CI locally.
#
# Usage:
#   ./scripts/ci-local.sh
#   ./scripts/ci-local.sh --skip-bench   # tests only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

SKIP_BENCH=0
for arg in "$@"; do
  case "${arg}" in
    --skip-bench)
      SKIP_BENCH=1
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--skip-bench]" >&2
      exit 2
      ;;
  esac
done

echo "==> make check"
make check

if [[ "${SKIP_BENCH}" -eq 1 ]]; then
  echo "==> skipping benchmarks (--skip-bench)"
  exit 0
fi

echo "==> make bench-verify"
make bench-verify

echo "==> CI checks passed"
