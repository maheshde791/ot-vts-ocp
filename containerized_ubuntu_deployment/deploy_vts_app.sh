#!/usr/bin/env bash
# ==============================================================================
# deploy_vts_app.sh - Automated Deployment Script for Containerized OpenText VTS
# ==============================================================================
# Purpose:
#   Deploys single-pod stateful OpenText VTS 26.1 for app1-team on Red Hat OpenShift / CRC.
#
# Key Architectural Features:
#   1. In-Container NGINX Reverse Proxy (Port 8443 SSL HTTP/2)
#   2. Dynamic Path-Stripping for Enterprise Ingress (/app1-team -> /)
#   3. Multi-Instance Query-String Port Forwarding (?portnumber=4000, 8888, 2000-2050)
#   4. End-to-End TLS Re-encryption & Enterprise Certificate Architecture:
#      - In Enterprise Production: The SAME Enterprise SSL certificate & private key
#        (Wildcard *.corp or Multi-SAN vts-cloud.corp) is configured on:
#          a) The Cloud Application Gateway / Load Balancer (Port 443 external entry)
#          b) The In-Container NGINX reverse-proxy inside both app1 and app2 pods (Port 8443)
#      - Zero Certificate Storage in Git: Certificates and private keys are NEVER committed
#        to the code repository. They are retrieved dynamically at deploy time from the
#        Enterprise Password Vault / PAM (e.g. Key Vault / PAM) onto the runner/bastion.
#      - For Re-encryption validation: The Application Gateway / OpenShift Route validates
#        the pod's backend TLS certificate using the Enterprise Internal Root/Intermediate CA.
#   5. Persistent Volume Claim (PVC) with non-destructive self-healing instances.json
# ==============================================================================

set -euo pipefail

# Color formatting for readable CLI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="lre-vts"
APP_NAME="vts-app1-team"
SERVICE_NAME="vts-app1-team-service"
ROUTE_NAME="vts-app1-team-route"
ROUTE_HOST="vts.apps-crc.testing"
ROUTE_PATH="/app1-team"

# Local certificate path for validation/POC (ignored by git):
# In production CI/CD pipelines, this file is populated dynamically from Enterprise Vault / PAM.
CERT_FILE="${SCRIPT_DIR}/certs/vts-backend-ca.crt"

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${CYAN}        Deploying Containerized OpenText VTS 26.1 (app1-team)                 ${NC}"
echo -e "${CYAN}==============================================================================${NC}"

# ------------------------------------------------------------------------------
# Step 1: Pre-flight Verification & Environment Setup
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/7] Checking environment and OpenShift CLI...${NC}"

if ! command -v oc &>/dev/null; then
    echo -e "  -> Configuring oc environment from crc..."
    if command -v crc &>/dev/null; then
        eval "$(crc oc-env)"
    else
        echo -e "${RED}ERROR: 'oc' CLI not found and 'crc' is not in PATH.${NC}"
        exit 1
    fi
fi

# Ensure Target Namespace Exists
echo -e "\n${YELLOW}[2/7] Ensuring namespace '${NAMESPACE}' exists...${NC}"
if ! oc get project "${NAMESPACE}" &>/dev/null; then
    echo -e "  -> Creating project '${NAMESPACE}'..."
    oc new-project "${NAMESPACE}"
else
    echo -e "  -> Project '${NAMESPACE}' already active."
    oc project "${NAMESPACE}" >/dev/null
fi

# ------------------------------------------------------------------------------
# Step 2: Apply Persistent Volume Claim (PVC)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/7] Applying Persistent Volume Claim (vts-pvc.yaml)...${NC}"
oc apply -f "${SCRIPT_DIR}/vts-pvc.yaml" -n "${NAMESPACE}"

# ------------------------------------------------------------------------------
# Step 3: Apply ConfigMap (configure.json + NGINX reverse-proxy configuration)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/7] Applying ConfigMap (vts-configmap.yaml)...${NC}"
oc apply -f "${SCRIPT_DIR}/vts-configmap.yaml" -n "${NAMESPACE}"

# ------------------------------------------------------------------------------
# Step 4: Apply Deployment (Single-Pod Stateful VTS 26.1)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[5/7] Applying Deployment (vts-deployment.yaml)...${NC}"
oc apply -f "${SCRIPT_DIR}/vts-deployment.yaml" -n "${NAMESPACE}"

