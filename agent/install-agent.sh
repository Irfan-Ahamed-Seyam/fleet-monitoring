#!/usr/bin/env bash
# Install Zabbix agent2 (7.0 LTS) in ACTIVE mode with TLS-PSK encryption.
#
# Run as root on each monitored server:
#   ZBX_SERVER=<monitoring-server-ip> ZBX_PSK=<64-hex-key> bash install-agent.sh
# On the monitoring server itself use ZBX_SERVER=127.0.0.1
#
# Active mode: the agent connects OUT to the server on 10051.
# No inbound port is opened on this server (agent listens on 127.0.0.1 only).
set -euo pipefail

ZBX_SERVER="${ZBX_SERVER:?set ZBX_SERVER}"
ZBX_PSK="${ZBX_PSK:?set ZBX_PSK}"
HOSTNAME_ZBX="${ZBX_HOSTNAME:-$(hostname -f)}"
METADATA="${ZBX_METADATA:-fleet linux cpanel}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ "$ZBX_PSK" =~ ^[0-9a-f]{64}$ ]] || { echo "ZBX_PSK must be 64 hex chars."; exit 1; }

. /etc/os-release
EL="${VERSION_ID%%.*}"
echo "==> $PRETTY_NAME (EL$EL), host '$HOSTNAME_ZBX' -> server $ZBX_SERVER"

# Zabbix docs: stop EPEL from shipping its own (older) zabbix packages
if [[ -f /etc/yum.repos.d/epel.repo ]] && ! grep -q 'excludepkgs=zabbix\*' /etc/yum.repos.d/epel.repo; then
  sed -i '/^\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
fi

if ! rpm -q zabbix-release >/dev/null 2>&1; then
  echo "==> Adding Zabbix 7.0 repository"
  ok=0
  for url in \
    "https://repo.zabbix.com/zabbix/7.0/alma/$EL/x86_64/zabbix-release-latest-7.0.el$EL.noarch.rpm" \
    "https://repo.zabbix.com/zabbix/7.0/alma/$EL/x86_64/zabbix-release-latest.el$EL.noarch.rpm" \
    "https://repo.zabbix.com/zabbix/7.0/rhel/$EL/x86_64/zabbix-release-latest-7.0.el$EL.noarch.rpm"; do
    if rpm -Uvh "$url" 2>/dev/null; then ok=1; break; fi
  done
  [[ $ok -eq 1 ]] || { echo "Could not add Zabbix repo. Check https://repo.zabbix.com/zabbix/7.0/"; exit 1; }
  dnf clean all -q
fi

echo "==> Installing zabbix-agent2"
dnf install -y -q zabbix-agent2

echo "==> Writing PSK and config"
install -m 640 -o root -g zabbix /dev/null /etc/zabbix/fleet.psk
echo "$ZBX_PSK" > /etc/zabbix/fleet.psk

CONF=/etc/zabbix/zabbix_agent2.conf
cp -n $CONF ${CONF}.orig
# comment out defaults we override (agent2 rejects duplicate keys)
sed -i -E 's/^(Server|ServerActive|Hostname|ListenIP|HostMetadata)=/# &/' $CONF

mkdir -p /etc/zabbix/zabbix_agent2.d
cat > /etc/zabbix/zabbix_agent2.d/fleet.conf <<CONF
# Managed by fleet-monitoring/install-agent.sh
Server=127.0.0.1
ListenIP=127.0.0.1
ServerActive=$ZBX_SERVER
Hostname=$HOSTNAME_ZBX
HostMetadata=$METADATA
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=fleet-psk
TLSPSKFile=/etc/zabbix/fleet.psk
CONF
grep -q '^Include=/etc/zabbix/zabbix_agent2.d/\*.conf' $CONF || echo 'Include=/etc/zabbix/zabbix_agent2.d/*.conf' >> $CONF

systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
sleep 3
systemctl is-active zabbix-agent2 && echo "==> Agent running. Check the server UI: host should auto-register within ~1 minute."
tail -5 /var/log/zabbix/zabbix_agent2.log || true
