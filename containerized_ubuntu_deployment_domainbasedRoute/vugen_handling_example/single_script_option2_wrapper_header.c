/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - Domain-Based VTS Test Script (Option 2: Wrapper Header)
 * ==============================================================================
 * Description:
 *   LEAST PREFERRED / FALLBACK METHOD: Complete single-file LoadRunner script
 *   using the custom compatibility header (vts_lrvtc.h) with standard lrvtc_connect.
 *
 * Use Cases:
 *   - Legacy VuGen versions without lrvtc_connect_ex support.
 *   - Scenarios where testers cannot modify VuGen Runtime Settings.
 *
 * Requirements:
 *   1. hosts file contains: "<Ingress-IP> vts-app1.apps-crc.testing vts-app2.apps-crc.testing"
 *   2. vts_lrvtc.h must be present in the script directory or included in globals.h.
 *   3. Standard lrvtc_connect syntax with zero Runtime Settings changes needed.
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

// ==============================================================================
// 1. vuser_init: Connect to VTS using the drop-in compatibility header
// ==============================================================================
int vuser_init()
{
    int rc;

    lr_output_message("====================================================================");
    lr_output_message("[VTS OPTION 2] Connecting via custom header wrapper (vts_lrvtc.h)...");
    lr_output_message("====================================================================");

    // --------------------------------------------------------------------------
    // TARGET SELECTION:
    // Option A: Default Table Instance on App1 Team (Port 8888)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);
    //
    // Option B: Multi-Instance Table on App1 Team (e.g. Instance_1 on Port 2001)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 2001, 0);
    //
    // Option C: Default Table Instance on App2 Team (Port 8888)
    //   rc = lrvtc_connect("vts-app2.apps-crc.testing", 8888, 0);
    // --------------------------------------------------------------------------

    rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS vts-app1! Return code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS vts-app1 via wrapper header!");
    return 0;
}

// ==============================================================================
// 2. Action: Test Data Retrieval, Parameterization, and Live Updates
// ==============================================================================
int Action()
{
    static int current_iteration = 1;

    // -------------------------------------------------------------------------
    // Transaction 1: Fetch Row Data from VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_01_Query_Customer_Data");

    lrvtc_query_row(current_iteration);

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

    lrvtc_update_message("Status", current_iteration, "PROCESSED_VIA_WRAPPER_HEADER");

    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_VIA_WRAPPER_HEADER'", current_iteration);

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
