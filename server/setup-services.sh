#!/usr/bin/env bash
# Service checks + alert-noise tuning for the Fleet. Run as root on the monitoring server:
#   bash setup-services.sh
#
# 1. Template "Fleet services": checks from each agent that the hosting services answer on
#    their ports (web 80/443, MySQL 3306, SMTP 25, IMAP 993, WHM 2087), with Up/Down value
#    mapping and triggers by severity. Linked to every Fleet host and to auto-registration.
# 2. Noise tuning: disables two routine "changed" triggers (installed package count, OS
#    description), which fire on every update. Security-relevant ones (/etc/passwd changed,
#    system name changed) stay on.
# 3. Excludes /swapfile from filesystem discovery (it was reported as a full disk).
# Idempotent.
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
    d = json.load(urllib.request.urlopen(urllib.request.Request(E["ZBX_URL"], json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=30))
    if "error" in d: raise SystemExit(f"{m}: {d['error']}")
    return d["result"]
tok = z("user.login", {"username": "Admin", "password": env["ZBX_ADMIN_PASSWORD"]})

TPL = "Fleet services"
SERVICES = [  # key, item name, trigger severity (2 warning, 3 average, 4 high)
    ("net.tcp.port[127.0.0.1,80]",   "Service: Web server (HTTP 80)",   4),
    ("net.tcp.port[127.0.0.1,443]",  "Service: Web server (HTTPS 443)", 4),
    ("net.tcp.port[127.0.0.1,3306]", "Service: MySQL/MariaDB (3306)",   4),
    ("net.tcp.port[127.0.0.1,25]",   "Service: SMTP (25)",              3),
    ("net.tcp.port[127.0.0.1,993]",  "Service: IMAP over SSL (993)",    3),
    ("net.tcp.port[127.0.0.1,2087]", "Service: WHM/cPanel (2087)",      2),
]

# --- template
tg = z("templategroup.get", {"filter": {"name": ["Templates/Applications"]}, "output": ["groupid"]})[0]["groupid"]
t = z("template.get", {"filter": {"host": [TPL]}, "output": ["templateid"]})
tid = t[0]["templateid"] if t else z("template.create", {"host": TPL, "groups": [{"groupid": tg}],
        "description": "Checks that hosting services answer on their ports (from the local agent).",
        "tags": [{"tag": "class", "value": "service"}]})["templateids"][0]

vm = z("valuemap.get", {"hostids": tid, "filter": {"name": ["Service state"]}, "output": ["valuemapid"]})
vmid = vm[0]["valuemapid"] if vm else z("valuemap.create", {"hostid": tid, "name": "Service state",
        "mappings": [{"value": "0", "newvalue": "Down"}, {"value": "1", "newvalue": "Up"}]})["valuemapids"][0]

existing_items = {i["key_"] for i in z("item.get", {"templateids": tid, "output": ["key_"]})}
existing_trig = {tr["description"] for tr in z("trigger.get", {"templateids": tid, "output": ["description"]})}
for key, name, sev in SERVICES:
    if key not in existing_items:
        z("item.create", {"hostid": tid, "name": name, "key_": key, "type": 7, "value_type": 3,
                          "delay": "1m", "history": "31d", "valuemapid": vmid,
                          "tags": [{"tag": "component", "value": "service"}]})
    short = name.replace("Service: ", "")
    desc = f"{short} is down on {{HOST.NAME}}"
    if desc not in existing_trig:
        z("trigger.create", {"description": desc, "priority": sev,
                             "expression": f"max(/{TPL}/{key},3m)=0",
                             "comments": "The port did not answer locally for 3 minutes. Check the service and its logs.",
                             "tags": [{"tag": "scope", "value": "availability"}]})
print(f"==> Template '{TPL}': {len(SERVICES)} service checks with triggers")

# --- link to all Fleet hosts and to auto-registration
gid = z("hostgroup.get", {"filter": {"name": ["Fleet"]}, "output": ["groupid"]})[0]["groupid"]
hosts = z("host.get", {"groupids": gid, "output": ["hostid"]})
z("host.massadd", {"hosts": [{"hostid": h["hostid"]} for h in hosts], "templates": [{"templateid": tid}]})
act = z("action.get", {"filter": {"name": ["Fleet auto-registration"]}, "output": ["actionid"], "selectOperations": "extend"})
if act:
    ops = act[0]["operations"]
    linked = [ot["templateid"] for op in ops if op["operationtype"] == "6" for ot in op.get("optemplate", [])]
    if tid not in linked:
        clean = []
        for op in ops:
            o = {"operationtype": int(op["operationtype"])}
            if op.get("opgroup"): o["opgroup"] = [{"groupid": g["groupid"]} for g in op["opgroup"]]
            if op.get("optemplate"): o["optemplate"] = [{"templateid": x["templateid"]} for x in op["optemplate"]]
            clean.append(o)
        clean.append({"operationtype": 6, "optemplate": [{"templateid": tid}]})
        z("action.update", {"actionid": act[0]["actionid"], "operations": clean})
print(f"==> Linked to {len(hosts)} Fleet hosts and to auto-registration")

# --- noise tuning on the Linux template
lt = z("template.get", {"filter": {"host": ["Linux by Zabbix agent active"]}, "output": ["templateid"]})[0]["templateid"]
quiet = ["Linux: Number of installed packages has been changed", "Linux: Operating system description has changed"]
for tr in z("trigger.get", {"templateids": lt, "output": ["triggerid", "description", "status"], "filter": {"description": quiet}}):
    if tr["status"] == "0": z("trigger.update", {"triggerid": tr["triggerid"], "status": 1})
print("==> Muted routine 'packages/OS description changed' triggers (kept /etc/passwd + system name)")

# --- /swapfile is not a filesystem to alert on
NOT = "^(/dev|/sys|/run|/proc|.+/shm$|/swapfile$)"
for h in hosts:
    m = z("usermacro.get", {"hostids": h["hostid"], "filter": {"macro": "{$VFS.FS.FSNAME.NOT_MATCHES}"}, "output": ["hostmacroid", "value"]})
    if m:
        if m[0]["value"] != NOT: z("usermacro.update", {"hostmacroid": m[0]["hostmacroid"], "value": NOT})
    else:
        z("usermacro.create", {"hostid": h["hostid"], "macro": "{$VFS.FS.FSNAME.NOT_MATCHES}", "value": NOT})
print("==> /swapfile excluded from filesystem discovery (clears within ~1h, at the next discovery run)")
PY
echo "==> Done. Service values appear within ~2 minutes (Monitoring > Latest data, tag component: service)."
