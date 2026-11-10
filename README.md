# Fleet Monitoring: Zabbix 7.0 + Grafana for a cPanel hosting fleet

Production monitoring for a fleet of AlmaLinux / cPanel web servers, built with **Zabbix 7.0 LTS**, **PostgreSQL** and **Grafana**, running in a single **Podman** pod.

> Work in progress: rollout is under way. A full write-up with architecture, dashboards and results will follow.

## Design
- **Active agents:** each server's Zabbix agent2 connects *out* to the monitoring server. No inbound port is opened on monitored servers.
- **Encrypted:** agent ↔ server traffic uses TLS-PSK.
- **Not exposed:** the Zabbix UI and Grafana bind to `127.0.0.1` and are reached over an SSH tunnel. PostgreSQL is not published at all.
- **Least privilege:** port 10051 is allowed in firewalld only from known agent IPs.
- **Auto-registration:** new servers join with host metadata and get templates automatically.

## Layout
| Path | Purpose |
|---|---|
| `server/install-monitoring-server.sh` | Installs Zabbix server + web + PostgreSQL + Grafana in a Podman pod |
| `server/allow-agent.sh` | Allows one more agent IP through the firewall |
| `agent/install-agent.sh` | Installs and configures Zabbix agent2 (active mode, TLS-PSK) |
