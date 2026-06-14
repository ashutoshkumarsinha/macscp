#!/usr/bin/env bash
# Start/stop WebDAV + MinIO fixtures for cloud backend benchmarks.
#
# Usage:
#   ./scripts/benchmark-cloud-env.sh start|stop|status|env
#
# Exports (via `env` subcommand or eval):
#   MACSCP_BENCH_WEBDAV=1 MACSCP_BENCH_S3=1
#
# Related: docker/docker-compose.bench-cloud.yml, macscp-benchmark cloud-backends
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="${ROOT}/docker/docker-compose.bench-cloud.yml"
RUN="${ROOT}/.benchmark/cloud-run"
MINIO_DATA="${ROOT}/.benchmark/minio-data"
MINIO_PID="${RUN}/minio.pid"
MINIO_LOG="${RUN}/minio.log"

export MACSCP_BENCH_WEBDAV_HOST="${MACSCP_BENCH_WEBDAV_HOST:-127.0.0.1}"
export MACSCP_BENCH_WEBDAV_PORT="${MACSCP_BENCH_WEBDAV_PORT:-8080}"
export MACSCP_BENCH_WEBDAV_USER="${MACSCP_BENCH_WEBDAV_USER:-bench}"
export MACSCP_BENCH_WEBDAV_PASS="${MACSCP_BENCH_WEBDAV_PASS:-bench}"
export MACSCP_BENCH_WEBDAV_PATH="${MACSCP_BENCH_WEBDAV_PATH:-/}"
export MACSCP_BENCH_S3_HOST="${MACSCP_BENCH_S3_HOST:-127.0.0.1}"
export MACSCP_BENCH_S3_PORT="${MACSCP_BENCH_S3_PORT:-9000}"
export MACSCP_BENCH_S3_BUCKET="${MACSCP_BENCH_S3_BUCKET:-macscp-bench}"
export MACSCP_BENCH_S3_ACCESS_KEY="${MACSCP_BENCH_S3_ACCESS_KEY:-minioadmin}"
export MACSCP_BENCH_S3_SECRET_KEY="${MACSCP_BENCH_S3_SECRET_KEY:-minioadmin}"
export MACSCP_BENCH_S3_REGION="${MACSCP_BENCH_S3_REGION:-us-east-1}"

wait_port() {
  local host="$1"
  local port="$2"
  local attempts="${3:-30}"
  for _ in $(seq 1 "${attempts}"); do
    if nc -z "${host}" "${port}" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  docker compose -f "${COMPOSE}" up -d
  wait_port 127.0.0.1 "${MACSCP_BENCH_WEBDAV_PORT}" 60
  wait_port 127.0.0.1 "${MACSCP_BENCH_S3_PORT}" 60
  echo "Cloud fixtures started via Docker (WebDAV :${MACSCP_BENCH_WEBDAV_PORT}, MinIO :${MACSCP_BENCH_S3_PORT})"
  return 0
}

start_native_minio() {
  mkdir -p "${MINIO_DATA}" "${RUN}"
  if [[ -f "${MINIO_PID}" ]] && kill -0 "$(cat "${MINIO_PID}")" 2>/dev/null; then
    echo "MinIO already running (pid $(cat "${MINIO_PID}"))"
    return 0
  fi

  local minio_bin=""
  if command -v minio >/dev/null 2>&1; then
    minio_bin="$(command -v minio)"
  elif [[ -x "${RUN}/minio" ]]; then
    minio_bin="${RUN}/minio"
  else
    echo "MinIO binary not found; install via brew install minio/stable/minio or use Docker." >&2
    return 1
  fi

  MINIO_ROOT_USER="${MACSCP_BENCH_S3_ACCESS_KEY}" \
  MINIO_ROOT_PASSWORD="${MACSCP_BENCH_S3_SECRET_KEY}" \
    nohup "${minio_bin}" server "${MINIO_DATA}" --address ":${MACSCP_BENCH_S3_PORT}" \
    >"${MINIO_LOG}" 2>&1 &
  echo $! >"${MINIO_PID}"
  wait_port 127.0.0.1 "${MACSCP_BENCH_S3_PORT}" 30

  if command -v mc >/dev/null 2>&1; then
    mc alias set macscp-bench "http://127.0.0.1:${MACSCP_BENCH_S3_PORT}" \
      "${MACSCP_BENCH_S3_ACCESS_KEY}" "${MACSCP_BENCH_S3_SECRET_KEY}" >/dev/null 2>&1 || true
    mc mb -p "macscp-bench/${MACSCP_BENCH_S3_BUCKET}" 2>/dev/null || true
  fi

  echo "MinIO started natively on :${MACSCP_BENCH_S3_PORT} (WebDAV unavailable without Docker)"
  return 0
}

