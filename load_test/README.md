# OpenText VTS Multi-Instance Load Testing & Benchmark Suite

A modular, high-concurrency shell-based performance testing and benchmarking harness for **OpenText Virtual Table Server (VTS)** deployed on **RHEL 9 64-bit VM** behind an **NGINX Reverse Proxy** (HTTPS / TLS 1.2/1.3).

---

## 1. Architecture Overview

```text
                               ┌── Instance 8888 (10 Readers + 10 Writers) ──┐
                               │                                             │
 [ Master Load Orchestrator ] ─┼── Instance 2000 (10 Readers + 10 Writers) ──┼──> [ RHEL 9 VM: All 3 Tested in Parallel ]
  (60 Parallel Worker Threads) │                                             │    (Live CPU % & RAM MB Monitored via SSH)
                               └── Instance 2001 (10 Readers + 10 Writers) ──┘
                                                     │
                                                     ▼
                                 [ Executive Benchmark Report (.txt) ]
```

### Suite Components

| File | Type | Purpose |
| :--- | :--- | :--- |
| **`master_load_tester.sh`** | Orchestrator | Validates endpoints, manages background monitor, spawns parallel worker pools, and triggers analytics. |
| **`worker_read.sh`** | Worker Process | Executes concurrent non-destructive read requests (`POST /client_api/get`). |
| **`worker_write.sh`** | Worker Process | Executes concurrent cell updates/adds (`POST /client_api/update`). |
| **`monitor_vm.sh`** | Background Daemon | Streams real-time CPU % and RAM MB metrics from the target VM every 1 second over SSH. |
| **`calculate_stats.sh`** | Analytics Engine | Computes response time percentiles (Min, Avg, p50, p90, p95, p99, Max), RPS, and VM resource statistics. |
| **`results/`** | Report Directory | Stores clean, dated benchmark reports (`.txt`). Intermediate CSVs are automatically purged. |

---

## 2. How Concurrency and Requests Are Calculated

The suite tests **multiple VTS instances simultaneously** using native Linux background processes (`&`):

### Formulas
$$\text{Total Parallel Threads} = (\text{Read Workers} + \text{Write Workers}) \times \text{Number of Instances}$$
$$\text{Total Requests} = \text{Total Parallel Threads} \times \text{Requests per Thread}$$

### Default Configuration Example (60 Threads, 3,000 Requests)

| Instance Port | Operation | Parallel Threads | Requests / Thread | Total Requests |
| :---: | :---: | :---: | :---: | :---: |
| **Port 8888** | READ | 10 | 50 | 500 |
| **Port 8888** | WRITE | 10 | 50 | 500 |
| **Port 2000** | READ | 10 | 50 | 500 |
| **Port 2000** | WRITE | 10 | 50 | 500 |
| **Port 2001** | READ | 10 | 50 | 500 |
| **Port 2001** | WRITE | 10 | 50 | 500 |
| **TOTALS** | **Reads + Writes** | **60 THREADS** | **50 reqs / thread** | **3,000 REQUESTS** |

- **Total Reads**: $30 \text{ Read Threads} \times 50 = \mathbf{1,500 \text{ Reads}}$
- **Total Writes**: $30 \text{ Write Threads} \times 50 = \mathbf{1,500 \text{ Writes}}$
- **Grand Total**: $1,500 + 1,500 = \mathbf{3,000 \text{ Requests}}$ running concurrently.

---

## 3. Prerequisites

### 1. Hostname Resolution
Ensure `vts-server.local` points to the VM IP in `/etc/hosts` on your client machine:
```bash
echo "192.168.122.245 vts-server.local vts-server" | sudo tee -a /etc/hosts
```

### 2. Passwordless SSH for Live CPU/RAM Monitoring
To allow `monitor_vm.sh` to sample CPU & RAM in the background without password prompts, copy your SSH public key to the VM once:
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 2>/dev/null || true
ssh-copy-id vtsadmin@192.168.122.245
```

---

## 4. How to Use the Scripts

### Scenario A: Standard Multi-Instance Benchmark (Default: 60 Threads, 3,000 Requests)
```bash
cd /home/mahesh/vts_ocp/load_test
./master_load_tester.sh --auth "maheshd:pass"
```

### Scenario B: Light Benchmark (30 Threads, 600 Requests)
Simulates 5 readers + 5 writers per instance (10 × 3 = 30 threads), running 20 requests each:
```bash
./master_load_tester.sh \
  --read-workers 5 \
  --read-reqs 20 \
  --write-workers 5 \
  --write-reqs 20 \
  --auth "maheshd:pass"
```

### Scenario C: Heavy Stress Test (150 Threads, 15,000 Requests)
Simulates 25 readers + 25 writers per instance (50 × 3 = 150 threads), running 100 requests each:
```bash
./master_load_tester.sh \
  --read-workers 25 \
  --read-reqs 100 \
  --write-workers 25 \
  --write-reqs 100 \
  --auth "maheshd:pass"
```

### Scenario D: Single Instance Targeted Test (e.g., Only Port 2000)
```bash
./master_load_tester.sh \
  --ports "2000" \
  --read-workers 20 \
  --write-workers 20 \
  --auth "maheshd:pass"
