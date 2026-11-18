# OpenText Virtual Table Server (VTS) 26.1: VuGen Tester Guide & Quickstart

This guide is designed for **Performance Test Engineers**, **VuGen Scripters**, and **QA Automation Teams** interacting with containerized OpenText Virtual Table Server (VTS) 26.1 deployed on OpenShift using **Path-Based Routing** (`https://vts.apps-crc.testing/app1-team`).

---

## 1. What This Folder Contains

| File | Type | Description |
| :--- | :--- | :--- |
| [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/vts_lrvtc.h) | C Header | Drop-in VuGen compatibility header. Translates native `lrvtc_*` calls to secure HTTPS REST queries over OpenShift Ingress. |
| [`single_script_example.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/single_script_example.c) | C Source | Complete, unified single-file LoadRunner script containing `vuser_init()`, `Action()`, and `vuser_end()`. |
| [`TESTERS_GUIDE.md`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/TESTERS_GUIDE.md) | Markdown | This step-by-step implementation, execution, and troubleshooting manual. |

---

## 2. Why the Custom Header (`vts_lrvtc.h`) is Needed

In enterprise OpenShift deployments:
1. **Path-Based Multi-Tenancy:** Each team shares a single cluster Ingress domain (`https://vts.apps-crc.testing`) and is assigned an isolated subpath (e.g. `/app1-team`, `/app2-team`).
2. **Encrypted Ingress on Port 443:** OpenShift router terminates or re-encrypts traffic on standard HTTPS port 443.
3. **Legacy `lrvtc_connect` Limitations:** VuGen's built-in legacy `lrvtc_connect("host", port, ...)` function only accepts raw TCP hostnames and integer ports without subpaths (it fails with `VTCERR_INVALID_CONNECTION_INFO` when passed a URL path).
4. **Zero-Change Drop-In Solution:** [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/vts_lrvtc.h) bridges this gap transparently using preprocessor macros. Testers write standard `lrvtc_query_row()`, `lrvtc_update_message()`, etc., with **zero changes to test logic in `Action.c`**.

---

## 3. Step-by-Step Setup Guide

### Step 1: Configure Hosts File on Testing Laptop (Windows / macOS / Linux)

Because the OpenShift cluster uses a domain name (`vts.apps-crc.testing`), map the OpenShift host IP on your testing machine:

* **On Windows (`C:\Windows\System32\drivers\etc\hosts` as Administrator):**
  ```text
  192.168.1.51 vts.apps-crc.testing
  ```
* **On macOS / Linux (`/etc/hosts` with `sudo`):**
  ```bash
  192.168.1.51 vts.apps-crc.testing
  ```
*(Replace `192.168.1.51` with your actual OpenShift host or Ingress router IP).*

---

### Step 2: Verify Connectivity in Browser

Open Google Chrome or Microsoft Edge and navigate to:
```text
https://vts.apps-crc.testing/app1-team/
```
1. Accept the self-signed TLS certificate prompt (click *Advanced* -> *Proceed*).
2. Enter the VTS credentials when prompted:
   - **Username:** `vtsadmin`
   - **Password:** `*****`
3. You should see the live VTS web console displaying your team's table and data columns (`Customer_Code`, `Account_Num`, `Status`, etc.).

---

### Step 3: Add `vts_lrvtc.h` to Your VuGen Script

1. Create a new VuGen script or open an existing one using protocol: **Web - HTTP/HTML**.
2. Copy [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/vts_lrvtc.h) into the **root directory** of your VuGen script (the folder containing `default.cfg` and `globals.h`).
3. In VuGen, open `globals.h` and add `#include "vts_lrvtc.h"`:

```c
#ifndef _GLOBALS_H
#define _GLOBALS_H

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h" // <-- Include compatibility header here

#endif // _GLOBALS_H
```

---

## 4. The Complete VuGen Test Script

You can use the script in two ways:
* **Option A (Standard VuGen Layout):** Place `vuser_init()` in `vuser_init.c`, `Action()` in `Action.c`, and `vuser_end()` in `vuser_end.c`.
* **Option B (Single Unified File):** Place the entire code block below into `Action.c` or [`single_script_example.c`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/single_script_example.c).

```c
#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

// ==============================================================================
// 1. vuser_init: Connect to VTS Pod & Discover Column Schema
// ==============================================================================
int vuser_init()
{
    int rc;

    // Connect to App1 Team instance on default table port 8888
    // Syntax: lrvtc_connect("<domain>/<team-subpath>", port, options)
    rc = lrvtc_connect("vts.apps-crc.testing/app1-team", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS app1-team pod!");
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected to VTS app1-team pod!");
    return 0;
}

// ==============================================================================
// 2. Action: Test Data Retrieval, Parameterization, and Live Updates
// ==============================================================================
int Action()
{
    // Use static iteration counter for Web HTTP protocol (lr_get_iteration is undefined in Web protocol)
    static int current_iteration = 1;

    // -------------------------------------------------------------------------
    // Transaction 1: Fetch Row Data from VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_01_Query_Customer_Data");

    // lrvtc_query_row fetches row at index (current_iteration) and AUTOMATICALLY
    // creates VuGen parameters: {Customer_Code}, {Account_Num}, {Status}, etc.
    lrvtc_query_row(current_iteration);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);


    // -------------------------------------------------------------------------
    // Simulated Business Application Logic
    // -------------------------------------------------------------------------
    // Best practice: Perform target application HTTP calls in dedicated transactions
    // so VTS fetch times do not skew application performance metrics.
    lr_think_time(1);


    // -------------------------------------------------------------------------
    // Transaction 2: Update Status in VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_02_Update_Status");

    // lrvtc_update_message updates the Status column on row current_iteration
    lrvtc_update_message("Status", current_iteration, "PROCESSED_BY_WINDOWS_VUGEN");

    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_BY_WINDOWS_VUGEN'", current_iteration);

    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);


    // Increment iteration counter for next pass
    current_iteration++;

    return 0;
}

// ==============================================================================
// 3. vuser_end: Clean Disconnect from VTS
// ==============================================================================
int vuser_end()
{
    lrvtc_disconnect();
    lr_output_message(">>> [VTS] Session disconnected cleanly.");
    return 0;
}
```

---

## 5. Execution Verification (What You Should See)

When you press **F5 (Replay)** in VuGen, the Output log displays:

```text
vts_lrvtc.h(37): [VTS] Connecting to https://vts.apps-crc.testing/app1-team (Instance Port 8888)...
vts_lrvtc.h(54): web_custom_request("VTS_Connect_Init") was successful, 111 body bytes
vts_lrvtc.h(67): [VTS] Connected successfully! Discovered 10 columns.
vuser_init.c(7): >>> SUCCESS: Connected to VTS app1-team pod!
...
Action.c(6): Notify: Transaction "VTS_01_Query_Customer_Data" started.
vts_lrvtc.h(106): web_custom_request("VTS_QueryRow") was successful
Action.c(12): >>> [ROW 1] Customer Code : IND_Cust_1
Action.c(13): >>> [ROW 1] Account Num   : IND_ACC_10001
Action.c(14): >>> [ROW 1] Status        : ACTIVE
Action.c(16): Notify: Transaction "VTS_01_Query_Customer_Data" ended with a "Pass" status (Duration: 0.1713)
Action.c(19): Notify: Transaction "VTS_02_Update_Status" started.
vts_lrvtc.h(160): web_custom_request("VTS_UpdateMessage") was successful
Action.c(24): >>> [ROW 1] Updated Status to 'PROCESSED_BY_WINDOWS_VUGEN'
Action.c(26): Notify: Transaction "VTS_02_Update_Status" ended with a "Pass" status (Duration: 0.0784)
vts_lrvtc.h(249): [VTS] Disconnected cleanly.
Vuser Terminated.
```

---

## 6. Troubleshooting & Common Pitfalls

### Issue 1: "One or more files in scripts folder are in use preventing script to replay"
* **Probable Cause A (Background Process):** A previous failed or aborted run left `mmdrv.exe` or `cci.exe` active in the background.
  * **Fix:** Open Windows Task Manager (`Ctrl + Shift + Esc`) -> **Details** tab -> Locate `mmdrv.exe` or `cci.exe` -> Click **End Task**. In VuGen, click **Design** -> **Clean Script**.
* **Probable Cause B (Microsoft OneDrive File Lock):** If the script is stored inside `OneDrive\Documents\...`, OneDrive's real-time cloud synchronizer immediately locks newly created files (`pre_cci.ci`, `mdrv.log`), blocking VuGen's compiler.
  * **Fix:** Right-click the OneDrive icon in the Windows taskbar -> **Pause syncing (2 hours)**, or move the script folder out of OneDrive to a local directory (e.g., `C:\VuGen\Scripts\VTS_PATH_Based_Validation`).

---

### Issue 2: `Action.c: Unresolved symbol : lr_get_iteration`
* **Probable Cause:** `lr_get_iteration()` is an internal Controller/Analysis function and does **not** exist in the VuGen Web (HTTP/HTML) C protocol runtime library.
* **Fix:** Do not use `lr_get_iteration()`. Use a C `static int` counter as shown in the script:
  ```c
  static int current_iteration = 1;
  // ... at the end of Action:
  current_iteration++;
  ```

---

### Issue 3: `globals.h: error: vts_lrvtc.h no such file or directory`
* **Probable Cause:** The file was saved inside a subfolder, or Windows saved it as `vts_lrvtc.h.txt`.
* **Fix:** Ensure the file is named exactly `vts_lrvtc.h` and is located in the root script directory right alongside `globals.h` and `default.cfg`.

---

### Issue 4: `redeclaration of 'lrvtc_disconnect' previously declared at ... SharedParameter.h`
* **Probable Cause:** LoadRunner's built-in header declares function prototypes with conflicting signatures.
* **Fix:** Handled transparently inside [`vts_lrvtc.h`](file:///home/mahesh/vts_ocp/containerized_ubuntu_deployment_pathbasedRoute/vugen_handling_example/vts_lrvtc.h) by implementing internal routines as `vts_wrap_*` and remapping them with preprocessor macros (`#define lrvtc_... vts_wrap_...`).

---

### Issue 5: `Warning -27077: The 'vuser_init' section contains web function(s) when 'Simulate a new user on each iteration' is ON`
* **Probable Cause:** VuGen alerts that HTTP calls in `vuser_init` may not reset between iterations when new user simulation is enabled.
* **Explanation:** This warning is expected and harmless. VTS connection is established once during initialization in `vuser_init` and reused throughout all iterations.

---

## 7. Direct cURL Command Examples (Live API Reference)

For quick health checks or data preparation scripts without launching VuGen:

### 7.1 Fetch Schema (`getAllColumns`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getAllColumns"
```
**Response:**
```json
["ID","Customer_Code","Account_Num","Region","Status","Txn_Amount","Batch_ID","Category","Priority","Comments"]
```

### 7.2 Fetch Row Slice (`getTable`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getTable"
```
**Response:**
```json
[["1","IND_Cust_1","IND_ACC_10001","APAC","ACTIVE","11.50","IND_BATCH_B","ENTERPRISE","NORMAL","IND_Record_1"]]
```

### 7.3 Update Cell Value (`update`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"index":1,"column":"Status","value":"PROCESSED_BY_WINDOWS_VUGEN"}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/update"
```
**Response:** `null` (HTTP 200 OK)

### 7.4 Retrieve Record in FIFO Order (`retrieve`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"columns":["Batch_ID"],"condition":0}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/retrieve"
```

### 7.5 Add New Record to Bottom of Table (`add`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"option":0,"new":{"Customer_Code":"NEW_CUST_99","Status":"PENDING"}}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/add"
```

### 7.6 Clear Column Data (`clearColumn`)
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"columns":["Comments"]}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/clearColumn"
```
