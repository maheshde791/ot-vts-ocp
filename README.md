# OpenText Virtual Table Server (VTS) Enterprise POC Guide

Comprehensive technical documentation and implementation reference for deploying **OpenText Virtual Table Server (VTS 26.1 / 26.3)** natively on **Red Hat Enterprise Linux 9 (64-bit)** with multi-instance support, Basic Authentication, NGINX SSL/TLS Reverse Proxy, automated port forwarding, and high-concurrency load validation.

---

## Table of Contents
1. [Target VM Environment Specifications](#1-target-vm-environment-specifications)
2. [Operating System & Network Configuration](#2-operating-system--network-configuration)
3. [VTS Installation & Service Setup](#3-vts-installation--service-setup)
4. [Multi-Instance Architecture](#4-multi-instance-architecture)
5. [Basic Authentication, User Creation & Role Assignment](#5-basic-authentication-user-creation--role-assignment)
6. [SSL/TLS Certificate Generation](#6-ssltls-certificate-generation)
7. [NGINX Reverse Proxy Installation & Port Forwarding](#7-nginx-reverse-proxy-installation--port-forwarding)
8. [Firewall Hardening (`firewalld`)](#8-firewall-hardening-firewalld)
9. [LoadRunner VuGen & LRE Integration Guide](#9-loadrunner-vugen--lre-integration-guide)
10. [High-Concurrency Load Testing & Benchmarking](#10-high-concurrency-load-testing--benchmarking)
11. [Configuration Files Repository Reference](#11-configuration-files-repository-reference)

---

## 1. Target VM Environment Specifications

The POC was executed and benchmarked on a dedicated RHEL 9 VM with the following hardware and software specifications:

| Component | Specification |
| :--- | :--- |
| **Operating System** | Red Hat Enterprise Linux release 9.8 (Plow) x86_64 |
| **Linux Kernel** | `5.14.0-687.5.3.el9_8.x86_64` |
| **vCPU Total** | 8 vCPUs (AMD Ryzen 7 PRO 5850U with Radeon Graphics) |
| **Memory (RAM)** | 16 GB Total (15 GiB physical, ~1.4 GiB baseline used) |
| **Swap Space** | 8.0 GB (7.9 GiB) |
| **Static IPv4** | `192.168.122.245/24` (Gateway: `192.168.122.1`, DNS: `192.168.122.1`) |
| **Hostname** | `vts-server.local` (Alias: `vts-server`) |
| **Administrative User**| `vtsadmin` with full passwordless local `sudo` privileges |
| **Installation Path** | `/opt/OT/OT_VTS/` |

---

## 2. Operating System & Network Configuration

### 2.1 User Creation & Sudo Access
```bash
# 1. Create dedicated vtsadmin user
sudo useradd -m -s /bin/bash vtsadmin
echo "vtsadmin:<seturpass>" | sudo chpasswd

# 2. Grant local sudo privileges
echo "vtsadmin ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/vtsadmin
sudo chmod 440 /etc/sudoers.d/vtsadmin
```

### 2.2 Static IPv4 Configuration (NetworkManager)
Ensure the VM maintains a permanent static IP across all reboots:
```bash
# Set static IP on interface enp1s0
sudo nmcli connection modify enp1s0 \
  ipv4.method manual \
  ipv4.addresses 192.168.122.245/24 \
  ipv4.gateway 192.168.122.1 \
  ipv4.dns 192.168.122.1

# Apply connection
sudo nmcli connection up enp1s0
```

### 2.3 Hostname Configuration
```bash
# Set system hostname
sudo hostnamectl set-hostname vts-server.local

# Add to /etc/hosts on VM
echo "192.168.122.245 vts-server.local vts-server" | sudo tee -a /etc/hosts
```

---

## 3. VTS Installation & Service Setup

1. **Download & Extraction**:
   Downloaded OpenText VTS 26.1 installation zip file:
   ```bash
   unzip VTS_26.1_Linux.zip
   tar -xvf VTS_Linux.tar.gz
   ```
2. **Execute Installation**:
   Executed the native setup binary:
   ```bash
   sudo chmod +x inst64.bin
   sudo ./inst64.bin
   ```
   *Accepted all default installation options. VTS installed automatically into `/opt/OT/OT_VTS`.*

3. **Verify Version**:
   ```bash
   /opt/OT/OT_VTS/show_vts_version
   ```

4. **Service Control**:
   ```bash
   # Start / Stop / Restart / Status
   sudo /opt/OT/OT_VTS/vts.sh start
   sudo /opt/OT/OT_VTS/vts.sh stop
   sudo /opt/OT/OT_VTS/vts.sh restart
   sudo /opt/OT/OT_VTS/vts.sh status
   ```

---

## 4. Multi-Instance Architecture

VTS was configured to run multiple independent database instances to isolate test data across different project teams:

```text
[ VTS Daemon (apiserver) ]
     ├── Admin UI & Reverse Proxy: Port 4000
     ├── Instance 1 (Default)    : Port 8888 (500 Customer records)
     ├── Instance 2 (Team_1)     : Port 2000 (500 Customer records)
     └── Instance 3 (Team_2)     : Port 2001 (500 Customer records)
```

Each instance holds dedicated tabular datasets with columns:
- `Customer_ID`
- `Customer_Name`
- `Email`

---

## 5. Basic Authentication, User Creation & Role Assignment

Authentication is enforced via the VTS configuration file: `/opt/OT/OT_VTS/web/configure.json`.

### 5.1 Roles Supported by VTS
- **`administrator`**: Full administrative access. Can create, import, export, truncate, or delete tables, and modify server configuration.
- **`user`**: Read/Write operator access. Can query, view, update, and append data cells, but **cannot** delete tables or change server settings.

### 5.2 Enterprise API Authentication Setting (`requireBasicAuthForAPI: false`)
> [!IMPORTANT]
> By keeping `"requireBasicAuthForAPI": false`:
> - **The Web Admin Console strictly requires a login (username & password)** to protect data from unauthorized browser access.
> - **LoadRunner VuGen test scripts can connect anonymously** via standard `lrvtc_connect("vts-server.local", 2000, VTOPT_KEEP_ALIVE)`. This eliminates having to hardcode passwords across hundreds of automated test scripts.

### 5.3 Active `configure.json` Configuration File

```json
{  
  "dbPath": "/var/lib/OT/OT_VTS/db/data",  
  "defaultDbName" : "Default",
  "adminPort": 4000,
  "defaultApiPort": 8888,
  "defaultStart": false,
  "enableDiag": false,
  "autoRefreshGrid": true,
  "maxInstancesAllowed": 50,
  "autoCreateIndexedColumn": true,
  "normalizeCSV": false,
  "admin": {
    "authentication": "Basic",
    "users":
    [
      {"user": "johns", "password": "<seturpass>", "display": "John Smith"},
      {"user": "maheshd", "password": "<seturpass>", "display": "Mahesh Deore"}
    ],
        
    "role":{
      "administrator":["maheshd"],
      "user":["johns"]
    },
	
    "requireBasicAuthForAPI": false,
	
    "domain": "",
    "domaincontroller": "",
    "ldapsCert": "",
    "ldapsCA": "",
    "useSSL": false,
	
    "certificate": "vts.crt",
    "privateKey": "vts.key",
    "passphrase": "",
    "ca": "vts.crt",
    "minVersion": "TLSv1.2",
    "maxVersion": "TLSv1.3",
    "ciphers": "ETCD_CIPHER_SUITES=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "requestClientCert": false
  },
  
  "languages": [
    { "en": "en-us" },
    { "zh-cn": ["zh", "zh-sg"] },
    { "ja": "ja" },
    { "ko": ["zh", "zh-sg"] },
    { "it": "zh-hk"},
    { "es": "zh-hk"},
    { "fr": "fr-fr"},
    { "ru": "ru"},
    "de"
  ],
  "defaultLanguage":"en",
  "dbInfo": {
    "connPool": {
      "maxIdle": 3500,
      "maxActive": 3500
    },
    "dbServerPort": { 
      "start": 6000,
      "end": 7000
    },
    "dbCheck": {
      "waitingTime": 1,
      "retryTimes": 3600
    }
  },
  "logger":{
    "level":"error", 
    "transports":{
      "file":{
        "type": "File",
        "path": "/tmp/VTS"
      },
      "console":{
        "type": "Console"
      }
    }
  }
}
```

---

## 6. SSL/TLS Certificate Generation

### 6.1 Local POC Self-Signed Certificate with SAN
Generated a 2048-bit RSA key and Subject Alternative Name (SAN) certificate to support modern TLS validation:

```bash
# 1. Create directories
sudo mkdir -p /etc/pki/tls/certs /etc/pki/tls/private

# 2. Generate Key & Cert with SAN extension
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/pki/tls/private/vts.key \
  -out /etc/pki/tls/certs/vts.crt \
  -subj "/C=US/ST=State/L=City/O=Enterprise/OU=Performance/CN=vts-server.local" \
  -addext "subjectAltName=DNS:vts-server.local,DNS:vts-server,IP:192.168.122.245,DNS:localhost"

# 3. Permissions
sudo chmod 600 /etc/pki/tls/private/vts.key
sudo chmod 644 /etc/pki/tls/certs/vts.crt
```

### 6.2 Enterprise Certificate Authority (Production Guidelines)
When submitting a certificate request in your corporate PKI portal:
- **Type**: Web Server Certificate (`Server Authentication` - OID `1.3.6.1.5.5.7.3.1`)
- **Key Algorithm**: RSA 2048-bit or 4096-bit (Unencrypted PEM private key)
- **Subject Alternative Names (SAN)**: Target FQDN, short hostname, and IP
- **Chain Order (PEM)**: Server Leaf Certificate &rarr; Intermediate CA &rarr; Root CA (`fullchain.pem`).

---

## 7. NGINX Reverse Proxy Installation & Port Forwarding

In accordance with OpenText's official documentation ([Connect with the VTS server - Enable port forwarding](https://admhelp.microfocus.com/vugen/en/26.1-26.3/help/WebHelp/Content/VTS/c_start_stop_server.htm)), NGINX acts as the single secure gateway (SSL termination) on port 443, routing traffic internally to instances via query-string regex.

### 7.1 Install NGINX & Configure SELinux
```bash
# 1. Install NGINX
sudo dnf install -y nginx

# 2. Allow NGINX to proxy outbound network traffic in SELinux
sudo setsebool -P httpd_can_network_connect 1
```

### 7.2 Active `/etc/nginx/conf.d/vts.conf` Configuration File

```nginx
server {
    listen       443 ssl;
    server_name  vts-server.local vts-server 192.168.122.245;

    # SSL Certificate & Key
    ssl_certificate      /etc/pki/tls/certs/vts.crt;
    ssl_certificate_key  /etc/pki/tls/private/vts.key;

    ssl_protocols        TLSv1.2 TLSv1.3;
    ssl_ciphers          HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # OpenText Query-String Port Forwarding + Web UI Proxy
    location / {
        if ($query_string ~* ^portnumber=(\d+)(.*)$) {
            set $port $1;
            set $para $2;
            proxy_pass http://127.0.0.1:$port$para;
        }

        # Default forward to VTS Web Admin UI (Port 4000)
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

# Redirect HTTP (Port 80) to HTTPS (Port 443)
server {
    listen       80;
    server_name  vts-server.local vts-server 192.168.122.245;
    return 301 https://$host$request_uri;
}
```

### 7.3 Start & Enable Service
```bash
sudo nginx -t
sudo systemctl enable --now nginx
```

---

## 8. Firewall Hardening (`firewalld`)

To enforce strict enterprise network compliance, all raw database backend ports (`4000`, `8888`, `2000`, `2001`) are blocked from the external network. Only standard web ports (**80**, **443**) and administrative SSH (**22**) are exposed.

```bash
# 1. Open standard web services
sudo firewall-cmd --add-service=https --permanent
sudo firewall-cmd --add-service=http --permanent

# 2. Remove backend instance ports from external network
sudo firewall-cmd --remove-port=4000/tcp --permanent
sudo firewall-cmd --remove-port=8888/tcp --permanent
sudo firewall-cmd --remove-port=2000-2050/tcp --permanent 2>/dev/null || true

# 3. Reload firewall
sudo firewall-cmd --reload
```

### Verification (`sudo firewall-cmd --list-all`)
```text
public (active)
  target: default
  interfaces: enp1s0
  services: cockpit dhcpv6-client http https ssh
  ports: 
```
*(Notice `ports:` is empty; only secure services `http` and `https` are accessible).*

---

## 9. LoadRunner VuGen & LRE Integration Guide

### 9.1 VuGen Runtime Setting (One-Time Setup per Script)
1. In VuGen, press **F4** (**Replay > Runtime Settings**).
2. Go to **General > Miscellaneous > VTS**.
3. Enable: ☑ **"Access VTS port by query string"**.
4. Set Port: **`443`** (HTTPS).

### 9.2 VuGen C Script Implementation (`vuser_init`, `Action`, `vuser_end`)

The C script code remains standard:

```c
#include "vts2.h"

vuser_init()
{
    // Connect to target instance port (e.g. 2000) over HTTPS 443
    lrvtc_connect("vts-server.local", 2000, VTOPT_KEEP_ALIVE);
    return 0;
}

Action()
{
    // 1. Fetch unique test data from VTS (Pops top row into {Customer_ID}, {Email})
    lrvtc_retrieve_row();

    // 2. Execute Application Under Test transaction
    lr_start_transaction("01_Account_Inquiry");

    web_custom_request("AccountDetails",
        "URL=https://api.internal.example.com/accounts/{Customer_ID}",
        "Method=GET",
        "Resource=0",
        LAST);

    lr_end_transaction("01_Account_Inquiry", LR_AUTO);

    // 3. (Optional) Append transaction status back to VTS
    // lrvtc_send_row1("Txn_ID;Status", "TXN100;SUCCESS", ";", VTSEND_STACKED);

    return 0;
}

vuser_end()
{
    // Cleanly close connection
    lrvtc_disconnect();
    return 0;
}
```

---

## 10. High-Concurrency Load Testing & Benchmarking

A modular shell benchmarking suite is located in [`load_test/`](file:///home/mahesh/vts_ocp/load_test/):

### Execution Command:
```bash
cd /home/mahesh/vts_ocp/load_test
./master_load_tester.sh --auth "maheshd:<seturpass>"
```

### Verified Multi-Instance Benchmark Results (3,000 Parallel Requests):

```text
             VTS MULTI-INSTANCE LOAD TEST & BENCHMARK REPORT (PARALLEL)         
 Test Duration          : 9.56 seconds
 Target Instances       : Port 2000, Port 2001, Port 8888 (Simultaneous)
 Total Requests Run     : 3000 (1500 Reads, 1500 Writes)
 Successful (HTTP 200)  : 3000 (100.0%)
 Failed / Errors        : 0 (0.0%)
 Overall Throughput     : 313.81 Requests/Second (RPS)
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
                     TARGET VM RESOURCE UTILIZATION                    
 CPU Utilization (%)    : Min: 1.5%  |  Average: 1.7%  |  Peak: 2.1%
 RAM Usage (MB)         : Min: 1410MB |  Average: 1411MB (9.0%) |  Peak: 1411MB (of 15731MB)
```

---

## 11. Configuration Files Repository Reference

The sanitized configuration files are saved in [`native_server_RHEL9-64bit/`](file:///home/mahesh/vts_ocp/native_server_RHEL9-64bit/):
- [`configure.json`](file:///home/mahesh/vts_ocp/native_server_RHEL9-64bit/configure.json) - VTS multi-instance, Basic Authentication, and database configuration.
- [`vts.conf`](file:///home/mahesh/vts_ocp/native_server_RHEL9-64bit/vts.conf) - NGINX SSL reverse proxy with OpenText query-string port forwarding.