# ------------------------------------------------------------------------------
# Step 5: Apply Internal ClusterIP Service (Port 443 -> 8443)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[6/7] Applying Service (vts-service.yaml)...${NC}"
oc apply -f "${SCRIPT_DIR}/vts-service.yaml" -n "${NAMESPACE}"

# ------------------------------------------------------------------------------
# Step 6: Create / Update Route with Enterprise Certificate (Vault Pattern)
# ------------------------------------------------------------------------------
# ARCHITECTURAL NOTE ON CERTIFICATES:
# In Enterprise Landing Zones:
#   - The SAME Enterprise SSL certificate & key (e.g. *.corp or vts-cloud.corp) is
#     configured on both the Application Gateway / Ingress Router and in-container NGINX.
#   - Certificates are pulled from Enterprise Password Vault / PAM at deploy time.
#   - Below, --dest-ca-cert supplies the CA that verifies the backend pod's TLS certificate.
#   - If the Enterprise Root CA is already installed cluster-wide or using Service CA,
#     --dest-ca-cert can be omitted.
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[7/7] Configuring OpenShift Re-encrypt Route...${NC}"

# Delete existing route if present so it recreates cleanly
if oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo -e "  -> Removing existing route to apply updated configuration..."
    oc delete route "${ROUTE_NAME}" -n "${NAMESPACE}" --wait=true
fi

if [ -f "${CERT_FILE}" ]; then
    echo -e "  -> Applying route with backend CA certificate: ${GREEN}${CERT_FILE}${NC}"
    oc create route reencrypt "${ROUTE_NAME}" \
        --service="${SERVICE_NAME}" \
        --port=https-web \
        --dest-ca-cert="${CERT_FILE}" \
        --hostname="${ROUTE_HOST}" \
        --path="${ROUTE_PATH}" \
        --insecure-policy=Redirect \
        -n "${NAMESPACE}"
else
    echo -e "  -> Local cert file not found; applying standard re-encrypt route (relying on Cluster / Service CA)..."
    oc create route reencrypt "${ROUTE_NAME}" \
        --service="${SERVICE_NAME}" \
        --port=https-web \
        --hostname="${ROUTE_HOST}" \
        --path="${ROUTE_PATH}" \
        --insecure-policy=Redirect \
        -n "${NAMESPACE}"
fi

# ------------------------------------------------------------------------------
# Step 7: Wait for Rollout & Verify Pod Readiness
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${YELLOW}Waiting for Deployment to reach 1/1 Running state...${NC}"
oc rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s

POD_NAME=$(oc get pod -n "${NAMESPACE}" -l app="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}SUCCESS: Pod is Running: ${POD_NAME}${NC}"

# ------------------------------------------------------------------------------
# Post-Deployment Verification Summary
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}==============================================================================${NC}"
echo -e "${GREEN}                  VTS APP1-TEAM DEPLOYMENT VERIFICATION                       ${NC}"
echo -e "${CYAN}==============================================================================${NC}"

echo -e "\n${YELLOW}Active Resources in '${NAMESPACE}':${NC}"
oc get pvc,deployment,svc,route -n "${NAMESPACE}"

echo -e "\n${YELLOW}Symlink & PVC Data Files:${NC}"
oc exec "${POD_NAME}" -n "${NAMESPACE}" -- ls -la /opt/OT/OT_VTS/web/instances.json
oc exec "${POD_NAME}" -n "${NAMESPACE}" -- ls -la /var/lib/OT/OT_VTS/db/data/

echo -e "\n${YELLOW}Quick Verification Commands:${NC}"
echo -e "  1. Web UI (Admin):"
echo -e "     ${CYAN}curl -k -i -u vtsadmin:***** https://${ROUTE_HOST}${ROUTE_PATH}/${NC}"
echo -e "  2. Default Instance API (Port 8888):"
echo -e "     ${CYAN}curl -k -i -u vtsadmin:***** -X POST \"https://${ROUTE_HOST}${ROUTE_PATH}/?portnumber=8888/client_api/get\" -H \"Content-Type: application/json\" -d '{\"colName\":\"Customer_ID\",\"index\":1}'${NC}"
echo -e "  3. Stream Live Logs:"
echo -e "     ${CYAN}oc logs -n ${NAMESPACE} deployment/${APP_NAME} -f${NC}"
echo -e "${CYAN}==============================================================================${NC}"
