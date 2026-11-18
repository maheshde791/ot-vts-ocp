#!/usr/bin/env bash
# ==============================================================================
# deploy_vts_app.sh - Automated Deployment Script for Domain-Based OpenText VTS
# ==============================================================================
# Purpose:
#   Deploys single-pod stateful OpenText VTS 26.1 for app1-team, app2-team, or both
#   on Red Hat OpenShift / CRC using Domain-Based Multi-Tenancy:
#     - App1 Team: https://vts-app1.apps-crc.testing/
#     - App2 Team: https://vts-app2.apps-crc.testing/
#
# Usage:
#   ./deploy_vts_app.sh [app1|app2|all] (default: all)
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="lre-vts"
TARGET="${1:-all}"
CERT_FILE="${SCRIPT_DIR}/certs/vts-backend-ca.crt"

deploy_team() {
    local TEAM_ID="$1"
    local APP_NAME="vts-${TEAM_ID}-team"
    local SERVICE_NAME="vts-${TEAM_ID}-team-service"
    local ROUTE_NAME="vts-${TEAM_ID}-team-route"
    local ROUTE_HOST="vts-${TEAM_ID}.apps-crc.testing"
    local PVC_FILE="${SCRIPT_DIR}/vts-pvc.yaml"
    local CM_FILE="${SCRIPT_DIR}/vts-configmap.yaml"
    local DEP_FILE="${SCRIPT_DIR}/vts-deployment.yaml"
    local SVC_FILE="${SCRIPT_DIR}/vts-service.yaml"

    if [ "${TEAM_ID}" == "app2" ]; then
        PVC_FILE="${SCRIPT_DIR}/vts-app2-pvc.yaml"
        CM_FILE="${SCRIPT_DIR}/vts-app2-configmap.yaml"
        DEP_FILE="${SCRIPT_DIR}/vts-app2-deployment.yaml"
        SVC_FILE="${SCRIPT_DIR}/vts-app2-service.yaml"
    fi

    echo -e "\n${CYAN}==============================================================================${NC}"
    echo -e "${CYAN}   Deploying OpenText VTS 26.1 Domain-Based: ${ROUTE_HOST}                  ${NC}"
    echo -e "${CYAN}==============================================================================${NC}"

    echo -e "${YELLOW}  -> Applying Persistent Volume Claim (${PVC_FILE##*/})...${NC}"
    oc apply -f "${PVC_FILE}" -n "${NAMESPACE}"

    echo -e "${YELLOW}  -> Applying ConfigMap (${CM_FILE##*/})...${NC}"
    oc apply -f "${CM_FILE}" -n "${NAMESPACE}"

    echo -e "${YELLOW}  -> Applying Deployment (${DEP_FILE##*/})...${NC}"
    oc apply -f "${DEP_FILE}" -n "${NAMESPACE}"

    echo -e "${YELLOW}  -> Applying Service (${SVC_FILE##*/})...${NC}"
    oc apply -f "${SVC_FILE}" -n "${NAMESPACE}"

    echo -e "${YELLOW}  -> Configuring OpenShift Re-encrypt Route (${ROUTE_HOST})...${NC}"
    if oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        oc delete route "${ROUTE_NAME}" -n "${NAMESPACE}" --wait=true
    fi

    if [ -f "${CERT_FILE}" ]; then
        echo -e "  -> Applying route with backend CA certificate: ${GREEN}${CERT_FILE}${NC}"
        oc create route reencrypt "${ROUTE_NAME}" \
            --service="${SERVICE_NAME}" \
            --port=https-web \
            --dest-ca-cert="${CERT_FILE}" \
            --hostname="${ROUTE_HOST}" \
            --insecure-policy=Redirect \
            -n "${NAMESPACE}"
    else
        oc create route reencrypt "${ROUTE_NAME}" \
            --service="${SERVICE_NAME}" \
            --port=https-web \
            --hostname="${ROUTE_HOST}" \
            --insecure-policy=Redirect \
            -n "${NAMESPACE}"
    fi

    echo -e "${YELLOW}  -> Waiting for Deployment rollout...${NC}"
    oc rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s
    local POD_NAME=$(oc get pod -n "${NAMESPACE}" -l app="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}')
    echo -e "${GREEN}SUCCESS: ${APP_NAME} is Running on Pod: ${POD_NAME}${NC}"
}

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${CYAN}   OpenText VTS 26.1 Containerized Domain-Based Multi-Tenancy Deployer       ${NC}"
echo -e "${CYAN}==============================================================================${NC}"

# Check oc CLI
if ! command -v oc &>/dev/null; then
    if command -v crc &>/dev/null; then
        eval "$(crc oc-env)"
    else
        echo -e "${RED}ERROR: 'oc' CLI not found.${NC}"
        exit 1
    fi
fi

# Ensure namespace
if ! oc get project "${NAMESPACE}" &>/dev/null; then
    oc new-project "${NAMESPACE}"
else
    oc project "${NAMESPACE}" >/dev/null
fi

case "${TARGET}" in
    app1)
        deploy_team "app1"
        ;;
    app2)
        deploy_team "app2"
        ;;
    all)
        deploy_team "app1"
        deploy_team "app2"
        ;;
    *)
        echo -e "${RED}Invalid target: ${TARGET}. Use app1, app2, or all.${NC}"
        exit 1
        ;;
esac

echo -e "\n${CYAN}==============================================================================${NC}"
echo -e "${GREEN}                  DEPLOYMENT SUMMARY & VERIFICATION                           ${NC}"
echo -e "${CYAN}==============================================================================${NC}"
oc get pvc,deployment,svc,route -n "${NAMESPACE}"
echo -e "\n${GREEN}Access URLs:${NC}"
echo -e "  - App1 Team: ${CYAN}https://vts-app1.apps-crc.testing/${NC}"
echo -e "  - App2 Team: ${CYAN}https://vts-app2.apps-crc.testing/${NC}"
echo -e "${CYAN}==============================================================================${NC}"
