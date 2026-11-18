/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - Action.c (Domain-Based Routing)
 * ==============================================================================
 * Demonstrates standard, native-style lrvtc_* method calls:
 *   1. lrvtc_query_row()      - queries all columns at current iteration
 *   2. lr_eval_string()       - reads populated column parameters
 *   3. lrvtc_update_message() - updates cell status in real-time
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

int Action()
{
    // Use static iteration counter for Web HTTP protocol
    static int current_iteration = 1;

    // -------------------------------------------------------------------------
    // Transaction 1: Fetch Row Data from VTS Table
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_01_Query_Customer_Data");

    // lrvtc_query_row automatically populates parameter names matching VTS column headers
    lrvtc_query_row(current_iteration);

    lr_output_message(">>> [ROW %d] Customer Code : %s", current_iteration, lr_eval_string("{Customer_Code}"));
    lr_output_message(">>> [ROW %d] Account Num   : %s", current_iteration, lr_eval_string("{Account_Num}"));
    lr_output_message(">>> [ROW %d] Region        : %s", current_iteration, lr_eval_string("{Region}"));
    lr_output_message(">>> [ROW %d] Current Status: %s", current_iteration, lr_eval_string("{Status}"));

    lr_end_transaction("VTS_01_Query_Customer_Data", LR_AUTO);

    // Simulated business flow think-time
    lr_think_time(1);

    // -------------------------------------------------------------------------
    // Transaction 2: Update Status Column in VTS Table
    // -------------------------------------------------------------------------
    lr_start_transaction("VTS_02_Update_Status");

    // Update Status column on row current_iteration
    lrvtc_update_message("Status", current_iteration, "PROCESSED_DOMAIN_BASED");

    lr_output_message(">>> [ROW %d] Updated Status to 'PROCESSED_DOMAIN_BASED'", current_iteration);

    lr_end_transaction("VTS_02_Update_Status", LR_AUTO);

    // Increment iteration counter for subsequent passes
    current_iteration++;

    return 0;
}
