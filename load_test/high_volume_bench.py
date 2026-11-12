#!/usr/bin/env python3
"""
High-volume persistent-connection (Keep-Alive) benchmark driver for RHEL 9 VTS + NGINX.
Supports multi-process + multi-thread sharding to drive 6,500+ concurrent virtual users
across all 20 VTS instances without client-side Python GIL or curl subprocess bottlenecks.
"""

import argparse
import base64
import concurrent.futures
import http.client
import json
import os
import random
import ssl
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from urllib.parse import urlparse


def run_worker(task_spec):
    """Execute READ or WRITE workload for one virtual user using persistent HTTPS keep-alive."""
    worker_type, port, worker_id, num_requests, host, netloc_port, max_index, auth_header, start_delay = task_spec
    if start_delay > 0:
        time.sleep(start_delay)

    ssl_ctx = ssl._create_unverified_context()
    conn = None
    results = []

    headers = {"Content-Type": "application/json", "Connection": "keep-alive"}
    if auth_header:
        headers["Authorization"] = auth_header

    path = f"/?portnumber={port}/client_api/{'get' if worker_type == 'READ' else 'update'}"

    for req_num in range(1, num_requests + 1):
        row_idx = random.randint(1, max_index)
        if worker_type == "READ":
            body = json.dumps({"colName": "Customer_ID", "index": row_idx})
        else:
            val = f"PERF_P{port}_W{worker_id}_R{req_num}"
            body = json.dumps({"index": row_idx, "column": "Customer_ID", "value": val})

        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        t0 = time.perf_counter()
        status = "000"

        for attempt in range(2):
            try:
                if conn is None:
                    conn = http.client.HTTPSConnection(host, netloc_port, timeout=30, context=ssl_ctx)
                conn.request("POST", path, body=body, headers=headers)
                resp = conn.getresponse()
                resp.read()
                status = str(resp.status)
                break
            except Exception:
                if conn is not None:
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = None
                if attempt == 1:
                    status = "000"

        lat_ms = (time.perf_counter() - t0) * 1000.0
        results.append(f"{ts},{worker_type},{port},{worker_id},{req_num},{status},{lat_ms:.2f}\n")

    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
    return results


def run_shard(shard_tasks):
    """Run a shard of virtual user threads inside a dedicated OS process."""
    if not shard_tasks:
        return []
    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(shard_tasks)) as pool:
        for res in pool.map(run_worker, shard_tasks):
            out.extend(res)
    return out


def preflight_check(host, netloc_port, ports, write_workers, auth_header, allow_unauth):
    """Verify all target ports respond HTTP 200 and validate write Basic Auth before scaling up."""
    ssl_ctx = ssl._create_unverified_context()
    headers = {"Content-Type": "application/json", "Connection": "close"}
    if auth_header:
        headers["Authorization"] = auth_header

    print("[1/4] Pre-flight check across target instances...")
    for p in ports:
        conn = http.client.HTTPSConnection(host, netloc_port, timeout=10, context=ssl_ctx)
        conn.request("POST", f"/?portnumber={p}/client_api/getAllColumnsSize", body="{}", headers=headers)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        if resp.status != 200:
            raise RuntimeError(f"Pre-flight failed on port {p}: HTTP {resp.status}")

    if write_workers > 0 and not allow_unauth:
        conn = http.client.HTTPSConnection(host, netloc_port, timeout=10, context=ssl_ctx)
        test_body = json.dumps({"index": 1, "column": "Customer_ID", "value": "PREFLIGHT_WRITE_OK"})
        conn.request("POST", f"/?portnumber={ports[0]}/client_api/update", body=test_body, headers=headers)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        if resp.status == 400 or resp.status == 401 or resp.status == 403:
            raise RuntimeError(
                f"Write pre-flight failed on port {ports[0]} with HTTP {resp.status}. "
                "VTS write endpoints (/client_api/update) require admin credentials via --auth 'user:pass'."
            )
    print(f"  -> All {len(ports)} instances healthy and authorized (HTTP 200).")


