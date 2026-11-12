#!/usr/bin/env bash
# Set each Fleet host's *display name* to its short hostname (web01.example.com -> web01).
# Keeps company domains out of dashboards/screenshots. The technical hostname is unchanged.
#   bash set-display-names.sh
set -euo pipefail
BASE=${BASE:-/opt/fleet-monitoring}
[[ $EUID -eq 0 || -n "${TEST_MODE:-}" ]] || { echo "Run as root."; exit 1; }
BASE=$BASE ZBX_URL="${ZBX_URL:-http://127.0.0.1:18080/api_jsonrpc.php}" python3 - <<'PY'
import json, os, urllib.request
E = os.environ
env = dict(l.strip().split("=", 1) for l in open(f"{E['BASE']}/.env") if "=" in l)
tok = None
def z(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    d = json.load(urllib.request.urlopen(urllib.request.Request(E["ZBX_URL"], json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20))
    if "error" in d: raise SystemExit(f"{m}: {d['error']}")
    return d["result"]
tok = z("user.login", {"username": "Admin", "password": env["ZBX_ADMIN_PASSWORD"]})
gid = z("hostgroup.get", {"filter": {"name": ["Fleet"]}, "output": ["groupid"]})[0]["groupid"]
for h in z("host.get", {"groupids": gid, "output": ["hostid", "host", "name"]}):
    short = h["host"].split(".")[0]
    if h["name"] != short:
        z("host.update", {"hostid": h["hostid"], "name": short})
    print(f"  {h['host']:34} -> {short}")
PY
