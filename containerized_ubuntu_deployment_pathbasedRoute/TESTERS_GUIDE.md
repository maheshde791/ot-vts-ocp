# OpenText Virtual Table Server (VTS) 26.1: Performance Testers & LoadRunner Guide

This guide is designed for **Performance Test Engineers**, **VuGen Scripters**, and **QA Automation Teams** interacting with containerized OpenText VTS 26.1 on OpenShift.

It covers:
1. **Working cURL Command Examples** (ready-to-use API queries with full request and response payloads).
2. **VuGen Integration Approach 1: Drop-In Header (`vts_lrvtc.h`)** (Zero script logic rewrite; keeps native `lrvtc_*` methods).
3. **VuGen Integration Approach 2: REST API (`web_custom_request`)** (Standard HTTP/HTML protocol).
4. **VuGen Integration Approach 3: Native `lrvtc_connect_ex`** (For domain-based routes).
5. **Load Generator (LG) Runtime Configuration & Troubleshooting**.

---

## 1. Working cURL Command Examples (Live API Reference)

All requests to VTS 26.1 require:
- **Authentication:** HTTP Basic Authentication header `Authorization: Basic <base64>` (`vtsadmin:*****`).
- **Content-Type:** `application/json`.
- **Base Domain:** `https://vts.apps-crc.testing`
- **Team Subpaths:** `/app1-team/` or `/app2-team/`
- **Instance Ports:** Port `8888` (Default Table) or Ports `2000`–`2018` (Custom Tables).

---

### 1.1 List All Columns (Discover Table Schema)

Fetches an array of all active column headers in the table.

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getAllColumns"
```

#### Actual Live Response:
```json
["ID","Customer_Code","Account_Num","Region","Status","Txn_Amount","Batch_ID","Category","Priority","Comments"]
```

---

### 1.2 Fetch Table Slice (`getTable`)

Fetches a 2D matrix of row records between `start` and `end` row indexes.

#### Request (Fetch Row 1 from App1 Team, Port 8888):
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getTable"
```

#### Actual Live Response (App1 Team):
```json
[["1","IND_Cust_1","IND_ACC_10001","APAC","ACTIVE","11.50","IND_BATCH_B","ENTERPRISE","NORMAL","IND_Record_1"]]
```

#### Request (Fetch Row 1 from App2 Team, Port 8888):
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"end":1}' \
  "https://vts.apps-crc.testing/app2-team/proxy/8888/client_api/getTable"
```

#### Actual Live Response (App2 Team - Verified Isolated Data):
```json
[["1","APP2_IND_Cust_1","APP2_IND_ACC_10001","APAC","ACTIVE","21.50","APP2_IND_BATCH_B","ENTERPRISE_TEAM2","NORMAL","APP2_IND_Record_1"]]
```

---

### 1.3 Fetch Single Cell or Column Range (`getColumnRange`)

Reads specific rows for a designated column without fetching the entire row.

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"column":"Customer_Code","start":1,"end":3}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getColumnRange"
```

#### Actual Live Response:
```json
["IND_Cust_1","IND_Cust_2","IND_Cust_3"]
```

---

### 1.4 Update a Cell Value (`update`)

Updates a cell value at a specific row `index` for a given `column`.

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"index":1,"column":"Status","value":"PROCESSED_BY_LG"}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/update"
```

#### Actual Live Response:
```json
null
```
*(HTTP Status `200 OK` indicates successful update)*

---

### 1.5 FIFO Retrieve Message (`retrieve`)

Pops a value from the top of the column (row 1) and removes it from the queue (FIFO queue pattern).

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"columns":["Customer_Code"],"condition":0}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/retrieve"
```

#### Actual Live Response:
```json
["IND_Cust_1"]
```

---

### 1.6 Append Record at End of Column (`add`)

Appends a new value at the bottom of the table.

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"option":0,"new":{"Customer_Code":"IND_Cust_5001"}}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/add"
```

#### Actual Live Response:
```json
null
```
*(HTTP Status `200 OK`)*

---

### 1.7 Insert Record at Top of Column (`insert`)

Inserts a new value at row 1 (LIFO pattern).

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"new":{"Customer_Code":"PRIORITY_CUST_99"}}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/insert"
```

#### Actual Live Response:
```json
null
```

---

### 1.8 Clear Column Content (`clearColumn`)

Clears all data within a specific column starting from row 1.

#### Request:
```bash
curl -k -s -u vtsadmin:***** \
  -H "Content-Type: application/json" \
  -d '{"start":1,"columns":["Txn_Amount"]}' \
  "https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/clearColumn"
```

#### Actual Live Response:
```json
null
```

---

## 2. VuGen Integration Approach 1: Drop-In Header (`vts_lrvtc.h`)

This approach is recommended when the testing team wants **minimal to zero code changes**. Existing `lrvtc_query_row`, `lrvtc_update_message`, `lrvtc_retrieve_message`, and `lrvtc_send_message` calls remain **100% identical**.

### How it works:
1. Copy [`vts_lrvtc.h`](vts_lrvtc.h) into the VuGen script directory.
2. In `globals.h`, add: `#include "vts_lrvtc.h"`.
3. In `vuser_init.c`, update the `lrvtc_connect` server string to point to the team ingress subpath.

---

### Full Script Implementation Example:

#### `globals.h`:
```c
#ifndef _GLOBALS_H
#define _GLOBALS_H

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h" // <-- Drop-in header

#endif // _GLOBALS_H
```

