/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - vuser_end.c (Domain-Based Routing)
 * ==============================================================================
 * Cleanly disconnects the VTS session at the conclusion of the test run.
 * ==============================================================================
 */

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
