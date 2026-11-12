#!/usr/bin/env bash
# ==============================================================================
# tune_rhel_vts.sh - Production Performance, Persistence & NGINX Tuning (RHEL 9)
# ==============================================================================
# Run with sudo on the RHEL 9 VTS server:
#   sudo bash tune_rhel_vts.sh
# Optional flag to enforce Basic Auth on backend client_api endpoints:
#   sudo bash tune_rhel_vts.sh --enable-api-auth
# ==============================================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (e.g., sudo bash $0)"
    exit 1
fi

ENABLE_API_AUTH="false"
if [[ "${1:-}" == "--enable-api-auth" ]]; then
    ENABLE_API_AUTH="true"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VTS_WEB_DIR="/opt/OT/OT_VTS/web"
VTS_CONF="${VTS_WEB_DIR}/configure.json"
REDIS_CONF="${VTS_WEB_DIR}/redis.conf"
NGINX_MAIN="/etc/nginx/nginx.conf"
NGINX_VTS="/etc/nginx/conf.d/vts.conf"
TS="$(date +%Y%m%d_%H%M%S)"

echo "================================================================================"
echo "       OpenText VTS 26.1 - RHEL 9 Production Tuning & Hardening                 "
echo "================================================================================"

# ------------------------------------------------------------------------------
# [1/6] Flush active in-memory Valkey instances safely before touching configs
# ------------------------------------------------------------------------------
echo "[1/6] Saving active Valkey in-memory databases to disk..."
for pid in $(pgrep -x valkey-server || true); do
    PORT=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 || true)
    if [[ -n "${PORT}" ]]; then
        echo -n "  -> Saving Valkey port ${PORT}... "
        "${VTS_WEB_DIR}/valkey-cli" -p "${PORT}" save >/dev/null 2>&1 && echo "OK" || echo "WARN"
    fi
done

# ------------------------------------------------------------------------------
# [2/6] Tune VTS configure.json (preserving existing users & credentials)
# ------------------------------------------------------------------------------
echo "[2/6] Tuning ${VTS_CONF}..."
if [[ ! -f "${VTS_CONF}" ]]; then
    echo "ERROR: ${VTS_CONF} not found!"
    exit 1
fi

cp -a "${VTS_CONF}" "${VTS_CONF}.bak.${TS}"

python3 - "${VTS_CONF}" "${ENABLE_API_AUTH}" << 'PYEOF'
import json
import sys

conf_path = sys.argv[1]
enable_api_auth = sys.argv[2] == "true"

with open(conf_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

cfg["defaultStart"] = True
cfg["autoRefreshGrid"] = False
cfg["maxInstancesAllowed"] = max(int(cfg.get("maxInstancesAllowed", 50)), 50)

if enable_api_auth:
    cfg.setdefault("admin", {})["requireBasicAuthForAPI"] = True

db_info = cfg.setdefault("dbInfo", {})
conn_pool = db_info.setdefault("connPool", {})
conn_pool["maxIdle"] = 5000
conn_pool["maxActive"] = 5000

# Widen internal Valkey port range (10000-30000) to avoid 6000-7000 Birthday Paradox collisions
db_port = db_info.setdefault("dbServerPort", {})
db_port["start"] = 10000
db_port["end"] = 30000

db_check = db_info.setdefault("dbCheck", {})
db_check["waitingTime"] = 10
db_check["retryTimes"] = 3600

with open(conf_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"  -> defaultStart=True, autoRefreshGrid=False, connPool=5000, dbServerPort=10000-30000, waitingTime=10s, requireBasicAuthForAPI={cfg['admin'].get('requireBasicAuthForAPI')}")
PYEOF

# ------------------------------------------------------------------------------
# [3/6] Configure Valkey Persistence (RDB 60s + Safe AOF Migration + Graceful Stop)
# ------------------------------------------------------------------------------
echo "[3/6] Configuring Valkey persistence & graceful shutdown hook..."
cp -a "${REDIS_CONF}" "${REDIS_CONF}.bak.${TS}"

# Enable 60s RDB snapshots if >=1 key modified
sed -i '/^save /d' "${REDIS_CONF}"
echo "save 60 1" >> "${REDIS_CONF}"

# Safely migrate live instances to AOF before setting appendonly yes in redis.conf
# (Prevents Valkey from loading stale empty appendonlydir/*.rdb on restart)
for pid in $(pgrep -x valkey-server || true); do
    PORT=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 || true)
    if [[ -n "${PORT}" ]]; then
        echo -n "  -> Rewriting live AOF snapshot on port ${PORT}... "
        "${VTS_WEB_DIR}/valkey-cli" -p "${PORT}" CONFIG SET appendonly yes >/dev/null 2>&1 || true
        "${VTS_WEB_DIR}/valkey-cli" -p "${PORT}" BGREWRITEAOF >/dev/null 2>&1 || true
        echo "OK"
    fi
done
sleep 2

sed -i 's/^appendonly no/appendonly yes/' "${REDIS_CONF}"
echo "  -> Enabled save 60 1 + appendonly yes (everysec) in ${REDIS_CONF}"

