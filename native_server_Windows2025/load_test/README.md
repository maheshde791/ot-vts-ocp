# OpenText VTS Multi-Instance Load Testing & Benchmark Suite (Windows Server 2025)

A high-concurrency performance testing and benchmarking harness for **OpenText Virtual Table Server (VTS) 26.1** running on **Windows Server 2025 Standard (Desktop Experience)** with native HTTPS / TLS 1.2/1.3.

---

## 1. Architecture Overview

```text
                               ┌── Instance 8888 (10 Readers + 10 Writers) ──┐
                               │                                             │
 [ Master Load Orchestrator ] ─┼── Instance 2000 (10 Readers + 10 Writers) ──┼──> [ Windows Server 2025 VM ]
  (60 Parallel Worker Threads) │                                             │    (Direct Port HTTPS / TLS 1.3)
                               └── Instance 2001 (10 Readers + 10 Writers) ──┘    (Live CPU % & RAM MB Monitored)
                                                     │
                                                     ▼
                                 [ Executive Benchmark Report (.txt) ]
```

### Suite Components

This load testing suite offers **dual execution capability**:
* **Native Windows PowerShell (`.ps1`):** Run natively inside the Windows Server 2025 VM or on any Windows test client.
* **Cross-Platform Shell (`.sh`):** Run remotely from the Linux host or CI/CD runner against the Windows VM.

| PowerShell Component | Shell Component | Type | Description |
| :--- | :--- | :--- | :--- |
| **`master_load_tester.ps1`** | **`master_load_tester.sh`** | Orchestrator | Pre-flight validation, launches background resource monitor, spawns parallel worker pools, and aggregates final percentiles. |
| **`worker_read.ps1`** | **`worker_read.sh`** | Worker | Executes concurrent read requests (`POST /client_api/get`). |
| **`worker_write.ps1`** | **`worker_write.sh`** | Worker | Executes concurrent cell updates (`POST /client_api/update`) using Basic Auth. |
| **`monitor_vm.ps1`** | **`monitor_vm.sh`** | Monitor | Samples real-time CPU % and RAM MB metrics every 1 second. |
| **`calculate_stats.ps1`** | **`calculate_stats.sh`** | Analytics | Computes response time percentiles (Min, Avg, p50, p90, p95, p99, Max), RPS throughput, and resource utilization. |
| **`results/`** | **`results/`** | Storage | Automatically persists formatted benchmark reports (`.txt`). Intermediate CSVs are cleaned up upon completion. |

---

## 2. Concurrency and Request Calculations

The suite exercises **all active VTS instances simultaneously** across their dedicated native HTTPS ports:

### Formulas
$$\text{Total Parallel Threads} = (\text{Read Workers} + \text{Write Workers}) \times \text{Number of Instances}$$
$$\text{Total Requests} = \text{Total Parallel Threads} \times \text{Requests per Thread}$$

### Default Benchmark Configuration (60 Parallel Threads, 3,000 Requests)

| Instance Port | Operation | Parallel Threads | Requests / Thread | Total Requests |
| :---: | :---: | :---: | :---: | :---: |
| **Port 8888** | READ | 10 | 50 | 500 |
| **Port 8888** | WRITE | 10 | 50 | 500 |
| **Port 2000** | READ | 10 | 50 | 500 |
| **Port 2000** | WRITE | 10 | 50 | 500 |
| **Port 2001** | READ | 10 | 50 | 500 |
| **Port 2001** | WRITE | 10 | 50 | 500 |
| **TOTALS** | **Reads + Writes** | **60 THREADS** | **50 reqs / thread** | **3,000 REQUESTS** |

- **Total Reads:** $30 \text{ Read Threads} \times 50 = \mathbf{1,500 \text{ Reads}}$
- **Total Writes:** $30 \text{ Write Threads} \times 50 = \mathbf{1,500 \text{ Writes}}$
- **Grand Total:** $1,500 + 1,500 = \mathbf{3,000 \text{ Requests}}$ running concurrently.

---

## 3. How to Run the Load Test

### Option A: From Windows PowerShell (Directly inside VM or Windows client)

Open **PowerShell as Administrator** in the `load_test` directory:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Standard Benchmark (60 threads, 3,000 requests)
.\master_load_tester.ps1 -Auth "maheshd:*****"

