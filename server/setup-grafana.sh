#!/usr/bin/env bash
# Connect Grafana to Zabbix and import the Fleet Overview dashboard.
# Run as root on the monitoring server after configure-zabbix.sh:
#   bash setup-grafana.sh
#
# - Creates a READ-ONLY Zabbix user "grafana" (read access to the Fleet group only)
# - Enables the Zabbix app plugin in Grafana and adds the Zabbix data source
# - Imports dashboards/fleet-overview.json (downloaded from this repo if not local)
set -euo pipefail
BASE=${BASE:-/opt/fleet-monitoring}
[[ $EUID -eq 0 || -n "${TEST_MODE:-}" ]] || { echo "Run as root."; exit 1; }
REPO_RAW=https://raw.githubusercontent.com/Irfan-Ahamed-Seyam/fleet-monitoring/main
DASH=${DASH:-$(dirname "$0")/../dashboards/fleet-overview.json}
if [[ ! -f "$DASH" ]]; then
  DASH=$BASE/fleet-overview.json
  curl -fsSL "$REPO_RAW/dashboards/fleet-overview.json" -o "$DASH"
fi
grep -q '^ZBX_GRAFANA_PASSWORD=' $BASE/.env || echo "ZBX_GRAFANA_PASSWORD=$(openssl rand -hex 12)" >> $BASE/.env

BASE=$BASE DASH=$DASH \
ZBX_URL="${ZBX_URL:-http://127.0.0.1:18080/api_jsonrpc.php}" \
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:13000}" \
DS_ZBX_URL="${DS_ZBX_URL:-http://127.0.0.1:8080/api_jsonrpc.php}" \
python3 - <<'PY'
import base64, json, os, urllib.request, urllib.error
E = os.environ
env = dict(l.strip().split("=", 1) for l in open(f"{E['BASE']}/.env") if "=" in l)

# ---- Zabbix: read-only user for Grafana
tok = None
def z(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    d = json.load(urllib.request.urlopen(urllib.request.Request(E["ZBX_URL"], json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20))
    if "error" in d: raise SystemExit(f"zabbix {m}: {d['error']}")
    return d["result"]
tok = z("user.login", {"username": "Admin", "password": env["ZBX_ADMIN_PASSWORD"]})
gid = z("hostgroup.get", {"filter": {"name": ["Fleet"]}, "output": ["groupid"]})[0]["groupid"]
ug = z("usergroup.get", {"filter": {"name": ["Grafana read-only"]}, "output": ["usrgrpid"]})
ugid = ug[0]["usrgrpid"] if ug else z("usergroup.create", {"name": "Grafana read-only", "gui_access": 3,
        "hostgroup_rights": [{"id": gid, "permission": 2}]})["usrgrpids"][0]
u = z("user.get", {"filter": {"username": ["grafana"]}, "output": ["userid"]})
if u:   # keep password in sync with .env (self-healing on re-run)
    z("user.update", {"userid": u[0]["userid"], "passwd": env["ZBX_GRAFANA_PASSWORD"], "usrgrps": [{"usrgrpid": ugid}]})
else:
    z("user.create", {"username": "grafana", "passwd": env["ZBX_GRAFANA_PASSWORD"], "roleid": "1", "usrgrps": [{"usrgrpid": ugid}]})
print("==> Zabbix read-only user 'grafana' ready (Fleet group, read only)")

# ---- Grafana
auth = "Basic " + base64.b64encode(f"admin:{env['GF_SECURITY_ADMIN_PASSWORD']}".encode()).decode()
def g(method, path, body=None, ok404=False):
    req = urllib.request.Request(E["GRAFANA_URL"] + path, None if body is None else json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": auth}, method=method)
    try:
        return json.load(urllib.request.urlopen(req, timeout=20))
    except urllib.error.HTTPError as e:
        if ok404 and e.code == 404: return None
        raise SystemExit(f"grafana {method} {path}: {e.code} {e.read()[:200]}")

g("POST", "/api/plugins/alexanderzobnin-zabbix-app/settings", {"enabled": True, "pinned": True, "jsonData": {}})
print("==> Zabbix plugin enabled")

ds = {"name": "Zabbix", "uid": "zabbix", "type": "alexanderzobnin-zabbix-datasource", "access": "proxy",
      "url": E["DS_ZBX_URL"], "isDefault": True,
      "jsonData": {"authType": "userLogin", "username": "grafana", "trends": True, "trendsFrom": "7d", "trendsRange": "4d", "cacheTTL": "1h"},
      "secureJsonData": {"password": env["ZBX_GRAFANA_PASSWORD"]}}
if g("GET", "/api/datasources/uid/zabbix", ok404=True):
    g("PUT", "/api/datasources/uid/zabbix", ds)
else:
    g("POST", "/api/datasources", ds)
health = g("GET", "/api/datasources/uid/zabbix/health")
print("==> Data source:", health.get("status"), "-", health.get("message"))

dash = json.load(open(E["DASH"]))
dash.pop("id", None)
r = g("POST", "/api/dashboards/db", {"dashboard": dash, "overwrite": True, "message": "fleet-monitoring setup"})
print("==> Dashboard imported:", r.get("url"))
PY
echo "==> Open Grafana -> Dashboards -> Fleet Overview"
