#!/usr/bin/env bash
# Allow one more agent IP to reach the Zabbix server on 10051.
#   bash allow-agent.sh 203.0.113.12
set -euo pipefail
ip="${1:?usage: allow-agent.sh <agent-ip>}"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip port port=10051 protocol=tcp accept"
firewall-cmd --reload
command -v imunify360-agent >/dev/null && imunify360-agent whitelist ip add "$ip" --comment "fleet-monitoring agent" || true
echo "Allowed $ip -> 10051"
