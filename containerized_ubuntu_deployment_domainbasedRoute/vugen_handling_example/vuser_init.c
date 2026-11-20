/*
 * ==============================================================================
 * OpenText VuGen 2026.1 - vuser_init.c (Domain-Based Routing)
 * ==============================================================================
 * Demonstrates connection to containerized OpenText VTS 26.1 over HTTPS 443.
 *
 * OPTION 1 (RECOMMENDED / ENTERPRISE STANDARD):
 *   Uses native OpenText lrvtc_connect_ex with Runtime Settings query string.
 *   Requires ZERO custom headers!
 *   Setup: Runtime Settings (F4) -> General -> Miscellaneous -> VTS
 *          -> Check "Access VTS port by query string" -> Set Port: 443
 *
 * OPTION 2 (FALLBACK / LEAST PREFERRED):
 *   Uses custom compatibility header (vts_lrvtc.h) with standard lrvtc_connect.
 *   Uncomment "#include \"vts_lrvtc.h\"" and the Option 2 block below.
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"

// ------------------------------------------------------------------------------
// For Option 2 only: Uncomment the line below to use the custom wrapper header
// #include "vts_lrvtc.h"
// ------------------------------------------------------------------------------

int vuser_init()
{
    int rc;

    // ==========================================================================
    // OPTION 1 (RECOMMENDED): Native OpenText lrvtc_connect_ex
    // ==========================================================================
    lr_output_message("[VTS] Connecting natively via lrvtc_connect_ex (Port 8888)...");

    rc = lrvtc_connect_ex(
        "Server=https://vts-app1.apps-crc.testing",
        "Port=8888",
        "UserName=vtsadmin",
        "Password=*****",
        LAST);

    /*
     * For secondary multi-instance table (e.g. Instance_1 on Port 2001):
     * rc = lrvtc_connect_ex("Server=https://vts-app1.apps-crc.testing", "Port=2001", "UserName=vtsadmin", "Password=*****", LAST);
     *
     * For App 2 Team:
     * rc = lrvtc_connect_ex("Server=https://vts-app2.apps-crc.testing", "Port=8888", "UserName=vtsadmin", "Password=*****", LAST);
     */

    // ==========================================================================
    // OPTION 2 (FALLBACK): Custom Header Wrapper (vts_lrvtc.h)
    // ==========================================================================
    /*
    lr_output_message("[VTS] Connecting via custom header wrapper (Port 8888)...");
    rc = lrvtc_connect("vts-app1.apps-crc.testing", 8888, 0);
    */

    if (rc != 0) {
        lr_error_message(">>> [FATAL] Failed to connect to VTS! Return code: %d", rc);
        return -1;
    }

    lr_output_message(">>> [SUCCESS] Connected cleanly to VTS via domain-based route!");
    return 0;
}
