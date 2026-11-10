#!/usr/bin/env bash
# Fleet status at a glance. Run as root on the monitoring server.
#   bash status.sh
set -euo pipefail
BASE=${BASE:-/opt/fleet-monitoring}
[[ $EUID -eq 0 || -n "${TEST_MODE:-}" ]] || { echo "Run as root."; exit 1; }
BASE=$BASE ZBX_URL="${ZBX_URL:-http://127.0.0.1:18080/api_jsonrpc.php}" python3 - <<'PY'
import json, os, time, urllib.request
BASE = os.environ["BASE"]
URL = os.environ.get("ZBX_URL", "http://127.0.0.1:18080/api_jsonrpc.php")
env = dict(l.strip().split("=", 1) for l in open(f"{BASE}/.env") if "=" in l)
tok = None
def call(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    d = json.load(urllib.request.urlopen(urllib.request.Request(URL, json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20))
    if "error" in d: raise SystemExit(f"{m}: {d['error']}")
    return d["result"]
tok = call("user.login", {"username": "Admin", "password": env["ZBX_ADMIN_PASSWORD"]})

hosts = call("host.get", {"output": ["hostid", "host", "status", "active_available"],
                          "selectInterfaces": "extend", "selectTags": "extend", "filter": {"status": 0}})
AVAIL = {"0": "unknown", "1": "OK", "2": "DOWN"}
now = time.time()
print(f"{'HOST':32} {'AGENT':8} {'LAST DATA':10} {'CPU%':>6} {'MEM%':>6} {'PROBLEMS':>8}")
for h in sorted(hosts, key=lambda x: x["host"]):
    items = {i["key_"]: i for i in call("item.get", {"hostids": h["hostid"], "output": ["key_", "lastvalue", "lastclock"],
             "filter": {"key_": ["agent.ping", "system.cpu.util", "vm.memory.util"]}})}
    ping = items.get("agent.ping", {})
    age = int(now - int(ping.get("lastclock", 0))) if ping.get("lastclock", "0") != "0" else None
    cpu = items.get("system.cpu.util", {}).get("lastvalue")
    mem = items.get("vm.memory.util", {}).get("lastvalue")
    probs = len(call("problem.get", {"hostids": h["hostid"], "output": ["eventid"]}))
    print(f"{h['host']:32} {AVAIL.get(h['active_available'], '?'):8} "
          f"{(str(age) + 's ago') if age is not None else 'never':10} "
          f"{(f'{float(cpu):.1f}' if cpu else '-'):>6} {(f'{float(mem):.1f}' if mem else '-'):>6} {probs:>8}")
print(f"\n{len(hosts)} monitored hosts")
PY
