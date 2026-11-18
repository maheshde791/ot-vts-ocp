# OpenText Virtual Table Server (VTS) 26.1: Domain-Based VuGen Tester Guide

This guide is designed for **Performance Test Engineers**, **VuGen Scripters**, and **QA Automation Teams** interacting with containerized OpenText Virtual Table Server (VTS) 26.1 deployed on Red Hat OpenShift / CRC using **Domain-Based Multi-Tenancy**:
- **App1 Team:** `https://vts-app1.apps-crc.testing/`
- **App2 Team:** `https://vts-app2.apps-crc.testing/`

---

## 1. What This Folder Contains

| File | Type | Description |
| :--- | :--- | :--- |
| [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/vts_lrvtc.h) | C Header | **Mandatory drop-in compatibility header.** Translates native `lrvtc_*` calls into HTTPS REST requests (`web_custom_request`) over standard port 443. |
| [`single_script_example.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/single_script_example.c) | C Source | **Complete, unified single-file LoadRunner script** combining `vuser_init`, `Action`, and `vuser_end`. |
| [`vuser_init.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/vuser_init.c) | C Source | Drop-in `vuser_init` file for existing multi-action VuGen scripts. |
| [`Action.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/Action.c) | C Source | Drop-in `Action` file showing query, evaluation, and update transactions. |
| [`vuser_end.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/vuser_end.c) | C Source | Drop-in `vuser_end` file for clean disconnect. |
| [`TESTERS_GUIDE.md`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/TESTERS_GUIDE.md) | Markdown | This step-by-step setup and execution manual. |

---

## 2. Architecture & Benefit of Domain-Based Routing

In Domain-Based Multi-Tenancy, each team is assigned an isolated subdomain (`vts-app1...`, `vts-app2...`):
1. **Clean Root URL:** The OpenText VTS admin console runs directly at root `/` with no URI path collisions.
2. **Dedicated Ingress Isolation:** Team traffic is isolated at the OpenShift Ingress layer with TLS re-encryption.
3. **Transparent Protocol Translation (`vts_lrvtc.h`):** Because Kubernetes/OpenShift cloud environments only expose HTTPS port 443 (while legacy `vtc.dll` expects direct, raw TCP sockets on port 8888 or 2000), `vts_lrvtc.h` transparently bridges the calls into HTTPS REST requests over port 443. Script code in `Action.c` remains 100% standard LoadRunner C code.

---

## 3. Prerequisites & One-Time Client Setup

### Step 1: Configure Hosts File on Windows / Client Machine
Ensure your operating system resolves the two domains to your OpenShift Ingress host:

* **On Windows (`C:\Windows\System32\drivers\etc\hosts` as Administrator):**
  ```text
  192.168.1.51 vts-app1.apps-crc.testing vts-app2.apps-crc.testing
  ```
* **On macOS / Linux (`/etc/hosts` with `sudo`):**
  ```bash
  192.168.1.51 vts-app1.apps-crc.testing vts-app2.apps-crc.testing
  ```
*(Replace `192.168.1.51` with your actual OpenShift host or Ingress router IP).*

---

### Step 2: (Optional but Recommended) Install OpenShift Router CA on Windows
To eliminate browser certificate warnings when visiting the VTS Admin Web UI:
1. Locate [`certs/openshift-router-ca.crt`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/certs/openshift-router-ca.crt).
2. On your Windows machine, open **PowerShell as Administrator** and run:
   ```powershell
   Import-Certificate -FilePath "C:\certs\openshift-router-ca.crt" -CertStoreLocation "Cert:\LocalMachine\Root"
   ```
3. Or double-click the file -> **Install Certificate** -> **Local Machine** -> **Trusted Root Certification Authorities** -> **Finish**.

---

### Step 3: Verify Connectivity in Browser
Open Google Chrome or Microsoft Edge and navigate to:
```text
https://vts-app1.apps-crc.testing/
```
and
```text
https://vts-app2.apps-crc.testing/
```
1. Enter the VTS credentials:
   - **Username:** `vtsadmin`
   - **Password:** `*****`
2. Confirm the VTS Admin Console loads at root `/` displaying your team's table data.

---

## 4. Script Implementation in VuGen

### Option A: Standard Multi-File VuGen Project
Copy [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/vts_lrvtc.h) into your VuGen script folder, then use the individual files:

#### 1. `vuser_init.c`:
```c
#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

int vuser_init()
{
    int rc;

    // Connect to App1 Team default table instance (Port 8888) over HTTPS port 443
    rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS! Return code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS via domain-based route!");
    return 0;
}
```

#### 2. `Action.c`:
```c
#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

int Action()
{
    static int current_iteration = 1;

    // Transaction 1: Query Row Data
    lr_start_transaction("VTS_01_Query_Customer_Data");
    lrvtc_query_row(current_iteration);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Region        : %s", current_iteration, lr_eval_string("{Region}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));
    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);

    lr_think_time(1);

    // Transaction 2: Update Status
    lr_start_transaction("VTS_02_Update_Status");
    lrvtc_update_message("Status", current_iteration, "PROCESSED_DOMAIN_BASED");
    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_DOMAIN_BASED'", current_iteration);
    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);

    current_iteration++;
    return 0;
}
```

