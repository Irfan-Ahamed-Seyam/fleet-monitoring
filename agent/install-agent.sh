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

PKG=$(command -v dnf || command -v yum) || { echo "No dnf/yum found."; exit 1; }

# Zabbix docs: stop EPEL from shipping its own (older) zabbix packages
if [[ -f /etc/yum.repos.d/epel.repo ]] && ! grep -q 'excludepkgs=zabbix\*' /etc/yum.repos.d/epel.repo; then
  sed -i '/^\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
fi

if ! rpm -q zabbix-release >/dev/null 2>&1; then
  echo "==> Adding Zabbix 7.0 repository"
  ok=0
  for url in \
    "https://repo.zabbix.com/zabbix/7.0/alma/$EL/x86_64/zabbix-release-latest-7.0.el$EL.noarch.rpm" \
    "https://repo.zabbix.com/zabbix/7.0/rhel/$EL/x86_64/zabbix-release-latest-7.0.el$EL.noarch.rpm" \
    "https://repo.zabbix.com/zabbix/7.0/alma/$EL/x86_64/zabbix-release-latest.el$EL.noarch.rpm"; do
    if rpm -Uvh "$url" 2>/dev/null; then ok=1; break; fi
  done
  [[ $ok -eq 1 ]] || { echo "Could not add Zabbix repo. Check https://repo.zabbix.com/zabbix/7.0/"; exit 1; }
fi
$PKG clean all -q >/dev/null 2>&1 || true

# agent2 where available (EL8+); classic agent on EL7 (Zabbix ships no agent2 for EL7)
if [[ "$EL" -ge 8 ]]; then
  PKGNAME=zabbix-agent2; SVC=zabbix-agent2; CONF=/etc/zabbix/zabbix_agent2.conf
  DROPIN_DIR=/etc/zabbix/zabbix_agent2.d; LOG=/var/log/zabbix/zabbix_agent2.log
else
  PKGNAME=zabbix-agent;  SVC=zabbix-agent;  CONF=/etc/zabbix/zabbix_agentd.conf
  DROPIN_DIR=/etc/zabbix/zabbix_agentd.d;  LOG=/var/log/zabbix/zabbix_agentd.log
fi

echo "==> Installing $PKGNAME"
$PKG install -y -q $PKGNAME

echo "==> Writing PSK and config"
install -m 640 -o root -g zabbix /dev/null /etc/zabbix/fleet.psk
echo "$ZBX_PSK" > /etc/zabbix/fleet.psk

cp -n $CONF ${CONF}.orig
# comment out defaults we override (duplicate keys are rejected)
sed -i -E 's/^(Server|ServerActive|Hostname|ListenIP|HostMetadata)=/# &/' $CONF

mkdir -p $DROPIN_DIR
cat > $DROPIN_DIR/fleet.conf <<CONF
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
grep -q "^Include=$DROPIN_DIR/\*.conf" $CONF || echo "Include=$DROPIN_DIR/*.conf" >> $CONF

# CSF (common on cPanel/CloudLinux) filters OUTGOING ports too: allow 10051 out
if [[ -f /etc/csf/csf.conf ]] && ! grep -qE '^TCP_OUT = "([^"]*,)?10051(,[^"]*)?"' /etc/csf/csf.conf; then
  cp /etc/csf/csf.conf /etc/csf/csf.conf.bak-fleetmon
  sed -i -E 's/^(TCP_OUT = "[^"]*)"/\1,10051"/' /etc/csf/csf.conf
  csf -r >/dev/null 2>&1 && echo "==> CSF: allowed outgoing 10051"
fi
if [[ "$ZBX_SERVER" != 127.0.0.1 ]]; then
  timeout 5 bash -c "</dev/tcp/$ZBX_SERVER/10051" 2>/dev/null && echo "==> Can reach $ZBX_SERVER:10051" \
    || echo "!! Cannot reach $ZBX_SERVER:10051. Check this server's outgoing firewall and the allowlist on the monitoring server."
fi

systemctl enable $SVC >/dev/null 2>&1
systemctl restart $SVC
sleep 3
systemctl is-active $SVC && echo "==> $SVC running. Host should auto-register within ~1 minute."
tail -5 $LOG || true
