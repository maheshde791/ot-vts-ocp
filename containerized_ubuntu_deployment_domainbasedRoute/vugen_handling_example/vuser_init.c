/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - vuser_init.c (Domain-Based Routing)
 * ==============================================================================
 * Connects to containerized OpenText VTS 26.1 via OpenShift Domain Route (Port 443)
 * using the drop-in compatibility header vts_lrvtc.h.
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"
#include "vts_lrvtc.h"

int vuser_init()
{
    int rc;

    // --------------------------------------------------------------------------
    // TARGET INSTANCE SELECTION:
    // Option A: Default Table Instance (Port 8888)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);
    //
    // Option B: Multi-Instance Table (e.g. Instance_1 on Port 2000)
    //   rc = lrvtc_connect("vts-app1.apps-crc.testing", 2000, 0);
    //
    // Option C: App 2 Team Domain (Port 8888)
    //   rc = lrvtc_connect("vts-app2.apps-crc.testing", 8888, 0);
    // --------------------------------------------------------------------------

    lr_output_message("[VTS] Connecting to https://vts-app1.apps-crc.testing (Port 8888)...");

    rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS! Return code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS via domain-based route!");
    return 0;
}
