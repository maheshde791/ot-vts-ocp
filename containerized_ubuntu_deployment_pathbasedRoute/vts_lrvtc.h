#ifndef _VTS_LRVTC_H_
#define _VTS_LRVTC_H_

/*
 * ==============================================================================
 * OpenText LoadRunner VuGen Compatibility Header: vts_lrvtc.h
 * ==============================================================================
 * Purpose:
 *   Enables LoadRunner performance testing scripts to communicate with
 *   containerized multi-tenant OpenText VTS instances using native lrvtc_* method
 *   syntax (lrvtc_connect, lrvtc_query_row, lrvtc_update_message, etc.)
 *   with ZERO changes to existing script business logic in Action.c.
 *
 * Supported Protocols & Runtimes:
 *   - VuGen Web (HTTP/HTML)
 *   - VuGen TruClient
 *   - LoadRunner Enterprise / Professional Load Generators (Windows & Linux)
 *
 * Security & Network Handling:
 *   - Automatically passes Basic Authentication header (vtsadmin:*****)
 *   - Supports HTTPS/TLS 1.2 on port 443 with Ingress path prefixes (/app1-team, /app2-team)
 *   - Automatically parses JSON responses and populates VuGen parameters:
 *       lrvtc_query_row(1) -> creates {Customer_Code}, {Status}, {Txn_Amount}, etc.
 * ==============================================================================
 */

#include "lrun.h"
#include "web_api.h"
#include "lrw_custom_body.h"

// Connection state storage
static char _vts_base_url[300] = "";
static char _vts_auth_hdr[256] = "Basic dnRzYWRtaW46KioqKio="; // vtsadmin:*****
static int  _vts_port = 8888;
static int  _vts_connected = 0;
static char _vts_cols[60][64];
static int  _vts_col_count = 0;

/*
 * ------------------------------------------------------------------------------
 * lrvtc_connect
 * ------------------------------------------------------------------------------
 * Connects to the VTS pod and discovers column names for automatic parameterization.
 * Server argument can be:
 *   - "vts.apps-crc.testing/app1-team" (Path-based OpenShift Ingress)
 *   - "https://vts.apps-crc.testing/app2-team" (Full URL format)
 *   - "app1-team" (Short name, defaults to https://vts.apps-crc.testing/<name>)
 */
