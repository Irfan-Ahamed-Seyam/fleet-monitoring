# Fleet Monitoring: Zabbix 7.0 + Grafana for a production hosting fleet

Production monitoring for a **fleet of 6 Linux web servers** (cPanel, about 1,000 hosted websites). It's built with **Zabbix 7.0 LTS**, **PostgreSQL** and **Grafana**, all in a single **Podman** pod, with encrypted active agents and no public exposure.

Designed and rolled out on a live production fleet in November 2026. Every server has reported continuously since.

![Grafana Fleet Overview: live data from all 6 production servers](docs/images/grafana-fleet.png)
<sub>Grafana "Fleet Overview": agent status, a <b>fleet summary</b> table (CPU, memory, swap, disk, load, uptime per server), <b>service status</b> (web, HTTPS, MySQL, SMTP, IMAP, WHM), active problems and 24-hour trends. Server names are anonymized.</sub>

---

## At a glance

| | |
|---|---|
| **Monitored servers** | 6 production servers, a mixed fleet: AlmaLinux 8, 9, 10 and CloudLinux 7, 9 |
| **Stack** | Zabbix 7.0 LTS server + web, PostgreSQL 16, Grafana 12 with the Zabbix plugin, Podman |
| **Agents** | Zabbix agent2 (EL8+) or classic agent (EL7), **active mode**, **TLS-PSK encrypted** |
| **Service checks** | Web (80/443), MySQL, SMTP, IMAP, WHM on every server, every minute. DOWN for 3 minutes raises a problem (High/Average/Warning by service) |
| **Onboarding** | Auto-registration: a new server joins the "Fleet" group with the Linux template, no clicking needed |
| **Exposure** | None. The UIs listen on `127.0.0.1` only, behind an SSH tunnel. Port 10051 is allowlisted per agent IP |
| **Footprint (measured)** | Agent ~18–36 MB RAM and ~0.2% CPU per server. The whole monitoring stack uses ~0.7 GB RAM |

## Architecture

```mermaid
flowchart LR
    subgraph fleet["Web servers (cPanel, mixed EL7-EL10)"]
        A1["web-01"]
        A2["web-02"]
        A3["web-03"]
        A4["web-04"]
        A5["web-05"]
    end

    subgraph mon["mon-01 (AlmaLinux 9): monitoring server + web server"]
        direction TB
        FW["nftables allowlist<br/>(10051 from fleet IPs only)"]
        subgraph pod["Podman pod: fleetmon"]
            ZS["Zabbix server 7.0<br/>:10051"]
            DB[("PostgreSQL 16<br/>not published")]
            ZW["Zabbix web<br/>127.0.0.1:18080"]
            GF["Grafana 12<br/>127.0.0.1:13000"]
        end
        AG0["agent2 (self)"]
    end

    A1 & A2 & A3 & A4 & A5 -- "active checks<br/>TLS-PSK, outbound only" --> FW --> ZS
    AG0 --> ZS
    ZS --- DB
    ZW --- DB
    GF -- "read-only API user" --> ZW
    ADMIN["Admin laptop"] -. "SSH tunnel" .-> ZW & GF
```

## Security design

- **No inbound ports on the monitored servers.** The agents run in *active* mode: they connect **out** to the server. Each agent listens only on `127.0.0.1`.
- **Encrypted transport.** Agent↔server traffic uses **TLS-PSK**. Auto-registration accepts PSK only, so unencrypted agents are refused.
- **Nothing public.** The Zabbix UI and Grafana bind to `127.0.0.1` and are reached through an SSH tunnel. PostgreSQL isn't published at all.
- **Allowlisted trapper port.** Port 10051 accepts only the fleet's IPs. It's enforced in **nftables at the prerouting hook**, see *Problems found* below.
- **Least privilege.** Grafana reads Zabbix through a **read-only API user** scoped to the Fleet group. A separate **read-only viewer** account exists for teammates and screenshots, and its write access was tested and blocked.
- **No secrets in this repo or on screen.** Passwords and the PSK are generated on the server (`/opt/fleet-monitoring`, mode 600). The PSK is never printed, and a rotation step is built in (`configure-zabbix.sh`).

