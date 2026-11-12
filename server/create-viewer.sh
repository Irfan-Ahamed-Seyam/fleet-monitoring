#!/usr/bin/env bash
# Create (or reset) a READ-ONLY "viewer" account in Zabbix and Grafana, e.g. for screenshots
# or for teammates who should see dashboards but change nothing. Run as root on the monitoring server:
#   bash create-viewer.sh [linux-user-to-receive-the-password]
#
# - Zabbix: user "viewer", User role, read-only on the Fleet host group
# - Grafana: user "viewer", Viewer role
# - The password is random, saved as ZBX_VIEWER_PASSWORD in .env, and (optionally) copied to
#   ~<linux-user>/.fleetmon-viewer (mode 600) so that user can log in without root.
set -euo pipefail
BASE=${BASE:-/opt/fleet-monitoring}
[[ $EUID -eq 0 || -n "${TEST_MODE:-}" ]] || { echo "Run as root."; exit 1; }
RECEIVER="${1:-}"
grep -q '^ZBX_VIEWER_PASSWORD=' $BASE/.env || echo "ZBX_VIEWER_PASSWORD=$(openssl rand -hex 16)" >> $BASE/.env

BASE=$BASE ZBX_URL="${ZBX_URL:-http://127.0.0.1:18080/api_jsonrpc.php}" GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:13000}" python3 - <<'PY'
import base64, json, os, urllib.request, urllib.error
E = os.environ
env = dict(l.strip().split("=", 1) for l in open(f"{E['BASE']}/.env") if "=" in l)
pw = env["ZBX_VIEWER_PASSWORD"]

tok = None
def z(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    d = json.load(urllib.request.urlopen(urllib.request.Request(E["ZBX_URL"], json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20))
    if "error" in d: raise SystemExit(f"zabbix {m}: {d['error']}")
    return d["result"]
tok = z("user.login", {"username": "Admin", "password": env["ZBX_ADMIN_PASSWORD"]})
gid = z("hostgroup.get", {"filter": {"name": ["Fleet"]}, "output": ["groupid"]})[0]["groupid"]
ug = z("usergroup.get", {"filter": {"name": ["Viewers (read-only)"]}, "output": ["usrgrpid"]})
ugid = ug[0]["usrgrpid"] if ug else z("usergroup.create", {"name": "Viewers (read-only)",
        "hostgroup_rights": [{"id": gid, "permission": 2}]})["usrgrpids"][0]
u = z("user.get", {"filter": {"username": ["viewer"]}, "output": ["userid"]})
if u: z("user.update", {"userid": u[0]["userid"], "passwd": pw, "usrgrps": [{"usrgrpid": ugid}]})
else: z("user.create", {"username": "viewer", "passwd": pw, "roleid": "1", "usrgrps": [{"usrgrpid": ugid}]})
print("==> Zabbix: 'viewer' ready (User role, read-only on Fleet)")

auth = "Basic " + base64.b64encode(f"admin:{env['GF_SECURITY_ADMIN_PASSWORD']}".encode()).decode()
def g(method, path, body=None, ok404=False):
    req = urllib.request.Request(E["GRAFANA_URL"] + path, None if body is None else json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": auth}, method=method)
    try: return json.load(urllib.request.urlopen(req, timeout=20))
    except urllib.error.HTTPError as e:
        if ok404 and e.code == 404: return None
        raise SystemExit(f"grafana {method} {path}: {e.code} {e.read()[:200]}")
user = g("GET", "/api/users/lookup?loginOrEmail=viewer", ok404=True)
if user:
    uid = user["id"]; g("PUT", f"/api/admin/users/{uid}/password", {"password": pw})
else:
    uid = g("POST", "/api/admin/users", {"name": "Viewer (read-only)", "login": "viewer", "password": pw})["id"]
g("PATCH", f"/api/orgs/1/users/{uid}", {"role": "Viewer"})
print("==> Grafana: 'viewer' ready (Viewer role)")
PY

if [[ -n "$RECEIVER" ]]; then
  home="$(getent passwd "$RECEIVER" | cut -d: -f6)"
  [[ -n "$home" ]] || { echo "No such user: $RECEIVER"; exit 1; }
  pw="$(grep '^ZBX_VIEWER_PASSWORD=' $BASE/.env | cut -d= -f2)"
  install -m 600 -o "$RECEIVER" -g "$(id -gn "$RECEIVER")" /dev/null "$home/.fleetmon-viewer"
  printf 'user=viewer\npassword=%s\n' "$pw" > "$home/.fleetmon-viewer"
  echo "==> Password copied to $home/.fleetmon-viewer (readable only by $RECEIVER)"
fi
