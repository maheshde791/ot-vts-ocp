#!/usr/bin/env bash
# ==============================================================================
# master_load_tester.sh - Master Load Testing & Benchmark Orchestrator for VTS
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"

# Default Configuration
TARGET_URL="https://vts-server.local"
INSTANCE_PORTS=("8888" "2000" "2001")
READ_WORKERS=10
READ_REQS_PER_WORKER=50
WRITE_WORKERS=10
WRITE_REQS_PER_WORKER=50
VM_HOST="192.168.122.245"
SSH_USER="vtsadmin"
MAX_INDEX=500
AUTH=""

# Parse CLI Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url) TARGET_URL="$2"; shift 2 ;;
        --ports) IFS=' ' read -r -a INSTANCE_PORTS <<< "$2"; shift 2 ;;
        --read-workers) READ_WORKERS="$2"; shift 2 ;;
        --read-reqs) READ_REQS_PER_WORKER="$2"; shift 2 ;;
        --write-workers) WRITE_WORKERS="$2"; shift 2 ;;
        --write-reqs) WRITE_REQS_PER_WORKER="$2"; shift 2 ;;
        --vm-host) VM_HOST="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --auth) AUTH="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --url <url>             Target VTS URL (default: https://vts-server.local)"
            echo "  --ports \"p1 p2 p3\"      Target Instance Ports (default: \"8888 2000 2001\")"
            echo "  --read-workers <n>      Parallel read threads per instance (default: 10)"
            echo "  --read-reqs <n>         Requests per read worker (default: 50)"
            echo "  --write-workers <n>     Parallel write threads per instance (default: 10)"
            echo "  --write-reqs <n>        Requests per write worker (default: 50)"
            echo "  --vm-host <host>        Target VM for CPU/RAM monitoring (default: 192.168.122.245)"
            echo "  --ssh-user <user>       SSH user for VM monitoring (default: vtsadmin)"
            echo "  --auth <user:pass>      HTTP Basic Auth credentials if enabled"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

NUM_PORTS=${#INSTANCE_PORTS[@]}
TOTAL_READ_WORKERS=$(( READ_WORKERS * NUM_PORTS ))
TOTAL_WRITE_WORKERS=$(( WRITE_WORKERS * NUM_PORTS ))
TOTAL_CONCURRENCY=$(( TOTAL_READ_WORKERS + TOTAL_WRITE_WORKERS ))

TOTAL_READ_REQS=$(( TOTAL_READ_WORKERS * READ_REQS_PER_WORKER ))
TOTAL_WRITE_REQS=$(( TOTAL_WRITE_WORKERS * WRITE_REQS_PER_WORKER ))
TOTAL_REQUESTS=$(( TOTAL_READ_REQS + TOTAL_WRITE_REQS ))

AUTH_CHECK=""
if [[ -n "${AUTH}" ]]; then
    AUTH_CHECK="-u ${AUTH}"
fi

echo "================================================================================"
echo "          INITIALIZING VTS MULTI-INSTANCE LOAD TEST & BENCHMARK                 "
echo "================================================================================"
echo " Target Endpoint     : ${TARGET_URL}"
echo " Active Instances    : ${INSTANCE_PORTS[*]} (${NUM_PORTS} instances under load simultaneously)"
echo " Workers / Instance  : ${READ_WORKERS} Readers + ${WRITE_WORKERS} Writers = $((READ_WORKERS + WRITE_WORKERS)) threads/instance"
echo " Total Concurrency   : ${TOTAL_CONCURRENCY} parallel worker threads across all instances"
echo " Total Requests      : ${TOTAL_REQUESTS} (${TOTAL_READ_REQS} Reads, ${TOTAL_WRITE_REQS} Writes)"
echo " Target VM Monitor   : ${SSH_USER}@${VM_HOST}"
if [[ -n "${AUTH}" ]]; then
    echo " Authentication      : Enabled (Basic Auth)"
fi
echo "--------------------------------------------------------------------------------"

# Step 1: Pre-flight check on ALL instances
echo "[1/5] Running pre-flight health checks across all instances..."
for port in "${INSTANCE_PORTS[@]}"; do
    echo -n "  -> Checking Instance on Port ${port}... "
    HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -X POST "${TARGET_URL}/?portnumber=${port}/client_api/getAllColumns" ${AUTH_CHECK} -H "Content-Type: application/json" -d '{}' || echo "000")
    if [[ "${HTTP_STATUS}" != "200" ]]; then
        echo "FAILED! (HTTP ${HTTP_STATUS})"
        echo "Error: Cannot connect to instance on port ${port}. If Basic Auth is enabled, provide --auth 'user:pass'."
        exit 1
    fi
    echo "OK (HTTP 200)"
done

# Ensure results directory exists
mkdir -p "${RESULTS_DIR}"

# Step 2: Use temporary scratch directory for in-flight CSV processing (automatically deleted at end)
TMP_DIR=$(mktemp -d /tmp/vts_load_XXXXXX)
cleanup_tmp() {
    rm -rf "${TMP_DIR}"
}
trap cleanup_tmp EXIT INT TERM

RAW_RESULTS_FILE="${TMP_DIR}/all_requests.csv"
VM_METRICS_FILE="${TMP_DIR}/vm_metrics.csv"

# Step 3: Start VM Resource Monitoring in Background
echo -n "[2/5] Starting background CPU/RAM monitor on VM (${SSH_USER}@${VM_HOST})... "
"${SCRIPT_DIR}/monitor_vm.sh" "${VM_METRICS_FILE}" "${VM_HOST}" "${SSH_USER}" 1 >/dev/null 2>&1 &
MONITOR_PID=$!
echo "Active (PID: ${MONITOR_PID})"

# Capture starting timestamp for filename & metrics
TIME_FROM=$(date +"%Y%m%d_%H%M%S")
START_TIME=$(date +%s.%N)

# Brief pause to capture baseline metrics before load
sleep 2

# Step 4: Launch Parallel Workers across all 3 instances
echo "[3/5] Spawning ${TOTAL_CONCURRENCY} parallel worker threads across instances [${INSTANCE_PORTS[*]}]..."
WORKER_PIDS=()

for port in "${INSTANCE_PORTS[@]}"; do
    # Launch Read Workers for this port
    for ((w = 1; w <= READ_WORKERS; w++)); do
        WORKER_OUTPUT="${TMP_DIR}/read_${port}_${w}.csv"
        "${SCRIPT_DIR}/worker_read.sh" "${w}" "${READ_REQS_PER_WORKER}" "${TARGET_URL}" "${port}" "${WORKER_OUTPUT}" "${MAX_INDEX}" "${AUTH}" &
        WORKER_PIDS+=($!)
    done

    # Launch Write Workers for this port
    for ((w = 1; w <= WRITE_WORKERS; w++)); do
        WORKER_OUTPUT="${TMP_DIR}/write_${port}_${w}.csv"
        "${SCRIPT_DIR}/worker_write.sh" "${w}" "${WRITE_REQS_PER_WORKER}" "${TARGET_URL}" "${port}" "${WORKER_OUTPUT}" "${MAX_INDEX}" "${AUTH}" &
        WORKER_PIDS+=($!)
    done
done

echo "[4/5] Multi-instance load test in progress (${TOTAL_REQUESTS} requests running in parallel)..."

# Wait for all workers across all instances to complete
for pid in "${WORKER_PIDS[@]}"; do
    wait "${pid}"
done

END_TIME=$(date +%s.%N)
TIME_TO=$(date +"%Y%m%d_%H%M%S")
DURATION=$(awk -v s="${START_TIME}" -v e="${END_TIME}" 'BEGIN { printf "%.2f", e - s }')

echo "Load execution finished in ${DURATION} seconds."

# Step 5: Stop Monitor & Consolidate Results
echo -n "[5/5] Finalizing metrics and calculating per-instance percentiles... "
kill "${MONITOR_PID}" 2>/dev/null || true
wait "${MONITOR_PID}" 2>/dev/null || true

# Consolidate all worker CSVs
cat "${TMP_DIR}"/*_*.csv > "${RAW_RESULTS_FILE}" 2>/dev/null || true
echo "Done."
echo ""

# Format Report Filename: <userNumber>users_<requests>requests_<timestampfrom>-<timestampto>.txt
REPORT_FILE="${RESULTS_DIR}/${TOTAL_CONCURRENCY}users_${TOTAL_REQUESTS}requests_${TIME_FROM}-${TIME_TO}.txt"

# Step 6: Generate Executive Multi-Instance Benchmark Report
# Printed directly to console AND saved into the designated report file
"${SCRIPT_DIR}/calculate_stats.sh" "${RAW_RESULTS_FILE}" "${VM_METRICS_FILE}" "${DURATION}" | tee "${REPORT_FILE}"

echo ""
echo " Report successfully saved to: ${REPORT_FILE}"
echo " (Temporary CSV files were cleaned up; results folder contains only final reports)"
echo "================================================================================"
