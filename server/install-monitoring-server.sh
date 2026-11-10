#!/usr/bin/env bash
# Fleet monitoring server: Zabbix 7.0 LTS + PostgreSQL + Grafana in one Podman pod.
#
# Run as root on the server that will host monitoring.
#   AGENT_IPS="203.0.113.10 203.0.113.11" bash install-monitoring-server.sh
#
# Security model:
#   - Zabbix web UI and Grafana listen on 127.0.0.1 only (reach them via SSH tunnel).
#   - PostgreSQL is not published at all (only reachable inside the pod).
#   - Port 10051 (agent -> server) is opened in firewalld ONLY for the IPs in AGENT_IPS.
#   - Agent <-> server traffic is encrypted with TLS-PSK (key generated here).
set -euo pipefail

BASE=/opt/fleet-monitoring
ZBX_TAG=alpine-7.0-latest
PG_IMAGE=docker.io/library/postgres:16-alpine
GRAFANA_IMAGE=docker.io/grafana/grafana:12.1.0
WEB_PORT=18080        # Zabbix UI   -> 127.0.0.1:18080
GRAFANA_PORT=13000    # Grafana     -> 127.0.0.1:13000
AGENT_IPS="${AGENT_IPS:-}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
command -v podman >/dev/null || { echo "podman not found."; exit 1; }

echo "==> Pre-flight: checking ports are free"
for p in $WEB_PORT $GRAFANA_PORT 10051; do
  if ss -ltn | awk '{print $4}' | grep -qE "[:.]$p\$"; then echo "Port $p already in use. Aborting."; exit 1; fi
done

echo "==> Creating $BASE and secrets"
mkdir -p $BASE/{pgdata,grafana,zbx-export}
chmod 700 $BASE
if [[ ! -f $BASE/.env ]]; then
  cat > $BASE/.env <<ENV
POSTGRES_USER=zabbix
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=zabbix
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 12)
ENV
  chmod 600 $BASE/.env
fi
if [[ ! -f $BASE/fleet.psk ]]; then
  openssl rand -hex 32 > $BASE/fleet.psk
  chmod 600 $BASE/fleet.psk
fi
# shellcheck disable=SC1091
source $BASE/.env
chown 472:0 $BASE/grafana   # grafana container user

echo "==> Creating pod (UI ports bound to localhost only)"
podman pod exists fleetmon && { echo "Pod 'fleetmon' already exists. Aborting (remove it first to reinstall)."; exit 1; }
podman pod create --name fleetmon \
  -p 127.0.0.1:${WEB_PORT}:8080 \
  -p 127.0.0.1:${GRAFANA_PORT}:3000 \
  -p 10051:10051

echo "==> Starting PostgreSQL"
podman run -d --pod fleetmon --name fleetmon-db --restart=always --memory=768m \
  --env-file $BASE/.env -v $BASE/pgdata:/var/lib/postgresql/data:Z $PG_IMAGE

echo "==> Starting Zabbix server"
podman run -d --pod fleetmon --name fleetmon-server --restart=always --memory=512m \
  --env-file $BASE/.env -e DB_SERVER_HOST=127.0.0.1 \
  -e ZBX_CACHESIZE=64M -e ZBX_STARTPOLLERS=5 \
  docker.io/zabbix/zabbix-server-pgsql:$ZBX_TAG

echo "==> Starting Zabbix web UI"
podman run -d --pod fleetmon --name fleetmon-web --restart=always --memory=256m \
  --env-file $BASE/.env -e DB_SERVER_HOST=127.0.0.1 -e ZBX_SERVER_HOST=127.0.0.1 \
  -e PHP_TZ=Europe/Stockholm \
  docker.io/zabbix/zabbix-web-nginx-pgsql:$ZBX_TAG

echo "==> Starting Grafana (with Zabbix plugin)"
podman run -d --pod fleetmon --name fleetmon-grafana --restart=always --memory=384m \
  -e GF_SECURITY_ADMIN_PASSWORD="$GF_SECURITY_ADMIN_PASSWORD" \
  -e GF_INSTALL_PLUGINS=alexanderzobnin-zabbix-app \
  -e GF_SERVER_HTTP_PORT=3000 \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -v $BASE/grafana:/var/lib/grafana:Z $GRAFANA_IMAGE

echo "==> Start containers on boot"
systemctl enable --now podman-restart.service >/dev/null 2>&1 || true

echo "==> Firewall: allow 10051 only from agent IPs"
if systemctl is-active -q firewalld; then
  for ip in $AGENT_IPS; do
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip port port=10051 protocol=tcp accept"
  done
  firewall-cmd --reload
fi
if command -v imunify360-agent >/dev/null; then
  for ip in $AGENT_IPS; do
    imunify360-agent whitelist ip add "$ip" --comment "fleet-monitoring agent" || true
  done
fi

cat <<DONE

==========================================================
 Monitoring server installed.
 Zabbix UI : http://127.0.0.1:${WEB_PORT}   (Admin / zabbix -> CHANGE IT)
 Grafana   : http://127.0.0.1:${GRAFANA_PORT}  (admin / see $BASE/.env)
 Reach them from your laptop with an SSH tunnel, e.g.
   ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} -L ${GRAFANA_PORT}:127.0.0.1:${GRAFANA_PORT} <this-server>

 Agent PSK (needed by install-agent.sh on every server):
   identity: fleet-psk
   key     : $(cat $BASE/fleet.psk)
==========================================================
DONE
