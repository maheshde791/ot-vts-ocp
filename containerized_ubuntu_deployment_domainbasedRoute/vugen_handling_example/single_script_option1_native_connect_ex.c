/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - Domain-Based VTS Test Script (Option 1: Native connect_ex)
 * ==============================================================================
 * Description:
 *   RECOMMENDED ENTERPRISE STANDARD: Complete, self-contained single-file
 *   LoadRunner script using 100% native OpenText VuGen APIs (lrvtc_connect_ex)
 *   and built-in Runtime Settings Query String routing over HTTPS Port 443.
 *
 * Requirements:
 *   1. hosts file contains: "<Ingress-IP> vts-app1.apps-crc.testing vts-app2.apps-crc.testing"
 *   2. VuGen Runtime Settings (F4):
 *      -> General -> Miscellaneous -> VTS
 *      -> Check: "Access VTS port by query string"
 *      -> Set HTTPS Port: 443
 *   3. ZERO custom wrapper headers required! Standard vendor code only.
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"

// ==============================================================================
// 1. vuser_init: Native Authenticated Connection to VTS over HTTPS 443
// ==============================================================================
int vuser_init()
{
    int rc;

    lr_output_message("====================================================================");
    lr_output_message("[VTS OPTION 1] Connecting natively via lrvtc_connect_ex...");
    lr_output_message("====================================================================");

    // --------------------------------------------------------------------------
    // TARGET SELECTION:
    // Option A: Default Table Instance on App1 Team (Port 8888)
    //   rc = lrvtc_connect_ex("Server=https://vts-app1.apps-crc.testing", "Port=8888", "UserName=vtsadmin", "Password=*****", LAST);
    //
    // Option B: Multi-Instance Table on App1 Team (e.g. Instance_1 on Port 2001)
    //   rc = lrvtc_connect_ex("Server=https://vts-app1.apps-crc.testing", "Port=2001", "UserName=vtsadmin", "Password=*****", LAST);
    //
    // Option C: Default Table Instance on App2 Team (Port 8888)
    //   rc = lrvtc_connect_ex("Server=https://vts-app2.apps-crc.testing", "Port=8888", "UserName=vtsadmin", "Password=*****", LAST);
    // --------------------------------------------------------------------------

    rc = lrvtc_connect_ex(
        "Server=https://vts-app1.apps-crc.testing",
        "Port=8888",
        "UserName=vtsadmin",
        "Password=*****",
        LAST);

    lr_output_message(">>> Native lrvtc_connect_ex Return Code: %d", rc);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS! Error code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS via native lrvtc_connect_ex!");
    return 0;
}

// ==============================================================================
// 2. Action: Native Data Retrieval & Status Updates
// ==============================================================================
int Action()
{
    static int current_iteration = 1;
    int rc;

    // -------------------------------------------------------------------------
    // Transaction 1: Fetch Row Data from VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_01_Query_Customer_Data");

    rc = lrvtc_query_row(current_iteration);
    lr_output_message(">>> lrvtc_query_row(row=%d) Return Code: %d", current_iteration, rc);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Region        : %s", current_iteration, lr_eval_string("{Region}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);

    lr_think_time(1);

    // -------------------------------------------------------------------------
    // Transaction 2: Update Status in VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_02_Update_Status");

    rc = lrvtc_update_message("Status", current_iteration, "PROCESSED_VIA_LRVTC_CONNECT_EX");
    lr_output_message(">>> lrvtc_update_message Return Code: %d", rc);
    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_VIA_LRVTC_CONNECT_EX'", current_iteration);

    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);

    current_iteration++;
    return 0;
}

// ==============================================================================
// 3. vuser_end: Disconnect Session
// ==============================================================================
int vuser_end()
{
    lrvtc_disconnect();
    lr_output_message(">>> [VTS] Session disconnected cleanly.");
    return 0;
}