int lrvtc_connect(char *server, int port, int options) {
    char url[350];
    char temp_str[128];
    int i;

    _vts_port = (port > 0) ? port : 8888;

    if (strstr(server, "http://") != NULL || strstr(server, "https://") != NULL) {
        sprintf(_vts_base_url, "%s", server);
    } else if (strchr(server, '/') != NULL) {
        sprintf(_vts_base_url, "https://%s", server);
    } else {
        sprintf(_vts_base_url, "https://vts.apps-crc.testing/%s", server);
    }

    lr_output_message("[VTS] Connecting to %s (Instance Port %d)...", _vts_base_url, _vts_port);

    web_set_sockets_option("SSL_VERSION", "TLS1.2");
    web_add_auto_header("Authorization", _vts_auth_hdr);
    web_add_auto_header("Content-Type", "application/json");

    // Fetch column schema for automatic VuGen parameter creation
    sprintf(url, "%s/proxy/%d/client_api/getAllColumns", _vts_base_url, _vts_port);

    web_reg_save_param_json(
        "ParamName=VTS_SchemaCols",
        "QueryString=$[*]",
        "SelectAll=Yes",
        "NotFound=Warning",
        LAST);

    web_custom_request("VTS_Connect_Init",
        "URL={url}",
        "Method=POST",
        "Body={}",
        LAST);

    _vts_col_count = atoi(lr_eval_string("{VTS_SchemaCols_count}"));
    if (_vts_col_count > 0) {
        for (i = 1; i <= _vts_col_count && i <= 60; i++) {
            sprintf(temp_str, "{VTS_SchemaCols_%d}", i);
            strcpy(_vts_cols[i - 1], lr_eval_string(temp_str));
        }
        _vts_connected = 1;
        lr_output_message("[VTS] Successfully connected! Discovered %d columns.", _vts_col_count);
        return 0;
    }

    lr_error_message("[VTS] Connection failed: unable to fetch table columns from %s", url);
    _vts_connected = 0;
    return -1;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_query_row
 * ------------------------------------------------------------------------------
 * Fetches the entire row at row_num and automatically populates {ColumnName}
 * parameters for every column discovered during connection.
 */
int lrvtc_query_row(int row_num) {
    char url[350];
    char body[128];
    char reg_expr[128];
    char query_expr[64];
    int i;

    if (!_vts_connected) {
        lr_error_message("[VTS] Cannot query row: VTS connection is not active.");
        return -1;
    }

    sprintf(url, "%s/proxy/%d/client_api/getTable", _vts_base_url, _vts_port);
    sprintf(body, "{\"start\":%d,\"end\":%d}", row_num, row_num);

    // Register correlation for each column
    for (i = 0; i < _vts_col_count; i++) {
        sprintf(reg_expr, "ParamName=%s", _vts_cols[i]);
        sprintf(query_expr, "QueryString=$[0][%d]", i);
        web_reg_save_param_json(
            reg_expr,
            query_expr,
            "NotFound=Warning",
            LAST);
    }

    web_custom_request("VTS_QueryRow",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_query_column
 * ------------------------------------------------------------------------------
 * Fetches a single cell at row_num and saves it into parameter {col_name}.
 */
int lrvtc_query_column(char *col_name, int row_num) {
    char url[350];
    char body[128];
    char reg_expr[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/getColumnRange", _vts_base_url, _vts_port);
    sprintf(body, "{\"column\":\"%s\",\"start\":%d,\"end\":%d}", col_name, row_num, row_num);
    sprintf(reg_expr, "ParamName=%s", col_name);

    web_reg_save_param_json(
        reg_expr,
        "QueryString=$[0]",
        "NotFound=Warning",
        LAST);

    web_custom_request("VTS_QueryColumn",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_update_message
 * ------------------------------------------------------------------------------
 * Updates a cell at row_num for the specified column.
 */
int lrvtc_update_message(char *col_name, int row_num, char *val) {
    char url[350];
    char body[512];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/update", _vts_base_url, _vts_port);
    sprintf(body, "{\"index\":%d,\"column\":\"%s\",\"value\":\"%s\"}", row_num, col_name, val);

    web_custom_request("VTS_UpdateMessage",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_retrieve_message
 * ------------------------------------------------------------------------------
 * Pops the top value of col_name (FIFO) and saves it into parameter {col_name}.
 */
int lrvtc_retrieve_message(char *col_name) {
    char url[350];
    char body[128];
    char reg_expr[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/retrieve", _vts_base_url, _vts_port);
    sprintf(body, "{\"columns\":[\"%s\"],\"condition\":0}", col_name);
    sprintf(reg_expr, "ParamName=%s", col_name);

    web_reg_save_param_json(
        reg_expr,
        "QueryString=$[0]",
        "NotFound=Warning",
        LAST);

    web_custom_request("VTS_RetrieveMessage",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_send_message
 * ------------------------------------------------------------------------------
 * Appends a new value to the specified column at the bottom of the table.
 */
int lrvtc_send_message(char *col_name, char *val, int index) {
    char url[350];
    char body[512];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/add", _vts_base_url, _vts_port);
    sprintf(body, "{\"option\":0,\"new\":{\"%s\":\"%s\"}}", col_name, val);

    web_custom_request("VTS_SendMessage",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_clear_column
 * ------------------------------------------------------------------------------
 * Clears all data within the specified column.
 */
int lrvtc_clear_column(char *col_name) {
    char url[350];
    char body[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/clearColumn", _vts_base_url, _vts_port);
    sprintf(body, "{\"start\":1,\"columns\":[\"%s\"]}", col_name);

    web_custom_request("VTS_ClearColumn",
        "URL={url}",
        "Method=POST",
        "Body={body}",
        LAST);

    return 0;
}

/*
 * ------------------------------------------------------------------------------
 * lrvtc_disconnect
 * ------------------------------------------------------------------------------
 * Cleans up session and resets connection state.
 */
void lrvtc_disconnect() {
    _vts_connected = 0;
    _vts_col_count = 0;
    lr_output_message("[VTS] Disconnected from %s", _vts_base_url);
}

#endif // _VTS_LRVTC_H_