# Light Benchmark (30 threads, 600 requests)
.\master_load_tester.ps1 -ReadWorkers 5 -WriteWorkers 5 -ReadReqsPerWorker 20 -WriteReqsPerWorker 20 -Auth "maheshd:*****"

# Heavy Stress Test (150 threads, 15,000 requests)
.\master_load_tester.ps1 -ReadWorkers 25 -WriteWorkers 25 -ReadReqsPerWorker 100 -WriteReqsPerWorker 100 -Auth "maheshd:*****"
```

---

### Option B: From Linux Host / Workstation (Over HTTPS Network)

Navigate to the `load_test` folder:

```bash
cd /home/mahesh/vts_ocp/native_server_Windows2025/load_test

# Standard Benchmark (60 threads, 3,000 requests)
./master_load_tester.sh --auth "maheshd:*****"

# Light Benchmark (30 threads, 600 requests)
./master_load_tester.sh \
  --read-workers 5 \
  --read-reqs 20 \
  --write-workers 5 \
  --write-reqs 20 \
  --auth "maheshd:*****"

# Heavy Stress Test (150 threads, 15,000 requests)
./master_load_tester.sh \
  --read-workers 25 \
  --read-reqs 100 \
  --write-workers 25 \
  --write-reqs 100 \
  --auth "maheshd:*****"
```

---

## 4. Benchmark Report Output Example

Upon completion of the run, the suite produces an executive benchmark summary and saves it to `results/`:

```text
======================================================================================
             VTS MULTI-INSTANCE LOAD TEST & BENCHMARK REPORT (PARALLEL)         
======================================================================================
 Test Duration          : 14.82 seconds
 Target Instances       : Port 2000, Port 2001, Port 8888
 Total Requests Run     : 3000 (1500 Reads, 1500 Writes)
 Successful (HTTP 200)  : 3000 (100.0%)
 Failed / Errors        : 0 (0.0%)
 Overall Throughput     : 202.43 Requests/Second (RPS)
======================================================================================
 INSTANCE       | OP     | COUNT  | MIN    | AVG    | p50    | p90    | p95    | p99    | MAX   
--------------------------------------------------------------------------------------
 Port 2000      | READ   | 500    | 5.2    | 12.4   | 10.8   | 18.2   | 22.1   | 28.4   | 34.6  
 Port 2000      | WRITE  | 500    | 6.1    | 14.1   | 12.3   | 20.4   | 24.5   | 31.0   | 38.2  
 Port 2000      | SUBTOT | 1000   | 5.2    | 13.3   | 11.5   | 19.3   | 23.3   | 29.8   | 38.2  
--------------------------------------------------------------------------------------
 Port 2001      | READ   | 500    | 5.1    | 12.1   | 10.5   | 17.9   | 21.8   | 27.9   | 33.8  
 Port 2001      | WRITE  | 500    | 5.9    | 13.8   | 12.0   | 19.8   | 23.9   | 30.4   | 37.5  
 Port 2001      | SUBTOT | 1000   | 5.1    | 13.0   | 11.2   | 18.9   | 22.8   | 29.1   | 37.5  
--------------------------------------------------------------------------------------
 Port 8888      | READ   | 500    | 5.0    | 11.8   | 10.2   | 17.5   | 21.2   | 27.2   | 32.9  
 Port 8888      | WRITE  | 500    | 5.8    | 13.5   | 11.7   | 19.4   | 23.4   | 29.9   | 36.8  
 Port 8888      | SUBTOT | 1000   | 5.0    | 12.7   | 10.9   | 18.5   | 22.3   | 28.5   | 36.8  
--------------------------------------------------------------------------------------
 ALL COMBINED   | TOTAL  | 3000   | 5.0    | 13.0   | 11.2   | 18.9   | 22.8   | 29.1   | 38.2  
======================================================================================
                     TARGET VM RESOURCE UTILIZATION                    
======================================================================================
 CPU Utilization (%)    : Min: 3.2%  |  Average: 18.5%  |  Peak: 34.2%
 RAM Usage (MB)         : Min: 4210MB |  Average: 4520MB (27.6%) |  Peak: 4850MB (of 16384MB)
======================================================================================
```

