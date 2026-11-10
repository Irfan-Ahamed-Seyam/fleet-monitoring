#!/usr/bin/env bash
# Restrict Zabbix trapper port 10051 to known agent IPs.
#
# Why this exists: Podman (netavark) publishes container ports with its own NAT
# rules, which bypass firewalld zone rules. So we filter 10051 in our own
# nftables table at the prerouting hook (before NAT), which nothing else touches.
#
#   bash firewall-lock.sh                 # (re)apply from the saved allowlist
#   bash firewall-lock.sh 203.0.113.10    # add an IP to the allowlist and apply
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
LIST=/opt/fleet-monitoring/agent-ips.txt
NFT=/etc/nftables/fleetmon.nft
touch "$LIST"; chmod 600 "$LIST"
for ip in "$@"; do
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Bad IPv4: $ip"; exit 1; }
  grep -qx "$ip" "$LIST" || echo "$ip" >> "$LIST"
done
ELEMS=$(paste -sd, "$LIST")

mkdir -p /etc/nftables
{
  echo "table inet fleetmon"
  echo "delete table inet fleetmon"
  echo "table inet fleetmon {"
  if [[ -n "$ELEMS" ]]; then
    echo "  set agents { type ipv4_addr; elements = { $ELEMS }; }"
  else
    echo "  set agents { type ipv4_addr; }"
  fi
  echo "  chain pre {"
  echo "    type filter hook prerouting priority -300; policy accept;"
  echo "    meta nfproto ipv4 tcp dport 10051 ip saddr != @agents counter drop"
  echo "    meta nfproto ipv6 tcp dport 10051 counter drop"
  echo "  }"
  echo "}"
} > "$NFT"
nft -f "$NFT"

cat > /etc/systemd/system/fleetmon-firewall.service <<UNIT
[Unit]
Description=Fleet monitoring: restrict Zabbix port 10051 to agent IPs
After=network-pre.target firewalld.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $NFT
ExecStop=/usr/sbin/nft delete table inet fleetmon

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable fleetmon-firewall.service >/dev/null
echo "==> 10051 allowed only from: ${ELEMS:-<none>}"
nft list set inet fleetmon agents | grep -E "elements|type" || true
