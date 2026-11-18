/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - Domain-Based VTS Test Script (All-In-One Single File)
 * ==============================================================================
 * Description:
 *   Complete, self-contained single-file LoadRunner script demonstrating
 *   integration with containerized OpenText VTS 26.1 deployed on OpenShift
 *   using Domain-Based Multi-Tenancy (https://vts-app1.apps-crc.testing).
 *
 * Supported Protocols:
 *   - Web - HTTP/HTML
 *   - Web Services
 *   - Any multi-protocol script with Web engine enabled
 *
 * Prerequisites:
 *   1. hosts file contains: "<Ingress-IP> vts-app1.apps-crc.testing vts-app2.apps-crc.testing"
 *   2. vts_lrvtc.h is present in the VuGen script directory
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

    // --------------------------------------------------------------------------
    // TARGET SELECTION:
    // Option A: Default Table Instance on App1 Team (Port 8888)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);
    //
    // Option B: Multi-Instance Table on App1 Team (e.g. Instance_1 on Port 2000)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 2000, 0);
    //
    // Option C: Default Table Instance on App2 Team (Port 8888)
    //   rc = lrvtc_connect("vts-app2.apps-crc.testing", 8888, 0);
    // --------------------------------------------------------------------------

    lr_output_message("[VTS] Connecting to https://vts-app1.apps-crc.testing (Instance Port 8888)...");

    rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS vts-app1! Return code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS vts-app1!");
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

    // lrvtc_query_row fetches row at index current_iteration
    // It dynamically registers parameters matching the table's column names
    lrvtc_query_row(current_iteration);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Region        : %s", current_iteration, lr_eval_string("{Region}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);

    // Simulated business flow think time
    lr_think_time(1);

    // -------------------------------------------------------------------------
    // Transaction 2: Update Status in VTS
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_02_Update_Status");

    // lrvtc_update_message updates the Status column on row current_iteration
    lrvtc_update_message("Status", current_iteration, "PROCESSED_DOMAIN_BASED");

    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_DOMAIN_BASED'", current_iteration);

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