#### `vuser_init.c`:
```c
vuser_init()
{
    // Connect to App1 Team pod (Default Table 8888)
    // Server argument format: "<domain>/<team-subpath>"
    int rc = lrvtc_connect("vts.apps-crc.testing/app1-team", 8888, 0);

    if (rc != 0) {
        lr_error_message("Failed to connect to VTS app1-team pod.");
        return -1;
    }

    lr_output_message("Successfully connected to VTS app1-team pod.");
    return 0;
}
```

#### `Action.c` (Zero Logic Change):
```c
Action()
{
    int current_iteration = lr_get_iteration();

    lr_start_transaction("VTS_01_Query_Customer_Data");

    // 1. Native lrvtc_query_row fetches row data and AUTOMATICALLY creates
    //    VuGen parameters: {Customer_Code}, {Account_Num}, {Status}, etc.
    lrvtc_query_row(current_iteration);

    lr_output_message("Extracted Customer Code: %s", lr_eval_string("{Customer_Code}"));
    lr_output_message("Extracted Account Number: %s", lr_eval_string("{Account_Num}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);


    lr_start_transaction("VTS_02_Update_Status");

    // 2. Native lrvtc_update_message updates the status column
    lrvtc_update_message("Status", current_iteration, "PROCESSED_BY_LG");

    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);


    lr_start_transaction("VTS_03_Retrieve_FIFO_Batch");

    // 3. Native lrvtc_retrieve_message pops next value into {Batch_ID}
    lrvtc_retrieve_message("Batch_ID");
    lr_output_message("Popped Batch ID: %s", lr_eval_string("{Batch_ID}"));

    lr_end_transaction("VTS_03_Retrieve_FIFO_Batch", LR_AUTO);

    return 0;
}
```

#### `vuser_end.c`:
```c
vuser_end()
{
    lrvtc_disconnect();
    return 0;
}
```

---

## 3. VuGen Integration Approach 2: REST API (`web_custom_request`)

If scripting in DevWeb, TruClient, or preferred standard Web HTTP protocol without C helper headers:

```c
Action()
{
    int row_id = lr_get_iteration();

    // 1. Set Authentication and JSON Content-Type
    web_add_auto_header("Authorization", "Basic dnRzYWRtaW46KioqKio=");
    web_add_auto_header("Content-Type", "application/json");

    // 2. Correlate Customer_Code from returned array
    web_reg_save_param_json(
        "ParamName=CustCode",
        "QueryString=$[0]",
        "NotFound=Warning",
        LAST);

    // 3. Execute REST query
    web_custom_request("VTS_GetCustomer",
        "URL=https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/getColumnRange",
        "Method=POST",
        "TargetFrame=",
        "Resource=0",
        "Referer=",
        "Mode=HTTP",
        "Body={\"column\":\"Customer_Code\",\"start\":{row_id},\"end\":{row_id}}",
        LAST);

    lr_output_message("Customer fetched: %s", lr_eval_string("{CustCode}"));

    // 4. Update Status column
    web_custom_request("VTS_UpdateStatus",
        "URL=https://vts.apps-crc.testing/app1-team/proxy/8888/client_api/update",
        "Method=POST",
        "Body={\"index\":{row_id},\"column\":\"Status\",\"value\":\"DONE\"}",
        LAST);

    return 0;
}
```

---

## 4. VuGen Integration Approach 3: Native `lrvtc_connect_ex` (Domain-Based)

If your enterprise exposes dedicated hostnames per team (e.g., `vts-app1.apps-crc.testing` and `vts-app2.apps-crc.testing`), testers can use OpenText's official secure C API:

```c
vuser_init()
{
    // Syntax: lrvtc_connect_ex(server, port, tls_mode, username, password, auth_type)
    // tls_mode: 1 (HTTPS)
    // auth_type: 1 (Basic Authentication)
    int rc = lrvtc_connect_ex("vts-app1.apps-crc.testing", 443, 1, "vtsadmin", "*****", 1);

    if (rc != 0) {
        lr_error_message("Connection failed to vts-app1. Return code: %d", rc);
        return -1;
    }
    return 0;
}
```

---

## 5. Load Generator (LG) Runtime Configuration & Troubleshooting

### 5.1 TLS / SSL Certificate Trust
* If the OpenShift router uses an internal corporate CA or self-signed certificate:
  * **Option A:** Install the Root/Intermediate CA certificate into the Windows Certificate Store (`Trusted Root Certification Authorities`) on all Load Generator servers.
  * **Option B:** In VuGen, add `web_set_sockets_option("SSL_VERSION", "TLS1.2");` in `vuser_init.c`.

### 5.2 Firewall & Network Connectivity
* **Only Port 443 (HTTPS)** must be opened from Load Generator servers to the OpenShift Ingress controller.
* Internal VTS ports (`4000`, `8888`, `2000`–`2018`, `10000`–`30000`) are reverse-proxied internally and **do not** require firewall openings.

### 5.3 Common Error Codes & Resolution

| Error Code / Message | Probable Cause | Resolution |
| :--- | :--- | :--- |
| `HTTP 401 Unauthorized` | Missing or invalid credentials. | Pass `Authorization: Basic dnRzYWRtaW46KioqKio=` header. |
| `HTTP 404 Not Found` | Missing `/proxy/<port>/client_api/` path or invalid port number. | Verify URL syntax: `https://<domain>/<team>/proxy/<port>/client_api/<method>`. |
| `HTTP 403 Forbidden` | Accessing port outside authorized range (`8888`, `2000–2050`). | Ensure instance port is between `2000` and `2050`. Direct access to internal database ports (`10000+`) is blocked by SSRF rules. |
| `VTCERR_INVALID_CONNECTION_INFO` | Passing URL path in native `lrvtc_connect`. | Native `lrvtc_connect` cannot parse subpaths. Use [`vts_lrvtc.h`](vts_lrvtc.h) or dedicated team hostnames. |
