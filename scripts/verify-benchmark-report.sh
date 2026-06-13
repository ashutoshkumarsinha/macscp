#!/usr/bin/env bash
# Verify macscp-benchmark pass criteria in a JSON report.
#
# Exits 0 when summary.passCriteriaMet is true; non-zero otherwise.
# Used by: make bench-verify, .github/workflows/ci.yml
#
# Usage:
#   ./scripts/verify-benchmark-report.sh
#   ./scripts/verify-benchmark-report.sh .benchmark/benchmark-results/report.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="${1:-${ROOT}/.benchmark/benchmark-results/report.json}"

if [[ ! -f "${REPORT}" ]]; then
  echo "Benchmark report not found: ${REPORT}" >&2
  echo "Run: make bench or make bench-apple-silicon" >&2
  exit 1
fi

python3 - "${REPORT}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    report = json.load(handle)

summary = report.get("summary", {})
if not summary.get("passCriteriaMet"):
    print("Benchmark pass criteria not met:", json.dumps(summary, indent=2), file=sys.stderr)
    sys.exit(1)

print("passCriteriaMet=true")
print(f"report={path}")
if host := report.get("config", {}).get("hostInfo"):
    print(
        f"host={host.get('architecture')} cores={host.get('processorCount')} "
        f"network={host.get('networkProfile')}"
    )
large = summary.get("citadelLargeFileRatio")
small = summary.get("citadelSmallFileRatio")
if large is not None or small is not None:
    print(f"large_file_ratio={large} small_file_ratio={small}")
PY