## Alert tuning

A monitoring system that cries wolf gets ignored, so the alerts were tuned after the first day:
- **Muted** "installed packages changed" and "OS description changed". They fire on every routine update and drowned out real issues.
- **Kept** "/etc/passwd has been changed" and "system name has changed". They're security-relevant: an unexpected account change is exactly what a SOC wants to see.
- **Excluded** `/swapfile` from filesystem discovery. It was being reported as a "full disk".
- **Service triggers** are severity-graded (web and database: High, mail: Average, control panel: Warning) and need 3 minutes of failure, so a brief restart doesn't raise a problem.

## Problems found and fixed during rollout

| Problem | How it was found | Fix |
|---|---|---|
| **Container ports bypass firewalld.** Podman's NAT (netavark) skips firewalld zone rules, so the published port 10051 was reachable from any IP | Rollout verification: **tested the port from an outside, non-allowlisted host** instead of trusting the config | Filter 10051 in a dedicated **nftables table at prerouting (before NAT)**, persisted with a systemd unit (`firewall-lock.sh`). Re-tested from outside: closed |
| **CSF egress filtering** on the older (EL7) servers blocked the agents' outbound 10051 | Agent log `connection error (POLLERR)`, then a manual TCP test | The agent installer adds 10051 to CSF `TCP_OUT` (with a backup) and checks reachability before finishing |
| **Mixed OS versions.** EL7 has `yum` and no agent2 package | The first install on CloudLinux 7 failed | The installer detects EL7/8/9/10 and picks `dnf` or `yum` and agent2 or the classic agent. Tested on CentOS 7 and AlmaLinux 8 containers before rollout |
| **Full hostnames (customer-facing domains)** cluttered dashboards and alerts | Dashboard review | Display names are set to short hostnames (`set-display-names.sh`). Technical hostnames are unchanged |
| **Container interfaces** doubled up the network graphs | Dashboard review | The network panels exclude `podman*`, `veth*` and similar interfaces |

## What it caught

**It survived a real fleet-wide reboot.** On day 3 all 6 servers were rebooted for a kernel update. Zabbix recorded the OS change on each server, and the monitoring stack (Podman pod), the agents and the nftables allowlist **all came back by themselves**, with no manual action (`podman-restart`, systemd units).

Within the **first hour**, Zabbix flagged **high swap usage on 4 of 6 servers**, the same memory pressure seen earlier during manual incident work. Since then it has also recorded:
- one web server reaching a **load average of 110** with CPU at **97%** over a 24-hour window
- swap on several servers sitting **below 5% free for most of the day**
- the fleet-wide kernel update and reboots, detected automatically as OS changes plus uptime resets

![Zabbix problems](docs/images/zabbix-problems.png)

![Zabbix hosts: all 6 reporting through active agents](docs/images/zabbix-hosts.png)

## Deploy

Every script is idempotent and runs as root. The real IPs live in a private runbook, not here.

```bash
# 1. Monitoring server
AGENT_IPS="203.0.113.10 203.0.113.11" bash server/install-monitoring-server.sh
bash server/configure-zabbix.sh        # PSK rotation, PSK-only auto-registration, Fleet group/action, Admin password
bash server/set-display-names.sh       # short display names
bash server/setup-services.sh         # service checks (web/MySQL/mail/WHM) + alert-noise tuning
bash server/setup-grafana.sh           # read-only Zabbix user, data source, Fleet Overview dashboard

# 2. Each monitored server (on the monitoring server itself use ZBX_SERVER=127.0.0.1)
ZBX_SERVER=<monitoring-server-ip> ZBX_PSK=<key> bash agent/install-agent.sh

# 3. Later: allow one more agent IP
bash server/allow-agent.sh 203.0.113.12
```