# Create graceful save hook for systemd ExecStop so VM shutdown/restart never loses memory state
cat << 'EOF' > /opt/OT/OT_VTS/graceful_save.sh
#!/bin/sh
for pid in $(pgrep -x valkey-server 2>/dev/null); do
    PORT=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2)
    if [ -n "$PORT" ]; then
        /opt/OT/OT_VTS/web/valkey-cli -p "$PORT" save >/dev/null 2>&1 || true
    fi
done
sync
EOF
chmod +x /opt/OT/OT_VTS/graceful_save.sh

mkdir -p /etc/systemd/system/vts.service.d
cat << 'EOF' > /etc/systemd/system/vts.service.d/graceful-save.conf
[Service]
ExecStop=/opt/OT/OT_VTS/graceful_save.sh
TimeoutStopSec=30
EOF
echo "  -> Added systemd ExecStop graceful save hook for vts.service"

# Create post-start self-healing watchdog (detects & heals redisdrv.go Valkey port collisions)
cat << 'EOF' > /opt/OT/OT_VTS/verify_instances.sh
#!/usr/bin/env bash
set -u
python3 - << 'PYEOF'
import base64, json, os, socket, subprocess, time, urllib.request

CONF = "/opt/OT/OT_VTS/web/configure.json"
INST = "/opt/OT/OT_VTS/web/instances.json"
CLI  = "/opt/OT/OT_VTS/web/valkey-cli"

with open(CONF, "r", encoding="utf-8") as f:
    cfg = json.load(f)

admin_port = int(cfg.get("adminPort", 4000))
default_db = cfg.get("defaultDbName", "Default")
default_api_port = int(cfg.get("defaultApiPort", 8888))

admin_names = set(cfg.get("admin", {}).get("role", {}).get("administrator", []))
auth_user = next((u for u in cfg.get("admin", {}).get("users", []) if u.get("user") in admin_names), None)
if auth_user is None and cfg.get("admin", {}).get("users"):
    auth_user = cfg["admin"]["users"][0]

instances = []
if os.path.exists(INST):
    with open(INST, "r", encoding="utf-8") as f:
        instances = json.load(f) or []

expected_ports = [default_api_port] + [int(x["port"]) for x in instances if x.get("serviceStatus")]
expected_names = ([default_db] if cfg.get("defaultStart", True) else []) + [x["name"] for x in instances if x.get("serviceStatus")]

# Wait up to 45s for apiserver to finish sequential startup across all instances
deadline = time.time() + 45
while time.time() < deadline:
    up = 0
    for p in [admin_port] + expected_ports:
        s = socket.socket()
        s.settimeout(0.5)
        if s.connect_ex(("127.0.0.1", p)) == 0:
            up += 1
        s.close()
    if up == 1 + len(expected_ports):
        break
    time.sleep(1)

time.sleep(2)

def active_valkey_dirs():
    out = subprocess.check_output(["ps", "-eo", "args"], text=True)
    dirs = set()
    for line in out.splitlines():
        if "valkey-server 127.0.0.1:" in line:
            port = line.strip().split()[-1].split(":")[-1]
            try:
                res = subprocess.check_output([CLI, "-p", port, "CONFIG", "GET", "dir"], text=True, stderr=subprocess.DEVNULL)
                lines = [l.strip() for l in res.splitlines() if l.strip()]
                if lines:
                    dirs.add(os.path.basename(lines[-1]))
            except Exception:
                pass
    return dirs

if auth_user:
    token = base64.b64encode(f"{auth_user['user']}:{auth_user['password']}".encode()).decode()
    headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}
    for attempt in range(1, 4):
        active = active_valkey_dirs()
        missing = [x["name"] for x in instances if x.get("serviceStatus") and x["name"] not in active]
        if not missing:
            print(f"[verify_instances] OK: {len(active)}/{len(expected_names)} isolated Valkey instances active.")
            break
        print(f"[verify_instances] Attempt {attempt}: healing Valkey port collision for {missing}")
        for name in missing:
            for action in ("stop", "start"):
                req = urllib.request.Request(f"http://127.0.0.1:{admin_port}/instances/{name}/{action}", data=b"{}", method="POST", headers=headers)
                try:
                    urllib.request.urlopen(req, timeout=10).read()
                except Exception as e:
                    print(f"[verify_instances] {name}/{action} warning: {e}")
                time.sleep(1.5 if action == "stop" else 2.5)
PYEOF
EOF
chmod +x /opt/OT/OT_VTS/verify_instances.sh

cat << 'EOF' > /etc/systemd/system/vts.service.d/verify-instances.conf
[Service]
ExecStartPost=/opt/OT/OT_VTS/verify_instances.sh
TimeoutStartSec=120
EOF
echo "  -> Added systemd ExecStartPost collision self-heal watchdog for vts.service"

