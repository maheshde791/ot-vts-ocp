#!/usr/bin/env bash
# ==============================================================================
# worker_read.sh - Parallel Worker for VTS Read Requests
# ==============================================================================
set -euo pipefail

WORKER_ID="${1:-1}"
NUM_REQUESTS="${2:-100}"
TARGET_URL="${3:-https://vts-server.local}"
INSTANCE_PORT="${4:-2000}"
OUTPUT_FILE="${5:-read_worker_${INSTANCE_PORT}_${WORKER_ID}.csv}"
MAX_INDEX="${6:-500}"
AUTH="${7:-}"

AUTH_FLAG=""
if [[ -n "${AUTH}" ]]; then
    AUTH_FLAG="-u ${AUTH}"
fi

ENDPOINT="${TARGET_URL}/?portnumber=${INSTANCE_PORT}/client_api/get"

for ((i = 1; i <= NUM_REQUESTS; i++)); do
    ROW_IDX=$(( (RANDOM % MAX_INDEX) + 1 ))
    REQ_TIME=$(date +"%Y-%m-%d %H:%M:%S.%3N")
    
    METRICS=$(curl -k -s -w "%{time_total} %{http_code}" -o /dev/null -X POST "${ENDPOINT}" \
        ${AUTH_FLAG} \
        -H "Content-Type: application/json" \
        -d "{\"colName\": \"Customer_ID\", \"index\": ${ROW_IDX}}" \
        --max-time 10 || echo "10.000000 000")

    LATENCY_SEC=$(echo "$METRICS" | awk '{print $1}')
    HTTP_CODE=$(echo "$METRICS" | awk '{print $2}')
    LATENCY_MS=$(awk -v s="$LATENCY_SEC" 'BEGIN { printf "%.2f", s * 1000 }')
    
    echo "${REQ_TIME},READ,${INSTANCE_PORT},${WORKER_ID},${i},${HTTP_CODE},${LATENCY_MS}" >> "${OUTPUT_FILE}"
done
