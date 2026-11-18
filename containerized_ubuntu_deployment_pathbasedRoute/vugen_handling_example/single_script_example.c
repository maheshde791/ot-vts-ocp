/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - Complete Standalone VTS Test Script
 * ==============================================================================
 * Description:
 *   Demonstrates end-to-end integration with containerized OpenText VTS on OpenShift
 *   using path-based routing (https://vts.apps-crc.testing/app1-team) and the
 *   vts_lrvtc.h compatibility header.
 *
 * Supported Protocols:
 *   - Web - HTTP/HTML
 *   - Web Services
 *   - Any multi-protocol script with Web engine enabled
 *
 * Prerequisites:
 *   1. hosts file contains: "<Ingress-IP> vts.apps-crc.testing"
 *   2. "vts_lrvtc.h" is placed in the script folder next to globals.h
 *   3. globals.h contains: #include "vts_lrvtc.h"
 * ==============================================================================
 */

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
    // Server syntax: "<domain>/<team-subpath>"
    // Port: 8888 (Default Table) or 2000-2018 (Custom Tables)
    rc = lrvtc_connect("vts.apps-crc.testing/app1-team", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS app1-team pod! Aborting vuser.");
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
    // Use a static iteration counter for Web HTTP/HTML protocol
    // (Note: lr_get_iteration() is not available in Web HTTP protocol)
    static int current_iteration = 1;

    // -------------------------------------------------------------------------
    // Step A: Query Row Data from VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_01_Query_Customer_Data");

    // lrvtc_query_row fetches row at index (current_iteration) and AUTOMATICALLY
    // populates VuGen parameters: {Customer_Code}, {Account_Num}, {Status}, etc.
    lrvtc_query_row(current_iteration);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);


    // -------------------------------------------------------------------------
    // Step B: Target Application Business Flow (Simulated)
    // -------------------------------------------------------------------------
    // Best practice: Perform target application requests in separate transactions
    // so VTS data fetch latency does not inflate application response times.
    lr_think_time(1);


    // -------------------------------------------------------------------------
    // Step C: Update Status in VTS to Flag Record as Processed
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_02_Update_Status");

    // lrvtc_update_message updates the Status column for row current_iteration
    lrvtc_update_message("Status", current_iteration, "PROCESSED_BY_WINDOWS_VUGEN");

    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_BY_WINDOWS_VUGEN'", current_iteration);

    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);


    // -------------------------------------------------------------------------
    // Step D: Increment iteration counter for subsequent passes
    // -------------------------------------------------------------------------
    current_iteration++;

    return 0;
}

// ==============================================================================
// 3. vuser_end: Clean Disconnect from VTS
// ==============================================================================
int vuser_end()
{
    lrvtc_disconnect();
    lr_output_message(">>> [VTS] Session closed cleanly.");
    return 0;
}