```

---

## 5. CLI Options Reference

| Option | Default | Description |
| :--- | :--- | :--- |
| `--url <url>` | `https://vts-server.local` | VTS HTTPS endpoint (via NGINX reverse proxy). |
| `--ports "p1 p2..."`| `"8888 2000 2001"` | Space-delimited list of target instance ports. |
| `--read-workers <n>` | `10` | Number of concurrent read threads **per instance**. |
| `--read-reqs <n>` | `50` | Number of read requests executed by each read thread. |
| `--write-workers <n>`| `10` | Number of concurrent write threads **per instance**. |
| `--write-reqs <n>` | `50` | Number of write requests executed by each write thread. |
| `--vm-host <host>` | `192.168.122.245` | Target VM hostname/IP for CPU & RAM monitoring. |
| `--ssh-user <user>` | `vtsadmin` | SSH username for VM resource monitoring. |
| `--auth <user:pass>` | *(empty)* | HTTP Basic Auth credentials if VTS authentication is enabled. |
| `--help` | - | Display help menu. |

---

## 6. Understanding the Metrics & Terminology

| Metric | Definition | Importance in Performance Testing |
| :--- | :--- | :--- |
| **COUNT** | Total requests executed. | Sample size for the test. |
| **MIN** | Fastest response recorded (ms). | Theoretical baseline network/processing floor. |
| **AVG** | Mathematical mean response time (ms). | General indicator; can be skewed by outliers. |
| **p50 (Median)** | 50% of requests were faster than this value. | Typical user experience. |
| **p90** | 90% of requests finished within this time. | Identifies tail degradation. |
| **p95** | 95% of requests finished within this time. | **Enterprise SLA Target**: Standard industry benchmark for SLA compliance. |
| **p99** | 99% of requests finished within this time. | Identifies worst 1% edge-case latencies under peak load. |
| **MAX** | The single slowest request in the run (ms). | Worst-case transaction. |
| **RPS** | Requests Per Second (Throughput). | System processing capacity ($Total\ Requests \div Duration$). |
| **SUBTOT** | Subtotal for a specific instance. | Combines READ and WRITE statistics for that instance port. |
| **CPU %** | Target VM CPU utilization. | Min, Average, and Peak processor load during test. |
| **RAM (MB)** | Target VM memory consumption. | Min, Average, and Peak memory utilization of the VM. |

---

## 7. Report Output & File Naming

- **No CSV files are saved in `results/`**: All in-flight CSV logs are handled in `/tmp` and automatically purged when the test concludes.
- The report is printed live on the console and saved to:
  ```text
  results/<userNumber>users_<requests>requests_<timestampfrom>-<timestampto>.txt
  ```
  *Example:* `results/60users_3000requests_20261029_164500-20261029_164510.txt`

### Sample Report

```text
======================================================================================
             VTS MULTI-INSTANCE LOAD TEST & BENCHMARK REPORT (PARALLEL)         
======================================================================================
 Test Duration          : 9.56 seconds
 Target Instances       : Port 2000, Port 2001, Port 8888
 Total Requests Run     : 3000 (1500 Reads, 1500 Writes)
 Successful (HTTP 200)  : 3000 (100.0%)
 Failed / Errors        : 0 (0.0%)
 Overall Throughput     : 313.81 Requests/Second (RPS)
======================================================================================
 INSTANCE       | OP     | COUNT  | MIN    | AVG    | p50    | p90    | p95    | p99    | MAX   
--------------------------------------------------------------------------------------
 Port 2000      | READ   | 500    | 7.5    | 40.4   | 39.1   | 56.1   | 60.4   | 73.5   | 85.2  
 Port 2000      | WRITE  | 500    | 9.8    | 40.4   | 39.6   | 55.5   | 61.3   | 73.5   | 81.4  
 Port 2000      | SUBTOT | 1000   | 7.5    | 40.4   | 39.4   | 55.8   | 61.1   | 73.5   | 85.2  
--------------------------------------------------------------------------------------
 Port 2001      | READ   | 500    | 7.9    | 42.0   | 41.2   | 57.9   | 63.6   | 74.7   | 79.5  
 Port 2001      | WRITE  | 500    | 17.4   | 41.2   | 40.4   | 57.3   | 62.1   | 73.8   | 78.1  
 Port 2001      | SUBTOT | 1000   | 7.9    | 41.6   | 40.9   | 57.6   | 62.5   | 74.0   | 79.5  
--------------------------------------------------------------------------------------
 Port 8888      | READ   | 500    | 12.2   | 40.8   | 40.3   | 56.2   | 60.8   | 72.6   | 97.3  
 Port 8888      | WRITE  | 500    | 9.7    | 40.4   | 39.8   | 56.0   | 59.7   | 69.5   | 84.3  
 Port 8888      | SUBTOT | 1000   | 9.7    | 40.6   | 40.1   | 56.0   | 60.6   | 72.0   | 97.3  
--------------------------------------------------------------------------------------
 ALL COMBINED   | TOTAL  | 3000   | 7.5    | 40.9   | 40.0   | 56.4   | 61.5   | 73.8   | 97.3  
======================================================================================
                     TARGET VM RESOURCE UTILIZATION                    
======================================================================================
 CPU Utilization (%)    : Min: 1.5%  |  Average: 1.7%  |  Peak: 2.1%
 RAM Usage (MB)         : Min: 1410MB |  Average: 1411MB (9.0%) |  Peak: 1411MB (of 15731MB)
======================================================================================
```

