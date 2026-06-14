#!/usr/bin/env bash
# Verify macscp-benchmark pass criteria in a JSON report.
#
# Exits 0 when summary.passCriteriaMet is true; non-zero otherwise.
# Prints each failed scenario before exiting.
#
# Used by: make bench-verify, .github/workflows/ci.yml, run-benchmarks.sh --verify
#
# Usage:
#   ./scripts/verify-benchmark-report.sh
#   ./scripts/verify-benchmark-report.sh .benchmark/benchmark-results/report.json
#
# Related: run-benchmarks.sh, Sources/MacSCPBenchmark/
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
results = report.get("results", [])
failed = [r for r in results if not r.get("passed")]

if failed:
    print("Failed benchmark scenarios:", file=sys.stderr)
    for item in failed:
        scenario = item.get("scenario", "?")
        notes = item.get("notes", "")
        print(f"  - {scenario}: {notes}", file=sys.stderr)

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