def main():
    parser = argparse.ArgumentParser(description="High-volume keep-alive VTS benchmark driver")
    parser.add_argument("--url", default="https://vts-server.local", help="Target NGINX VTS URL")
    parser.add_argument("--ports", default="8888 2000 2001", help="Space-separated instance ports")
    parser.add_argument("--all-20", action="store_true", help="Target all 20 instances (8888 + 2000..2018)")
    parser.add_argument("--read-workers", type=int, default=100, help="Read threads per instance")
    parser.add_argument("--read-reqs", type=int, default=50, help="Requests per read thread")
    parser.add_argument("--write-workers", type=int, default=100, help="Write threads per instance")
    parser.add_argument("--write-reqs", type=int, default=50, help="Requests per write thread")
    parser.add_argument("--max-index", type=int, default=4000, help="Max row index (default: 4000)")
    parser.add_argument("--processes", type=int, default=0, help="Worker processes for client sharding (0=auto)")
    parser.add_argument("--ramp-up", type=float, default=0.0, help="Ramp-up window in seconds across all VUsers")
    parser.add_argument("--vm-host", default="192.168.122.245", help="VM IP for resource monitor")
    parser.add_argument("--ssh-user", default="vtsadmin", help="SSH user for resource monitor")
    parser.add_argument("--auth", default="", help="Basic Auth user:pass (required for write/update)")
    parser.add_argument("--allow-unauth", action="store_true", help="Skip pre-flight write auth validation")
    args = parser.parse_args()

    parsed = urlparse(args.url)
    host = parsed.hostname or "vts-server.local"
    netloc_port = parsed.port or 443
    ports = ["8888"] + [str(p) for p in range(2000, 2019)] if args.all_20 else args.ports.split()

    auth_header = ""
    if args.auth:
        token = base64.b64encode(args.auth.encode("utf-8")).decode("ascii")
        auth_header = f"Basic {token}"

    script_dir = os.path.dirname(os.path.abspath(__file__))
    results_dir = os.path.join(script_dir, "results")
    os.makedirs(results_dir, exist_ok=True)

    total_workers = (args.read_workers + args.write_workers) * len(ports)
    total_reqs = ((args.read_workers * args.read_reqs) + (args.write_workers * args.write_reqs)) * len(ports)
    num_procs = args.processes if args.processes > 0 else (min(16, os.cpu_count() or 8) if total_workers >= 600 else 1)
    num_procs = max(1, min(num_procs, total_workers))

    print("=" * 80)
    print("  HIGH-VOLUME PERSISTENT KEEP-ALIVE VTS BENCHMARK (RHEL 9 + NGINX)")
    print("=" * 80)
    print(f" Target Endpoint     : {args.url} ({host}:{netloc_port})")
    print(f" Active Instances    : {len(ports)} instances ({ports[0]} .. {ports[-1]})")
    print(f" Concurrency         : {total_workers} persistent VUsers ({args.read_workers}R + {args.write_workers}W / instance)")
    print(f" Client Sharding     : {num_procs} OS processes x ~{total_workers // num_procs} keep-alive threads")
    print(f" Ramp-Up Window      : {args.ramp_up:.1f}s | Max Row Index: {args.max_index}")
    print(f" Total Requests      : {total_reqs}")
    print("-" * 80)

    try:
        preflight_check(host, netloc_port, ports, args.write_workers, auth_header, args.allow_unauth)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    # Build shuffled task list so ramp-up distributes load evenly across all instances & R/W
    all_tasks = []
    for p in ports:
        for w in range(1, args.read_workers + 1):
            all_tasks.append(("READ", p, w, args.read_reqs, host, netloc_port, args.max_index, auth_header, 0.0))
        for w in range(1, args.write_workers + 1):
            all_tasks.append(("WRITE", p, w, args.write_reqs, host, netloc_port, args.max_index, auth_header, 0.0))

    random.shuffle(all_tasks)
    if args.ramp_up > 0 and len(all_tasks) > 1:
        all_tasks = [
            (*t[:-1], (idx / (len(all_tasks) - 1)) * args.ramp_up)
            for idx, t in enumerate(all_tasks)
        ]

    shards = [all_tasks[i::num_procs] for i in range(num_procs)]

    with tempfile.TemporaryDirectory(prefix="vts_hv_") as tmp_dir:
        raw_csv = os.path.join(tmp_dir, "all_requests.csv")
        vm_csv = os.path.join(tmp_dir, "vm_metrics.csv")

        print(f"[2/4] Starting VM resource monitor ({args.ssh_user}@{args.vm_host})...")
        mon_script = os.path.join(script_dir, "monitor_vm.sh")
        mon_proc = subprocess.Popen(
            [mon_script, vm_csv, args.vm_host, args.ssh_user, "1"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        time_from = datetime.now().strftime("%Y%m%d_%H%M%S")
        time.sleep(2)
        print(f"[3/4] Running {total_workers} concurrent VUsers across {len(ports)} instances...")
        t_start = time.perf_counter()

        with open(raw_csv, "w", encoding="utf-8") as f:
            if num_procs == 1:
                f.writelines(run_shard(shards[0]))
            else:
                with concurrent.futures.ProcessPoolExecutor(max_workers=num_procs) as pool:
                    for lines in pool.map(run_shard, shards):
                        f.writelines(lines)

        duration = time.perf_counter() - t_start
        time_to = datetime.now().strftime("%Y%m%d_%H%M%S")

        mon_proc.terminate()
        try:
            mon_proc.wait(timeout=3)
        except Exception:
            mon_proc.kill()

        print(f"[4/4] Execution completed in {duration:.2f}s. Aggregating report...")
        report_file = os.path.join(results_dir, f"{total_workers}users_{total_reqs}requests_keepalive_{time_from}-{time_to}.txt")
        stats_script = os.path.join(script_dir, "calculate_stats.sh")
        proc = subprocess.run([stats_script, raw_csv, vm_csv, f"{duration:.2f}"], capture_output=True, text=True)
        print(proc.stdout)
        with open(report_file, "w", encoding="utf-8") as rf:
            rf.write(proc.stdout)
        print(f"Report saved to: {report_file}")


if __name__ == "__main__":
    main()
