#ifndef _VTS_LRVTC_H_
#define _VTS_LRVTC_H_

/*
 * ==============================================================================
 * OpenText LoadRunner VuGen Compatibility Header: vts_lrvtc.h
 * ==============================================================================
 * Purpose:
 *   Enables LoadRunner scripts to communicate with containerized multi-tenant
 *   OpenText VTS instances using native lrvtc_* method syntax with ZERO changes
 *   to script code in Action.c, vuser_init.c, and vuser_end.c.
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

int vts_wrap_connect(char *server, int port, int options) {
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

    sprintf(url, "%s/proxy/%d/client_api/getAllColumns", _vts_base_url, _vts_port);
    lr_save_string(url, "VTS_ReqUrl");

    web_reg_save_param_json(
        "ParamName=VTS_SchemaCols",
        "QueryString=$[*]",
        "SelectAll=Yes",
        "NotFound=Warning",
        LAST);

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_Connect_Init",
        "URL={VTS_ReqUrl}",
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
        lr_output_message("[VTS] Connected successfully! Discovered %d columns.", _vts_col_count);
        return 0;
    }

    lr_error_message("[VTS] Connection failed: unable to fetch table columns from %s", url);
    _vts_connected = 0;
    return -1;
}

int vts_wrap_query_row(int row_num) {
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
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    for (i = 0; i < _vts_col_count; i++) {
        sprintf(reg_expr, "ParamName=%s", _vts_cols[i]);
        sprintf(query_expr, "QueryString=$[0][%d]", i);
        web_reg_save_param_json(
            reg_expr,
            query_expr,
            "NotFound=Warning",
            LAST);
    }

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_QueryRow",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_query_column(char *col_name, int row_num) {
    char url[350];
    char body[128];
    char reg_expr[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/getColumnRange", _vts_base_url, _vts_port);
    sprintf(body, "{\"column\":\"%s\",\"start\":%d,\"end\":%d}", col_name, row_num, row_num);
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    sprintf(reg_expr, "ParamName=%s", col_name);
    web_reg_save_param_json(
        reg_expr,
        "QueryString=$[0]",
        "NotFound=Warning",
        LAST);

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_QueryColumn",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_update_message(char *col_name, int row_num, char *val) {
    char url[350];
    char body[512];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/update", _vts_base_url, _vts_port);
    sprintf(body, "{\"index\":%d,\"column\":\"%s\",\"value\":\"%s\"}", row_num, col_name, val);
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_UpdateMessage",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_retrieve_message(char *col_name) {
    char url[350];
    char body[128];
    char reg_expr[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/retrieve", _vts_base_url, _vts_port);
    sprintf(body, "{\"columns\":[\"%s\"],\"condition\":0}", col_name);
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    sprintf(reg_expr, "ParamName=%s", col_name);
    web_reg_save_param_json(
        reg_expr,
        "QueryString=$[0]",
        "NotFound=Warning",
        LAST);

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_RetrieveMessage",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_send_message(char *col_name, char *val, int index) {
    char url[350];
    char body[512];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/add", _vts_base_url, _vts_port);
    sprintf(body, "{\"option\":0,\"new\":{\"%s\":\"%s\"}}", col_name, val);
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_SendMessage",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_clear_column(char *col_name) {
    char url[350];
    char body[128];

    if (!_vts_connected) return -1;

    sprintf(url, "%s/proxy/%d/client_api/clearColumn", _vts_base_url, _vts_port);
    sprintf(body, "{\"start\":1,\"columns\":[\"%s\"]}", col_name);
    lr_save_string(url, "VTS_ReqUrl");
    lr_save_string(body, "VTS_ReqBody");

    web_add_header("Authorization", _vts_auth_hdr);
    web_add_header("Content-Type", "application/json");

    web_custom_request("VTS_ClearColumn",
        "URL={VTS_ReqUrl}",
        "Method=POST",
        "Body={VTS_ReqBody}",
        LAST);

    return 0;
}

int vts_wrap_disconnect() {
    _vts_connected = 0;
    _vts_col_count = 0;
    lr_output_message("[VTS] Disconnected cleanly.");
    return 0;
}

// -----------------------------------------------------------------------------
// Preprocessor macro aliases: Map standard lrvtc_* calls to our wrapper
// -----------------------------------------------------------------------------
#undef lrvtc_connect
#undef lrvtc_disconnect
#undef lrvtc_query_row
#undef lrvtc_query_column
#undef lrvtc_update_message
#undef lrvtc_retrieve_message
#undef lrvtc_send_message
#undef lrvtc_clear_column

#define lrvtc_connect          vts_wrap_connect
#define lrvtc_disconnect       vts_wrap_disconnect
#define lrvtc_query_row        vts_wrap_query_row
#define lrvtc_query_column     vts_wrap_query_column
#define lrvtc_update_message   vts_wrap_update_message
#define lrvtc_retrieve_message vts_wrap_retrieve_message
#define lrvtc_send_message     vts_wrap_send_message
#define lrvtc_clear_column     vts_wrap_clear_column

#endif // _VTS_LRVTC_H_