Open the UIs from your laptop:
```bash
ssh -L 18080:127.0.0.1:18080 -L 13000:127.0.0.1:13000 <monitoring-server>
# Zabbix: http://localhost:18080   Grafana: http://localhost:13000
```

## Operations

| Script | Purpose |
|---|---|
| `server/status.sh` | Fleet status table: agent availability, last data, CPU %, memory %, open problems |
| `server/setup-services.sh` | Service checks template, triggers, alert-noise tuning (idempotent) |
| `server/create-viewer.sh` | Read-only "viewer" account in Zabbix and Grafana |
| `server/firewall-lock.sh` | Re-apply or extend the 10051 allowlist |
| `server/configure-zabbix.sh` | Also rotates the PSK when re-run (then update the agents) |

## System requirements

| Role | Requirement |
|---|---|
| Monitoring server | EL9 (tested on AlmaLinux 9), Podman 4+, ~1.5 GB free RAM, 2 GB+ disk for 31 days of history, Python 3 |
| Monitored servers | EL7 to EL10 (AlmaLinux, CloudLinux, RHEL-compatible), outbound TCP 10051 to the monitoring server |
| Admin access | SSH to the monitoring server (for the tunnel), root for the install scripts |

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Agent log: `cannot connect to [server]:10051 (POLLERR)` | Outbound firewall on the agent (CSF `TCP_OUT`) | `timeout 5 bash -c '</dev/tcp/<server>/10051'`. The installer adds 10051 to CSF |
| Agent log: `host [...] not found` | Normal on first contact. Auto-registration creates the host | It clears within ~1 minute ("active checks ... are active again") |
| Agent connects but the host never appears | PSK mismatch, or the IP isn't in the allowlist | `nft list set inet fleetmon agents` on the server; compare `/etc/zabbix/fleet.psk` |
| Port 10051 reachable from anywhere | Container ports bypass firewalld | `bash server/firewall-lock.sh`, then test from a non-allowlisted host |
| A service shows DOWN but works | The service listens only on a public IP, not 127.0.0.1 | Adjust the check's key to that IP, or bind the service to localhost too |
| A Grafana panel is empty or errors | Item name changed, or the read-only user can't see the host group | Re-run `setup-grafana.sh` (it re-syncs the user and data source) |

## Repository layout

```
server/
  install-monitoring-server.sh   Zabbix server + web + PostgreSQL + Grafana in a Podman pod
  configure-zabbix.sh            auto-registration (PSK only), Fleet group + action, Admin password, PSK rotation
  firewall-lock.sh               nftables allowlist for 10051, persisted via systemd
  allow-agent.sh                 add one agent IP
  set-display-names.sh           short display names
  setup-services.sh              service checks template + triggers, alert-noise tuning
  setup-grafana.sh               read-only Zabbix user, Grafana data source, dashboard import
  create-viewer.sh               read-only viewer account
  status.sh                      fleet status table
agent/
  install-agent.sh               agent2/agent for EL7-10, active + TLS-PSK, CSF egress, reachability check
dashboards/
  fleet-overview.json            Grafana dashboard (Zabbix data source)
docs/images/                     screenshots
```

## Roadmap

- **Alert notifications** (Telegram or email) with severity routing and a runbook link per alert
- **Website availability and SSL-expiry checks** for key client sites (HTTP checks from outside the server)
- **Ops tools:** a Bash health check and a Python log analyzer (top IPs, failed logins, error spikes)
- **SLA report:** monthly uptime and incidents per server from Zabbix data, exported to Excel
- **An external watchdog** for the monitoring server itself, and pinned image versions

## Related

- [monitoring-lab](https://github.com/Irfan-Ahamed-Seyam/monitoring-lab): a lab version with Prometheus, Alertmanager, blackbox checks and incident drills
