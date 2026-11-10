#!/usr/bin/env bash
# One-time Zabbix setup after install-monitoring-server.sh. Run as root on the monitoring server.
#   bash configure-zabbix.sh
#
# What it does (idempotent where possible):
#   1. Rotates the agent PSK (new random key in /opt/fleet-monitoring/fleet.psk)
#   2. Auto-registration: accept agents only over TLS-PSK
#   3. Host group "Fleet" + action: metadata contains "fleet" -> add host, add to group,
#      link "Linux by Zabbix agent active"
#   4. Disables the default "Zabbix server" host (no agent in the server container)
#   5. Replaces the default Admin password with a random one (saved in .env)
# Secrets never leave the server.
set -euo pipefail
BASE=${BASE:-/opt/fleet-monitoring}
[[ $EUID -eq 0 || -n "${TEST_MODE:-}" ]] || { echo "Run as root."; exit 1; }

if [[ "${KEEP_PSK:-0}" != 1 ]]; then
  openssl rand -hex 32 > $BASE/fleet.psk && chmod 600 $BASE/fleet.psk
  echo "==> PSK rotated"
fi
grep -q '^ZBX_ADMIN_PASSWORD=' $BASE/.env || echo "ZBX_ADMIN_PASSWORD=$(openssl rand -hex 12)" >> $BASE/.env

BASE=$BASE ZBX_URL="${ZBX_URL:-http://127.0.0.1:18080/api_jsonrpc.php}" python3 - <<'PY'
import json, os, urllib.request, sys
BASE = os.environ["BASE"]
URL = os.environ.get("ZBX_URL", "http://127.0.0.1:18080/api_jsonrpc.php")
env = dict(l.strip().split("=", 1) for l in open(f"{BASE}/.env") if "=" in l)
psk = open(f"{BASE}/fleet.psk").read().strip()
tok = None
def call(method, params):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    req = urllib.request.Request(URL, json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode(), h)
    d = json.load(urllib.request.urlopen(req, timeout=20))
    if "error" in d: raise SystemExit(f"{method}: {d['error']}")
    return d["result"]

# login: default password first, else the one we set earlier
for pw in ("zabbix", env["ZBX_ADMIN_PASSWORD"]):
    try:
        tok = call("user.login", {"username": "Admin", "password": pw}); cur = pw; break
    except SystemExit:
        tok = None
if not tok: sys.exit("Could not log in as Admin.")
print("==> Logged in to Zabbix API")

call("autoregistration.update", {"tls_accept": 2, "tls_psk_identity": "fleet-psk", "tls_psk": psk})
print("==> Auto-registration: PSK only")

g = call("hostgroup.get", {"filter": {"name": ["Fleet"]}, "output": ["groupid"]})
gid = g[0]["groupid"] if g else call("hostgroup.create", {"name": "Fleet"})["groupids"][0]
tid = call("template.get", {"filter": {"host": ["Linux by Zabbix agent active"]}, "output": ["templateid"]})[0]["templateid"]
if not call("action.get", {"filter": {"name": ["Fleet auto-registration"]}, "output": ["actionid"]}):
    call("action.create", {
        "name": "Fleet auto-registration", "eventsource": 2, "status": 0,
        "filter": {"evaltype": 0, "conditions": [{"conditiontype": 24, "operator": 2, "value": "fleet"}]},
        "operations": [
            {"operationtype": 2},
            {"operationtype": 4, "opgroup": [{"groupid": gid}]},
            {"operationtype": 6, "optemplate": [{"templateid": tid}]},
        ]})
print("==> Host group 'Fleet' + auto-registration action ready")

zs = call("host.get", {"filter": {"host": ["Zabbix server"]}, "output": ["hostid"]})
if zs: call("host.update", {"hostid": zs[0]["hostid"], "status": 1}); print("==> Default 'Zabbix server' host disabled")

if cur == "zabbix":
    call("user.update", {"userid": "1", "current_passwd": "zabbix", "passwd": env["ZBX_ADMIN_PASSWORD"]})
    print("==> Admin password changed (see ZBX_ADMIN_PASSWORD in .env)")
PY
echo "==> Done. Next: install agents (agent/install-agent.sh)."
