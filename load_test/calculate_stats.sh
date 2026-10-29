#!/usr/bin/env bash
# ==============================================================================
# calculate_stats.sh - Aggregate Multi-Instance Latency & Resource Stats
# ==============================================================================
set -euo pipefail

RESULTS_CSV="${1:-results.csv}"
METRICS_CSV="${2:-vm_metrics.csv}"
DURATION_SEC="${3:-1}"

python3 - << EOF
import sys
import os

results_file = "${RESULTS_CSV}"
metrics_file = "${METRICS_CSV}"
duration = float("${DURATION_SEC}") if float("${DURATION_SEC}") > 0 else 1.0

def calculate_percentiles(latencies):
    if not latencies:
        return {"min": 0, "avg": 0, "p50": 0, "p90": 0, "p95": 0, "p99": 0, "max": 0}
    sorted_lats = sorted(latencies)
    n = len(sorted_lats)
    def p(pct):
        idx = int(round((pct / 100.0) * n)) - 1
        return sorted_lats[max(0, min(idx, n - 1))]
    return {
        "min": sorted_lats[0],
        "avg": sum(sorted_lats) / n,
        "p50": p(50),
        "p90": p(90),
        "p95": p(95),
        "p99": p(99),
        "max": sorted_lats[-1]
    }

# Data structures: port -> {"READ": [], "WRITE": []}
port_data = {}
all_lats = []
all_reads = []
all_writes = []
status_counts = {}

if os.path.exists(results_file):
    with open(results_file, 'r') as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) >= 7:
                op_type = parts[1]
                port = parts[2]
                code = parts[5]
                try:
                    lat = float(parts[6])
                except ValueError:
                    continue
                
                if port not in port_data:
                    port_data[port] = {"READ": [], "WRITE": []}
                
                all_lats.append(lat)
                if op_type in port_data[port]:
                    port_data[port][op_type].append(lat)
                
                if op_type == "READ":
                    all_reads.append(lat)
                elif op_type == "WRITE":
                    all_writes.append(lat)
                
                status_counts[code] = status_counts.get(code, 0) + 1

total_reqs = len(all_lats)
success_reqs = status_counts.get("200", 0)
error_reqs = total_reqs - success_reqs
rps = total_reqs / duration

all_stats = calculate_percentiles(all_lats)

# Read VM metrics
cpu_vals = []
ram_used_vals = []
ram_total = 0

if os.path.exists(metrics_file):
    with open(metrics_file, 'r') as f:
        lines = f.readlines()
        for line in lines[1:]: # skip header
            parts = line.strip().split(',')
            if len(parts) >= 5:
                try:
                    cpu_vals.append(float(parts[1]))
                    ram_used_vals.append(float(parts[2]))
                    ram_total = float(parts[3])
                except ValueError:
                    continue

cpu_min = min(cpu_vals) if cpu_vals else 0.0
cpu_avg = (sum(cpu_vals) / len(cpu_vals)) if cpu_vals else 0.0
cpu_max = max(cpu_vals) if cpu_vals else 0.0

ram_min = min(ram_used_vals) if ram_used_vals else 0.0
ram_avg = (sum(ram_used_vals) / len(ram_used_vals)) if ram_used_vals else 0.0
ram_max = max(ram_used_vals) if ram_used_vals else 0.0

# Print Multi-Instance Terminal Report
print("=" * 86)
print("             VTS MULTI-INSTANCE LOAD TEST & BENCHMARK REPORT (PARALLEL)         ")
print("=" * 86)
print(f" Test Duration          : {duration:.2f} seconds")
print(f" Target Instances       : {', '.join([f'Port {p}' for p in sorted(port_data.keys())])}")
print(f" Total Requests Run     : {total_reqs} ({len(all_reads)} Reads, {len(all_writes)} Writes)")
print(f" Successful (HTTP 200)  : {success_reqs} ({(success_reqs/total_reqs*100) if total_reqs else 0:.1f}%)")
print(f" Failed / Errors        : {error_reqs} ({(error_reqs/total_reqs*100) if total_reqs else 0:.1f}%)")
print(f" Overall Throughput     : {rps:.2f} Requests/Second (RPS)")
print("=" * 86)
print(f" {'INSTANCE':<14} | {'OP':<6} | {'COUNT':<6} | {'MIN':<6} | {'AVG':<6} | {'p50':<6} | {'p90':<6} | {'p95':<6} | {'p99':<6} | {'MAX':<6}")
print("-" * 86)

for port in sorted(port_data.keys()):
    r_stats = calculate_percentiles(port_data[port]["READ"])
    w_stats = calculate_percentiles(port_data[port]["WRITE"])
    p_combined = port_data[port]["READ"] + port_data[port]["WRITE"]
    c_stats = calculate_percentiles(p_combined)
    
    print(f" Port {port:<9} | READ   | {len(port_data[port]['READ']):<6} | {r_stats['min']:<6.1f} | {r_stats['avg']:<6.1f} | {r_stats['p50']:<6.1f} | {r_stats['p90']:<6.1f} | {r_stats['p95']:<6.1f} | {r_stats['p99']:<6.1f} | {r_stats['max']:<6.1f}")
    print(f" Port {port:<9} | WRITE  | {len(port_data[port]['WRITE']):<6} | {w_stats['min']:<6.1f} | {w_stats['avg']:<6.1f} | {w_stats['p50']:<6.1f} | {w_stats['p90']:<6.1f} | {w_stats['p95']:<6.1f} | {w_stats['p99']:<6.1f} | {w_stats['max']:<6.1f}")
    print(f" Port {port:<9} | SUBTOT | {len(p_combined):<6} | {c_stats['min']:<6.1f} | {c_stats['avg']:<6.1f} | {c_stats['p50']:<6.1f} | {c_stats['p90']:<6.1f} | {c_stats['p95']:<6.1f} | {c_stats['p99']:<6.1f} | {c_stats['max']:<6.1f}")
    print("-" * 86)

print(f" {'ALL COMBINED':<14} | TOTAL  | {total_reqs:<6} | {all_stats['min']:<6.1f} | {all_stats['avg']:<6.1f} | {all_stats['p50']:<6.1f} | {all_stats['p90']:<6.1f} | {all_stats['p95']:<6.1f} | {all_stats['p99']:<6.1f} | {all_stats['max']:<6.1f}")
print("=" * 86)
print("                     TARGET VM RESOURCE UTILIZATION                    ")
print("=" * 86)
if cpu_vals:
    print(f" CPU Utilization (%)    : Min: {cpu_min:.1f}%  |  Average: {cpu_avg:.1f}%  |  Peak: {cpu_max:.1f}%")
    ram_pct = (ram_avg / ram_total * 100) if ram_total else 0
    print(f" RAM Usage (MB)         : Min: {ram_min:.0f}MB |  Average: {ram_avg:.0f}MB ({ram_pct:.1f}%) |  Peak: {ram_max:.0f}MB (of {ram_total:.0f}MB)")
else:
    print(" (No VM metrics captured - check SSH access)")
print("=" * 86)
EOF