start() {
  if start_docker; then
    export MACSCP_BENCH_WEBDAV=1
    export MACSCP_BENCH_S3=1
    return 0
  fi

  if start_native_minio; then
    export MACSCP_BENCH_S3=1
    unset MACSCP_BENCH_WEBDAV || true
    echo "WebDAV skipped — start Docker for full cloud fixture set." >&2
    return 0
  fi

  echo "Failed to start cloud fixtures." >&2
  return 1
}

stop() {
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "${COMPOSE}" down >/dev/null 2>&1 || true
  fi
  if [[ -f "${MINIO_PID}" ]]; then
    kill "$(cat "${MINIO_PID}")" 2>/dev/null || true
    rm -f "${MINIO_PID}"
  fi
  echo "Cloud fixtures stopped"
}

status() {
  local ok=0
  if nc -z 127.0.0.1 "${MACSCP_BENCH_S3_PORT}" 2>/dev/null; then
    echo "MinIO listening on :${MACSCP_BENCH_S3_PORT}"
  else
    echo "MinIO not running"
    ok=1
  fi
  if nc -z 127.0.0.1 "${MACSCP_BENCH_WEBDAV_PORT}" 2>/dev/null; then
    echo "WebDAV listening on :${MACSCP_BENCH_WEBDAV_PORT}"
  else
    echo "WebDAV not running"
    ok=1
  fi
  return "${ok}"
}

print_env() {
  cat <<EOF
export MACSCP_BENCH_S3=1
export MACSCP_BENCH_S3_HOST=${MACSCP_BENCH_S3_HOST}
export MACSCP_BENCH_S3_PORT=${MACSCP_BENCH_S3_PORT}
export MACSCP_BENCH_S3_BUCKET=${MACSCP_BENCH_S3_BUCKET}
export MACSCP_BENCH_S3_ACCESS_KEY=${MACSCP_BENCH_S3_ACCESS_KEY}
export MACSCP_BENCH_S3_SECRET_KEY=${MACSCP_BENCH_S3_SECRET_KEY}
export MACSCP_BENCH_S3_REGION=${MACSCP_BENCH_S3_REGION}
EOF
  if nc -z 127.0.0.1 "${MACSCP_BENCH_WEBDAV_PORT}" 2>/dev/null; then
    cat <<EOF
export MACSCP_BENCH_WEBDAV=1
export MACSCP_BENCH_WEBDAV_HOST=${MACSCP_BENCH_WEBDAV_HOST}
export MACSCP_BENCH_WEBDAV_PORT=${MACSCP_BENCH_WEBDAV_PORT}
export MACSCP_BENCH_WEBDAV_USER=${MACSCP_BENCH_WEBDAV_USER}
export MACSCP_BENCH_WEBDAV_PASS=${MACSCP_BENCH_WEBDAV_PASS}
export MACSCP_BENCH_WEBDAV_PATH=${MACSCP_BENCH_WEBDAV_PATH}
EOF
  fi
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  env) print_env ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|env}" >&2
    exit 1
    ;;
esac