#### 3. `vuser_end.c`:
```c
#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

int vuser_end()
{
    lrvtc_disconnect();
    lr_output_message(">>> [VTS] Session disconnected cleanly.");
    return 0;
}
```

---

### Option B: All-In-One Single Script (`single_script_example.c`)
If your project team prefers reviewing or pasting a complete self-contained script in one file, use [`single_script_example.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_domainbasedRoute/vugen_handling_example/single_script_example.c).

---

## 5. How to Target Different Instances

| Target Scenario | Server Parameter | Port Parameter | Notes |
| :--- | :--- | :--- | :--- |
| **App1 Team - Default Table** | `"vts-app1.apps-crc.testing"` | `8888` | Default primary table instance |
| **App1 Team - Instance 1** | `"vts-app1.apps-crc.testing"` | `2000` | Secondary table instance |
| **App1 Team - Instance N** | `"vts-app1.apps-crc.testing"` | `2000 + N - 1` | Ports `2000`–`2018` |
| **App2 Team - Default Table** | `"vts-app2.apps-crc.testing"` | `8888` | Isolated tenant App2 |
| **App2 Team - Instance 1** | `"vts-app2.apps-crc.testing"` | `2000` | Isolated tenant App2 secondary table |

Example targeting `Instance_1` on Port 2000:
```c
lrvtc_connect("vts-app1.apps-crc.testing", 2000, 0);
```

---

## 6. Recommended VuGen Runtime Settings

1. **Iteration Logic (`lr_get_iteration` warning):**
   * Web HTTP protocol does not declare `lr_get_iteration()`.
   * **Best Practice:** Use a file-scope static counter in `Action.c`:
     ```c
     static int current_iteration = 1;
     // ... operations ...
     current_iteration++;
     ```
2. **"Files in scripts folder are in use" / CCI lock:**
   * If VuGen reports that `.ci` files are in use:
     - End any orphaned `mmdrv.exe` or `cci.exe` processes in Windows Task Manager.
     - Click **Design -> Clean Script** in VuGen.
     - Keep script directories outside real-time cloud sync folders (e.g., save in `C:\VuGen\Scripts\` instead of `OneDrive\`).
3. **Transaction Placement:**
   * Always encapsulate `lrvtc_query_row` and `lrvtc_update_message` in their own separate transactions (`VTS_01_Query...`, `VTS_02_Update...`) outside your application's business transactions.

---

## 7. Direct cURL Examples (Command-Line Verification)

### App1 Team - Default Instance (Port 8888):
```bash
# Query Row 1
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts-app1.apps-crc.testing/proxy/8888/client_api/getTable"

# Update Cell
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"index":1,"column":"Status","value":"PROCESSED_DOMAIN_BASED"}' \
  "https://vts-app1.apps-crc.testing/proxy/8888/client_api/update"
```

### App1 Team - Secondary Instance (Port 2000):
```bash
# Query Row 1 from Instance_1
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts-app1.apps-crc.testing/proxy/2000/client_api/getTable"
```

### App2 Team - Default Instance (Port 8888):
```bash
# Query Row 1 from App2
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts-app2.apps-crc.testing/proxy/8888/client_api/getTable"
```

---

## 8. Frequently Asked Questions for Test Teams

### Q1: Why do I need to include `vts_lrvtc.h` in my script?
* In traditional on-premises VMs, VTS required opening unencrypted, raw TCP ports (`8888`, `2000`, `2001`, etc.) for every table.
* In enterprise cloud environments, all traffic must enter securely over **HTTPS port 443**.
* LoadRunner's native `vtc.dll` was built for raw TCP sockets. The `vts_lrvtc.h` header transparently translates your `lrvtc_*` function calls into high-performance HTTPS REST requests (`web_custom_request`) over port 443.

### Q2: Do I have to rewrite my script or change how I access parameters?
* **No.** Not a single line of business logic or transaction code in `Action.c` needs to change.
* You continue using `lrvtc_query_row()`, `lrvtc_update_message()`, and `lr_eval_string("{ColumnName}")` exactly as before.

### Q3: Will this script and header change when deploying to production cloud?
* **No.** The header is 100% environment-agnostic.
* The only item that changes is the target domain name passed to `lrvtc_connect()`:
  * Local CRC: `lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);`
  * Production Cloud: `lrvtc_connect("vts-app1.<enterprise-cloud-domain>", 8888, 0);`

### Q4: How do on-premises Load Generators (LGs) communicate with the Cloud VTS?
* All Load Generators communicate with the Cloud VTS exclusively via outbound HTTPS on port 443.
* Because port 443 is standard outbound HTTPS, no special firewall pinholes or raw TCP port ranges (`2000–2050`) need to be requested from enterprise network teams.
