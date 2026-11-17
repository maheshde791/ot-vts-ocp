# OpenText Virtual Table Server (VTS) 26.1 on OpenShift: Path-Based Multi-Tenancy Architecture & Deployment Guide

This document provides complete technical specifications, architectural designs, deployment instructions, and test engineering integration guidelines for deploying containerized **OpenText Virtual Table Server (VTS) 26.1** on **Red Hat OpenShift / CRC** using **Path-Based Multi-Tenancy**.

---

## Table of Contents

1. [Executive Summary & Architectural Model](#1-executive-summary--architectural-model)
2. [Core Architectural Innovations](#2-core-architectural-innovations)
   - [Zero-Disk Vendor Modification Principle](#21-zero-disk-vendor-modification-principle)
   - [In-Container NGINX Reverse Proxy & Stream Transformation](#22-in-container-nginx-reverse-proxy--stream-transformation)
   - [Gorilla WebSocket Upgrade & Connection Header Handling](#23-gorilla-websocket-upgrade--connection-header-handling)
   - [Relative Navigation Stream Rewriting for Angular SPA](#24-relative-navigation-stream-rewriting-for-angular-spa)
   - [SSRF Mitigation & Internal Valkey Port Protection](#25-ssrf-mitigation--internal-valkey-port-protection)
3. [Persistent Storage & Multi-Instance Engine Architecture](#3-persistent-storage--multi-instance-engine-architecture)
   - [Storage Architecture & Symlink Bootstrapping](#31-storage-architecture--symlink-bootstrapping)
   - [Multi-Instance Port Forwarding & Valkey Allocation](#32-multi-instance-port-forwarding--valkey-allocation)
   - [Graceful Shutdown & Data Persistence Life Cycle](#33-graceful-shutdown--data-persistence-life-cycle)
4. [Deployment Verification & Multi-Tenant Data Validation](#4-deployment-verification--multi-tenant-data-validation)
   - [Multi-Instance Scale: 20 Instances per Pod](#41-multi-instance-scale-20-instances-per-pod)
   - [High-Scale Data Population: 100,000 Records per Team](#42-high-scale-data-population-100000-records-per-team)
   - [Cold Pod Recreate & Cross-Tenant Isolation Results](#43-cold-pod-recreate--cross-tenant-isolation-results)
5. [LoadRunner VuGen & Load Generator (LG) Integration](#5-loadrunner-vugen--load-generator-lg-integration)
   - [Approach 1: Transparent Drop-In Header (`vts_lrvtc.h`) — Recommended](#51-approach-1-transparent-drop-in-header-vts_lrvtch--recommended)
   - [Approach 2: VuGen REST API Integration (`web_custom_request`)](#52-approach-2-vugen-rest-api-integration-web_custom_request)
   - [Approach 3: Native `lrvtc_connect_ex` with Dedicated Hostnames](#53-approach-3-native-lrvtc_connect_ex-with-dedicated-hostnames)
6. [Complete REST API Reference](#6-complete-rest-api-reference)
7. [Deployment Instructions & Operational Runbook](#7-deployment-instructions--operational-runbook)
   - [File Manifest](#71-file-manifest)
   - [Automated Deployment Execution](#72-automated-deployment-execution)
   - [Verification Commands](#73-verification-commands)

---

## 1. Executive Summary & Architectural Model

Enterprise performance testing teams often require isolated test data repositories across multiple independent application teams (`app1-team`, `app2-team`) while leveraging a **single shared ingress DNS domain** (e.g., `https://vts.apps-crc.testing`).

The official OpenText VTS container image (`performancetesting/opentext_vts_linux_ubuntu:26.1`) is designed exclusively for single-tenant, root-path (`/`) hosting with direct port exposure. This deployment achieves **Path-Based Multi-Tenancy** under a unified domain without altering the vendor image:

```
                                  +---------------------------------------+
                                  | LoadRunner LGs / Testers' Web Browser |
                                  +-------------------+-------------------+
                                                      |
                                    HTTPS Port 443 (TLS 1.2 / TLS 1.3)
                                                      v
                                  +---------------------------------------+
                                  |    OpenShift Ingress HAProxy Router   |
                                  |       (vts.apps-crc.testing)          |
                                  +-------------------+-------------------+
                                                      |
                         +----------------------------+----------------------------+
                         | Path: /app1-team/*                                      | Path: /app2-team/*
                         v                                                         v
         +-------------------------------+                         +-------------------------------+
         | Pod: vts-app1-team            |                         | Pod: vts-app2-team            |
         |  - In-Container NGINX (:8443) |                         |  - In-Container NGINX (:8443) |
         |  - VTS Web Console (:4000)    |                         |  - VTS Web Console (:4000)    |
         |  - Default Table (:8888)      |                         |  - Default Table (:8888)      |
         |  - Custom Tables (:2000-2018) |                         |  - Custom Tables (:2000-2018) |
         |  - Persistent PVC (10 GiB)    |                         |  - Persistent PVC (10 GiB)    |
         +-------------------------------+                         +-------------------------------+
```

### Key Architectural Metrics:

| Dimension | Specification |
| :--- | :--- |
| **Vendor Container Image** | `performancetesting/opentext_vts_linux_ubuntu:26.1` (100% Pristine) |
| **Shared Domain** | `vts.apps-crc.testing` |
| **Tenant Ingress Subpaths** | `/app1-team/` and `/app2-team/` |
| **Active Instances per Pod** | 20 instances (Port `8888` + Ports `2000`–`2018`) |
| **Data Capacity per Pod** | 100,000 records (5,000 rows $\times$ 10 columns $\times$ 20 tables) |
| **Internal Database Engine** | Valkey (Redis-compatible in-memory data store with disk persistence) |
| **Storage Architecture** | Red Hat OpenShift CSI Block/File PersistentVolumeClaim (10 GiB RWO) |
| **Security & Auth** | RBAC Basic Authentication (`vtsadmin:*****`) + End-to-End Re-encrypt TLS |

---

## 2. Core Architectural Innovations

### 2.1 Zero-Disk Vendor Modification Principle
To guarantee vendor compliance and seamless future container updates, **zero vendor application files on disk are modified**. All root paths, Angular single-page application (SPA) base tags, WebSocket URIs, and instance navigation URLs are transformed dynamically in-flight using NGINX stream filters (`sub_filter`).

### 2.2 In-Container NGINX Reverse Proxy & Stream Transformation
The container runs an unprivileged NGINX reverse-proxy on port `8443` fronting VTS services (`4000`, `8888`, `2000–2050`). 

When traffic enters through OpenShift with the team prefix (e.g., `/app1-team/`), NGINX performs the following runtime stream substitutions:

```nginx
# Non-destructive stream transformation for pristine vendor SPA
sub_filter '<base href="/">' '<base href="/$team_prefix/">';
sub_filter 'this.baseURL=""' 'this.baseURL="/$team_prefix"';
sub_filter 'prefix:"/assets/i18n/"' 'prefix:"assets/i18n/"';
sub_filter '}/ws`' '}/$team_prefix/ws`';
sub_filter 'window.open(o,"_blank")' 'window.open(o.slice(1),"_blank")';
sub_filter 'window.open(s,"_blank")' 'window.open(s.slice(1),"_blank")';
sub_filter_types application/javascript text/javascript;
sub_filter_once off;
```

### 2.3 Gorilla WebSocket Upgrade & Connection Header Handling
VTS uses the Go Gorilla WebSocket library on port `4000/ws` for real-time table grid updates. When applying `sub_filter`, NGINX requires `proxy_set_header Accept-Encoding "";` to prevent upstream gzip compression.

> [!WARNING]
> In NGINX, declaring any `proxy_set_header` inside a child `location` block wipes out all inherited `proxy_set_header` directives from the parent `server` block.

To prevent dropping WebSocket handshakes (`400 Bad Request` / UI showing `Disconnected`), the WebSocket upgrade headers are explicitly declared directly inside the child location block:
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

### 2.4 Relative Navigation Stream Rewriting for Angular SPA
When an operator navigates to another VTS instance from the UI drop-down ("Other Instances"), the compiled Angular SPA invokes `window.open(this.router.serializeUrl(n), "_blank")`, emitting an absolute path `"/ ?port=2000"`. 

The leading slash would force browsers to jump to the root domain (`https://vts.apps-crc.testing/?port=2000`), escaping the team path and causing HTTP 404 errors. 

NGINX in-flight stream rewriting transforms this dynamically:
```nginx
sub_filter 'window.open(o,"_blank")' 'window.open(o.slice(1),"_blank")';
```
This converts the target to a relative URL `"?port=2000"`, keeping the browser securely inside `https://vts.apps-crc.testing/app1-team/?port=2000`.

### 2.5 SSRF Mitigation & Internal Valkey Port Protection
Each active VTS table instance dynamically provisions an internal Valkey process on ports between `10000` and `30000`. 

NGINX enforces strict Server-Side Request Forgery (SSRF) controls:
```nginx
# 1. Allow strictly authorized API ports: 4000, 8888, 2000-2050
if ($query_string ~* "^portnumber=(4000|888[89]|889[0-9]|890[0-8]|20[0-4][0-9]|2050)(.*)$") {
    set $inst_port $1;
    set $inst_param $2;
    proxy_pass http://127.0.0.1:$inst_port$inst_param;
    break;
}

# 2. Block any attempt targeting internal Valkey storage engines
if ($query_string ~* "portnumber=") {
    return 403;
}
```

---

## 3. Persistent Storage & Multi-Instance Engine Architecture

### 3.1 Storage Architecture & Symlink Bootstrapping
VTS maintains instance definitions in `/opt/OT/OT_VTS/web/instances.json` and database files in `/var/lib/OT/OT_VTS/db/data`. In containerized environments without persistence, terminating a pod wipes all custom table instances.

To resolve this:
1. A 10 GiB PVC is mounted at `/var/lib/OT/OT_VTS/db/data`.
2. On pod initialization, an automatic bootstrapping script inspects `/var/lib/OT/OT_VTS/db/data/instances.json`:
   - If missing or empty, it seeds the initial default instance.
   - If present, it verifies JSON validity.
3. The script creates an atomic symlink from `/opt/OT/OT_VTS/web/instances.json` pointing to the persistent storage file.

```bash
# Entrypoint initialization script inside vts-deployment.yaml
if [ ! -f /var/lib/OT/OT_VTS/db/data/instances.json ] || [ ! -s /var/lib/OT/OT_VTS/db/data/instances.json ]; then
    echo '[{"name":"Default","port":8888,"serviceStatus":true}]' > /var/lib/OT/OT_VTS/db/data/instances.json
fi
ln -sf /var/lib/OT/OT_VTS/db/data/instances.json /opt/OT/OT_VTS/web/instances.json
```

### 3.2 Multi-Instance Port Forwarding & Valkey Allocation
* **Default Table:** Port `8888` (API access) backed by Valkey port allocated from pool `10000-30000`.
* **Custom Tables (Instance_1 through Instance_19):** Ports `2000` through `2018`.
* **Admin Web UI:** Port `4000`.
* **In-Container NGINX:** Port `8443` (TLS 1.2 / TLS 1.3).

### 3.3 Graceful Shutdown & Data Persistence Life Cycle
Valkey periodically dumps memory to disk (`dump.rdb` / AOF). When Kubernetes sends `SIGTERM`, processes may terminate before in-memory writes are committed.

A `preStop` container lifecycle hook triggers synchronous disk flushing before pod termination:
```yaml
lifecycle:
  preStop:
    exec:
      command:
        - /bin/bash
        - -c
        - |
          # Flush all active Valkey database instances to disk
          for pid in $(pgrep valkey-server); do
            port=$(ss -tlpn | grep "pid=${pid}," | awk '{print $4}' | awk -F: '{print $NF}')
            if [ -n "${port}" ]; then
              /opt/OT/OT_VTS/web/valkey-cli -p "${port}" save 2>/dev/null || true
            fi
          done
          sync
          sleep 2
```

---

## 4. Deployment Verification & Multi-Tenant Data Validation

### 4.1 Multi-Instance Scale: 20 Instances per Pod
Both `vts-app1-team` and `vts-app2-team` pods were initialized with 20 concurrent table instances:
- **Port 8888:** `Default`
- **Port 2000–2018:** `Instance_1` through `Instance_19`

### 4.2 High-Scale Data Population: 100,000 Records per Team
Each table was populated with **5,000 records** across **10 schema columns** ($5,000 \times 20 = 100,000$ records per pod; **200,000 records total across both pods**).

To guarantee strict tenant and instance isolation, each table was injected with unique country-coded identifiers:

| Port | Instance Name | App1 Team Prefix | App2 Team Prefix | Total Records |
| :--- | :--- | :--- | :--- | :--- |
| **8888** | Default | `IND_Cust_1` .. `5000` | `APP2_IND_Cust_1` .. `5000` | 5,000 |
| **2000** | Instance_1 | `AUS_Cust_1` .. `5000` | `APP2_AUS_Cust_1` .. `5000` | 5,000 |
| **2001** | Instance_2 | `USA_Cust_1` .. `5000` | `APP2_USA_Cust_1` .. `5000` | 5,000 |
| **2002** | Instance_3 | `GBR_Cust_1` .. `5000` | `APP2_GBR_Cust_1` .. `5000` | 5,000 |
| **2003** | Instance_4 | `CAN_Cust_1` .. `5000` | `APP2_CAN_Cust_1` .. `5000` | 5,000 |
| **2004** | Instance_5 | `DEU_Cust_1` .. `5000` | `APP2_DEU_Cust_1` .. `5000` | 5,000 |
| **2005** | Instance_6 | `FRA_Cust_1` .. `5000` | `APP2_FRA_Cust_1` .. `5000` | 5,000 |
| **2006** | Instance_7 | `JPN_Cust_1` .. `5000` | `APP2_JPN_Cust_1` .. `5000` | 5,000 |
| **2007** | Instance_8 | `SGP_Cust_1` .. `5000` | `APP2_SGP_Cust_1` .. `5000` | 5,000 |
| **2008** | Instance_9 | `NZL_Cust_1` .. `5000` | `APP2_NZL_Cust_1` .. `5000` | 5,000 |
| **2009** | Instance_10 | `IRL_Cust_1` .. `5000` | `APP2_IRL_Cust_1` .. `5000` | 5,000 |
| **2010** | Instance_11 | `CHE_Cust_1` .. `5000` | `APP2_CHE_Cust_1` .. `5000` | 5,000 |
| **2011** | Instance_12 | `NLD_Cust_1` .. `5000` | `APP2_NLD_Cust_1` .. `5000` | 5,000 |
| **2012** | Instance_13 | `SWE_Cust_1` .. `5000` | `APP2_SWE_Cust_1` .. `5000` | 5,000 |
| **2013** | Instance_14 | `NOR_Cust_1` .. `5000` | `APP2_NOR_Cust_1` .. `5000` | 5,000 |
| **2014** | Instance_15 | `DNK_Cust_1` .. `5000` | `APP2_DNK_Cust_1` .. `5000` | 5,000 |
| **2015** | Instance_16 | `FIN_Cust_1` .. `5000` | `APP2_FIN_Cust_1` .. `5000` | 5,000 |
| **2016** | Instance_17 | `ESP_Cust_1` .. `5000` | `APP2_ESP_Cust_1` .. `5000` | 5,000 |
| **2017** | Instance_18 | `ITA_Cust_1` .. `5000` | `APP2_ITA_Cust_1` .. `5000` | 5,000 |
| **2018** | Instance_19 | `BRA_Cust_1` .. `5000` | `APP2_BRA_Cust_1` .. `5000` | 5,000 |

### 4.3 Cold Pod Recreate & Cross-Tenant Isolation Results
1. Both pods (`vts-app1-team` and `vts-app2-team`) were terminated via `oc delete pod`.
2. Fresh pods spawned, attached the persistent volumes, read the symlinked `instances.json`, and initialized all 20 database engines.
3. Automated verification script scanned all 20 tables on both pods:
   - **`app1-team`:** 100% of rows matched expected country identifiers (`IND`, `AUS`, ..., `BRA`).
   - **`app2-team`:** 100% of rows matched expected prefixed identifiers (`APP2_IND`, `APP2_AUS`, ..., `APP2_BRA`).
   - **Cross-tenant query test:** Querying port 2004 on `app1-team` returned `DEU_Cust_1` while querying port 2004 on `app2-team` returned `APP2_DEU_Cust_1`. **Zero data swapping or leakage.**

---

## 5. LoadRunner VuGen & Load Generator (LG) Integration

LoadRunner performance testing scripts running on distributed Load Generators (LGs) need to query and update VTS data. 

### 5.1 Approach 1: Transparent Drop-In Header (`vts_lrvtc.h`) — Recommended
This approach allows testing teams to keep **100% of their existing `lrvtc_*` methods** with **zero changes to `Action.c`**.

#### How it works:
1. Copy [`vts_lrvtc.h`](vts_lrvtc.h) into the VuGen script directory.
2. In `globals.h`, add: `#include "vts_lrvtc.h"`.
3. In `vuser_init.c`:
   ```c
   vuser_init()
   {
       // Connects to App1 or App2 pod over HTTPS with Basic Auth
       lrvtc_connect("vts.apps-crc.testing/app1-team", 8888, 0);
       return 0;
   }
   ```
4. In `Action.c` (**Unchanged existing script code**):
   ```c
   Action()
   {
       int iteration = lr_get_iteration();

       // Native lrvtc_query_row automatically populates {Customer_Code}, {Status}, etc.
       lrvtc_query_row(iteration);
       lr_output_message("Customer Code: %s", lr_eval_string("{Customer_Code}"));

       // Native lrvtc_update_message
       lrvtc_update_message("Status", iteration, "PROCESSED_BY_LG");

       // Native lrvtc_retrieve_message (FIFO queue pop)
       lrvtc_retrieve_message("Batch_ID");

       return 0;
   }

   vuser_end()
   {
       lrvtc_disconnect();
       return 0;
   }
   ```

### 5.2 Approach 2: VuGen REST API Integration (`web_custom_request`)
For microservice-style testing or protocols without C runtime hooks (e.g., DevWeb, TruClient Web):

```c
Action()
{
    web_add_auto_header("Authorization", "Basic dnRzYWRtaW46KioqKio=");
    web_add_auto_header("Content-Type", "application/json");

    // Fetch cell from App1 Team (Port 8888, Row 1)
    web_reg_save_param_json(
        "ParamName=CustCode",
        "QueryString=$[0]",
        LAST);

    web_custom_request("VTS_Fetch_Customer",
        "URL=https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getColumnRange",
        "Method=POST",
        "Body={\"column\":\"Customer_Code\",\"start\":1,\"end\":1}",
        LAST);

    lr_output_message("Fetched Customer: %s", lr_eval_string("{CustCode}"));
    return 0;
}
```

### 5.3 Approach 3: Native `lrvtc_connect_ex` with Dedicated Hostnames
If organizational policy forbids helper headers, expose dedicated OpenShift routes for each team (`vts-app1.apps-crc.testing` and `vts-app2.apps-crc.testing`) and use OpenText's native secure connection API:

```c
vuser_init()
{
    // lrvtc_connect_ex(server, port, tls_mode, username, password, auth_type)
    lrvtc_connect_ex("vts-app1.apps-crc.testing", 443, 1, "vtsadmin", "*****", 1);
    return 0;
}
```

---

## 6. Complete REST API Reference

All requests must include `Content-Type: application/json` and `Authorization: Basic <base64(vtsadmin:*****>`.

| API Purpose | HTTP | URL Endpoint | Request Body | Sample Response |
| :--- | :--- | :--- | :--- | :--- |
| **Fetch Table Slice** | POST | `/<team>/proxy/<port>/client_api/getTable` | `{"start": 1, "end": 2}` | `[["1","IND_Cust_1",...],["2","IND_Cust_2",...]]` |
| **Fetch Cell Range** | POST | `/<team>/proxy/<port>/client_api/getColumnRange` | `{"column": "Customer_Code", "start": 1, "end": 1}` | `["IND_Cust_1"]` |
| **List Columns** | POST | `/<team>/proxy/<port>/client_api/getAllColumns` | `{}` | `["ID","Customer_Code","Status",...]` |
| **Update Cell** | POST | `/<team>/proxy/<port>/client_api/update` | `{"index": 1, "column": "Status", "value": "PROCESSED"}` | `null` (HTTP 200) |
| **FIFO Retrieve** | POST | `/<team>/proxy/<port>/client_api/retrieve` | `{"columns": ["Batch_ID"], "condition": 0}` | `["IND_BATCH_B"]` |
| **Append Row (Bottom)** | POST | `/<team>/proxy/<port>/client_api/add` | `{"option": 0, "new": {"Customer_Code": "NEW_001"}}` | `null` (HTTP 200) |
| **Insert Row (Top)** | POST | `/<team>/proxy/<port>/client_api/insert` | `{"new": {"Customer_Code": "NEW_001"}}` | `null` (HTTP 200) |
| **Clear Column Data** | POST | `/<team>/proxy/<port>/client_api/clearColumn` | `{"start": 1, "columns": ["Txn_Amount"]}` | `null` (HTTP 200) |

---

## 7. Deployment Instructions & Operational Runbook

### 7.1 File Manifest

```
containerized_ubuntu_deployment/
|-- deploy_vts_app.sh           # Automated deployment script for app1, app2, or both
|-- vts-pvc.yaml                # 10 GiB RWO PersistentVolumeClaim (App1 Team)
|-- vts-configmap.yaml          # configure.json & NGINX reverse proxy config (App1 Team)
|-- vts-deployment.yaml         # Stateful single-pod deployment with auto-symlink (App1 Team)
|-- vts-service.yaml            # ClusterIP Service exposing port 443 -> 8443 (App1 Team)
|-- vts-route.yaml              # OpenShift Re-encrypt route on /app1-team (App1 Team)
|-- vts-app2-pvc.yaml           # 10 GiB RWO PersistentVolumeClaim (App2 Team)
|-- vts-app2-configmap.yaml     # configure.json & NGINX reverse proxy config (App2 Team)
|-- vts-app2-deployment.yaml    # Stateful single-pod deployment with auto-symlink (App2 Team)
|-- vts-app2-service.yaml       # ClusterIP Service exposing port 443 -> 8443 (App2 Team)
|-- vts-app2-route.yaml         # OpenShift Re-encrypt route on /app2-team (App2 Team)
|-- vts_lrvtc.h                 # VuGen C compatibility header for test engineers
`-- README.md                   # This document
```

### 7.2 Automated Deployment Execution

Execute the unified deployer script:

```bash
# 1. Navigate to deployment folder
cd /home/mahesh/vts_ocp/containerized_ubuntu_deployment

# 2. Deploy both App1 and App2 teams
./deploy_vts_app.sh all

# Or deploy individual teams:
# ./deploy_vts_app.sh app1
# ./deploy_vts_app.sh app2
```

### 7.3 Verification Commands

#### 1. Check Pod Status
```bash
oc get pods,pvc,route -n lre-vts
```

#### 2. Query App1 Team Web Console
```bash
curl -k -i -u vtsadmin:***** https://vts.apps-crc.testing/app1-team/
```

#### 3. Query App1 Team Table Data (Port 8888)
```bash
curl -k -s -u vtsadmin:***** -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getTable
```

#### 4. Query App2 Team Table Data (Port 8888)
```bash
curl -k -s -u vtsadmin:***** -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  https://vts.apps-crc.testing/app2-team/proxy/8888/client_api/getTable
```

#### 5. Verify Cold Pod Restart Persistence
```bash
# Delete pod
oc delete pod -l app=vts-app1-team -n lre-vts

# Wait for replacement pod to be Ready
oc wait --for=condition=Ready pod -l app=vts-app1-team -n lre-vts --timeout=120s

# Re-verify row 1 data is preserved
curl -k -s -u vtsadmin:***** -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getTable
```
