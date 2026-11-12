#!/usr/bin/env bash
# ==============================================================================
# monitor_vm.sh - Real-time CPU & RAM Utilization Monitor for Windows VM
# ==============================================================================
set -euo pipefail

OUTPUT_FILE="${1:-vm_metrics.csv}"
VM_NAME="${2:-Windows-Server-2025}"
INTERVAL="${3:-1}"

# Write CSV Header
echo "Timestamp,CPU_Usage_Pct,RAM_Used_MB,RAM_Total_MB,RAM_Usage_Pct" > "${OUTPUT_FILE}"

# Monitor VM via virsh domstats (hypervisor level)
python3 - << EOF
import subprocess, time, sys

domain = "${VM_NAME}"
output_file = "${OUTPUT_FILE}"
interval = float("${INTERVAL}")

def get_stats():
    try:
        out = subprocess.check_output(["virsh", "domstats", domain, "--cpu-total", "--balloon"], stderr=subprocess.DEVNULL).decode()
        cpu, rss, max_mem = 0, 0, 16384
        for line in out.splitlines():
            line = line.strip()
            if "cpu.time=" in line:
                cpu = int(line.split("=")[1])
            elif "balloon.rss=" in line:
                rss = int(line.split("=")[1]) // 1024
            elif "balloon.maximum=" in line:
                max_mem = int(line.split("=")[1]) // 1024
        return cpu, rss, max_mem
    except Exception:
        return 0, 0, 16384

with open(output_file, "a") as f:
    prev_cpu, prev_rss, max_mem = get_stats()
    prev_time = time.time()
    
    while True:
        time.sleep(interval)
        curr_cpu, curr_rss, max_mem = get_stats()
        curr_time = time.time()
        
        elapsed_ns = (curr_time - prev_time) * 1e9
        if elapsed_ns > 0 and prev_cpu > 0:
            cpu_pct = min(100.0, max(0.0, ((curr_cpu - prev_cpu) / (elapsed_ns * 8)) * 100))
        else:
            cpu_pct = 0.0
            
        mem_pct = (curr_rss / max_mem * 100) if max_mem else 0
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        
        f.write(f"{ts},{cpu_pct:.1f},{curr_rss},{max_mem},{mem_pct:.1f}\n")
        f.flush()
        
        prev_cpu = curr_cpu
        prev_time = curr_time
EOF

