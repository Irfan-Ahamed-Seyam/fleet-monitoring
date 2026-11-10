#!/usr/bin/env bash
# Allow one more agent IP to reach the Zabbix server on 10051.
#   bash allow-agent.sh 203.0.113.12
set -euo pipefail
ip="${1:?usage: allow-agent.sh <agent-ip>}"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
bash "$(dirname "$0")/firewall-lock.sh" "$ip"
command -v imunify360-agent >/dev/null && imunify360-agent ip-list local add --purpose white "$ip" --comment "fleet-monitoring agent" >/dev/null || true
echo "Allowed $ip -> 10051"
