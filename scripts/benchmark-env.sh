#!/usr/bin/env bash
# Start/stop a local OpenSSH SFTP server for MacSCP development and benchmarks.
#
# Port 2222 by default. Keys and data live under .benchmark/
# Used by: make server-start, make run, make bench
#
# Usage:
#   ./scripts/benchmark-env.sh start|stop|restart|status
#   MACSCP_BENCH_PORT=2223 ./scripts/benchmark-env.sh start
#
# Related: run-benchmarks.sh, verify-benchmark-report.sh, ci-local.sh (see docs/README.md)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="${ROOT}/.benchmark"
KEYS="${BENCH_DIR}/keys"
DATA="${BENCH_DIR}/data"
RUN="${BENCH_DIR}/run"
PORT="${MACSCP_BENCH_PORT:-2222}"
USER_NAME="${MACSCP_BENCH_USER:-$(whoami)}"

# --- Server lifecycle ---

start() {
  mkdir -p "${KEYS}" "${DATA}" "${RUN}"

  if [[ ! -f "${KEYS}/host_key" ]]; then
    ssh-keygen -t ed25519 -f "${KEYS}/host_key" -N "" -C "macscp-bench-host"
  fi
  if [[ ! -f "${KEYS}/client_key" ]]; then
    ssh-keygen -t ed25519 -f "${KEYS}/client_key" -N "" -C "macscp-bench-client"
  fi
  if [[ ! -f "${KEYS}/client_encrypted" ]]; then
    ssh-keygen -t ed25519 -f "${KEYS}/client_encrypted" -N "benchpass" -C "macscp-bench-encrypted"
  fi

  cp "${KEYS}/client_key.pub" "${KEYS}/authorized_keys"
  cat "${KEYS}/client_encrypted.pub" >> "${KEYS}/authorized_keys"

  cat > "${BENCH_DIR}/sshd_config" <<EOF
Port ${PORT}
ListenAddress 127.0.0.1
HostKey ${KEYS}/host_key
AuthorizedKeysFile ${KEYS}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
PidFile ${RUN}/sshd.pid
StrictModes no
AllowUsers ${USER_NAME}
Subsystem sftp /usr/libexec/sftp-server
EOF

  if [[ -f "${RUN}/sshd.pid" ]] && kill -0 "$(cat "${RUN}/sshd.pid")" 2>/dev/null; then
    echo "SFTP test server already running on port ${PORT} (pid $(cat "${RUN}/sshd.pid"))"
    return 0
  fi

  /usr/sbin/sshd -f "${BENCH_DIR}/sshd_config"
  sleep 0.5

  if ! nc -z 127.0.0.1 "${PORT}" 2>/dev/null; then
    echo "Failed to start sshd on port ${PORT}" >&2
    exit 1
  fi

  echo "SFTP test server started on 127.0.0.1:${PORT}"
  echo "  User: ${USER_NAME} (key auth)"
  echo "  Client key: ${KEYS}/client_key"
  echo "  Encrypted key: ${KEYS}/client_encrypted (passphrase: benchpass)"
  echo "  Data dir: ${DATA}"
}

stop() {
  if [[ -f "${RUN}/sshd.pid" ]]; then
    kill "$(cat "${RUN}/sshd.pid")" 2>/dev/null || true
    rm -f "${RUN}/sshd.pid"
    echo "SFTP test server stopped"
  else
    pkill -f "sshd -f ${BENCH_DIR}/sshd_config" 2>/dev/null || true
    echo "SFTP test server stopped (if running)"
  fi
}

status() {
  if nc -z 127.0.0.1 "${PORT}" 2>/dev/null; then
    echo "listening on ${PORT}"
    exit 0
  fi
  echo "not running"
  exit 1
}

# --- Command dispatch ---

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 1
    ;;
esac
