#!/usr/bin/env bash
# ==============================================================================
# monitor_vm.sh - Real-time CPU & RAM Utilization Monitor
# ==============================================================================
set -euo pipefail

OUTPUT_FILE="${1:-vm_metrics.csv}"
VM_HOST="${2:-192.168.122.245}"
SSH_USER="${3:-vtsadmin}"
INTERVAL="${4:-1}"

# Trap termination signal and kill child ssh process cleanly
SSH_PID=""
cleanup() {
    if [[ -n "${SSH_PID}" ]]; then
        kill "${SSH_PID}" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGINT SIGTERM

# Write CSV Header
echo "Timestamp,CPU_Usage_Pct,RAM_Used_MB,RAM_Total_MB,RAM_Usage_Pct" > "${OUTPUT_FILE}"

# Stream real-time CPU & RAM metrics from VM directly into OUTPUT_FILE
REMOTE_CMD='while true; do
  TS=$(date +"%Y-%m-%d %H:%M:%S")
  CPU=$(top -b -n 1 2>/dev/null | grep "%Cpu" | awk "{printf \"%.1f\", 100 - \$8}")
  MEM=$(free -m 2>/dev/null | awk "/Mem:/ {printf \"%d,%d,%.1f\", \$3, \$2, (\$3/\$2)*100}")
  echo "${TS},${CPU},${MEM}"
  sleep 1
done'

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${VM_HOST}" "${REMOTE_CMD}" >> "${OUTPUT_FILE}" 2>/dev/null &
SSH_PID=$!

wait "${SSH_PID}" 2>/dev/null || true