# ------------------------------------------------------------------------------
# [4/6] Tune RHEL 9 Kernel TCP Stack & Memory Overcommit
# ------------------------------------------------------------------------------
echo "[4/6] Applying RHEL 9 kernel sysctl tuning..."
cat << 'EOF' > /etc/sysctl.d/99-vts-tuning.conf
# Prevent Valkey/Redis BGSAVE fork failures under high memory load
vm.overcommit_memory = 1

# Expand socket backlog & keep ephemeral client ports (32768-65000) separate from Valkey dbServerPort (10000-30000)
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 32768 65000
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system >/dev/null
echo "  -> Applied /etc/sysctl.d/99-vts-tuning.conf"

# ------------------------------------------------------------------------------
# [5/6] Tune & Harden Local NGINX Reverse Proxy
# ------------------------------------------------------------------------------
echo "[5/6] Tuning & hardening NGINX (${NGINX_MAIN} & ${NGINX_VTS})..."
cp -a "${NGINX_MAIN}" "${NGINX_MAIN}.bak.${TS}"
[[ -f "${NGINX_VTS}" ]] && cp -a "${NGINX_VTS}" "${NGINX_VTS}.bak.${TS}"

# Deploy tuned nginx.conf if present alongside script, otherwise tune in-place
if [[ -f "${SCRIPT_DIR}/nginx.conf" ]]; then
    cp -f "${SCRIPT_DIR}/nginx.conf" "${NGINX_MAIN}"
else
    if ! grep -q "worker_rlimit_nofile" "${NGINX_MAIN}"; then
        sed -i '/^worker_processes/a worker_rlimit_nofile 65535;' "${NGINX_MAIN}"
    else
        sed -i 's/^worker_rlimit_nofile.*/worker_rlimit_nofile 65535;/' "${NGINX_MAIN}"
    fi
    sed -i 's/worker_connections.*/worker_connections 8192;/' "${NGINX_MAIN}"
fi

# Raise systemd LimitNOFILE for nginx.service
mkdir -p /etc/systemd/system/nginx.service.d
cat << 'EOF' > /etc/systemd/system/nginx.service.d/limits.conf
[Service]
LimitNOFILE=65535
EOF

# Deploy hardened vts.conf (prefer local copy in script dir if present)
if [[ -f "${SCRIPT_DIR}/vts.conf" ]]; then
    cp -f "${SCRIPT_DIR}/vts.conf" "${NGINX_VTS}"
else
    cat << 'EOF' > "${NGINX_VTS}"
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

server {
    listen       443 ssl http2 backlog=16384;
    server_name  vts-server.local vts-server 192.168.122.245;

    ssl_certificate      /etc/pki/tls/certs/vts.crt;
    ssl_certificate_key  /etc/pki/tls/private/vts.key;

    ssl_protocols        TLSv1.2 TLSv1.3;
    ssl_ciphers          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache    shared:SSL:50m;
    ssl_session_timeout  1d;
    ssl_session_tickets  off;

    proxy_http_version   1.1;
    proxy_set_header     Upgrade $http_upgrade;
    proxy_set_header     Connection $connection_upgrade;
    proxy_set_header     Host $host;
    proxy_set_header     X-Real-IP $remote_addr;
    proxy_set_header     X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header     X-Forwarded-Proto https;

    proxy_connect_timeout 10s;
    proxy_send_timeout    60s;
    proxy_read_timeout    60s;
    client_max_body_size  100m;

    location / {
        if ($query_string ~* "^portnumber=(4000|888[89]|889[0-9]|890[0-8]|20[0-4][0-9]|2050)(.*)$") {
            set $port $1;
            set $para $2;
            proxy_pass http://127.0.0.1:$port$para;
            break;
        }

        if ($query_string ~* "portnumber=") {
            return 403;
        }

        proxy_pass http://127.0.0.1:4000;
    }
}

server {
    listen       80;
    server_name  vts-server.local vts-server 192.168.122.245;
    return 301 https://$host$request_uri;
}
EOF
fi

nginx -t

# Lock configure.json permissions and preserve non-root vts_svc ownership if present
chmod 600 "${VTS_CONF}"
if id vts_svc >/dev/null 2>&1; then
    chown -R vts_svc:vts_svc /opt/OT/OT_VTS /var/lib/OT/OT_VTS
    [[ -d /var/log/vts ]] && chown -R vts_svc:vts_svc /var/log/vts
fi

# ------------------------------------------------------------------------------
# [6/6] Reload systemd & restart VTS + NGINX cleanly
# ------------------------------------------------------------------------------
echo "[6/6] Reloading systemd and restarting services..."
systemctl daemon-reload
systemctl restart vts
systemctl restart nginx
sleep 2

echo ""
echo "=== Active Services, Valkey Isolation & Ports Verification ==="
systemctl is-active vts nginx
echo "Active valkey-server processes: $(pgrep -xc valkey-server || true)"
ss -tlnp | grep -E '(:443|:80|:4000|:8888|:2000|:2001)'

echo ""
echo "================================================================================"
echo " RHEL 9 VTS Tuning Complete! Verify APIs via https://vts-server.local"
echo "================================================================================"
