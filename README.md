# Homelab Observability Stack

An observability stack (Prometheus + Grafana) built from scratch to monitor a laptop running as a 24/7 server for self-hosted AI workloads — 55-60 Docker containers (Ollama, LiteLLM, Dify, Langfuse, ClickHouse, and more), including a discrete GPU (NVIDIA GTX 1050 Mobile).

This isn't a "docker-compose up and done" tutorial. During development, the stack was actually used to **debug real incidents** in the infrastructure it monitors — a crash-looping container, a Prometheus cardinality explosion, a Grafana OOM-kill, a hardware sensor that simply doesn't exist. Every incident is documented in [PRD.md](PRD.md#14-incidents--findings-during-development-changelog).

## Why This Project Exists

This laptop runs dozens of AI containers 24/7, cooled by consumer laptop hardware rather than a server rack. Netdata is already installed for live troubleshooting, but it lacks flexible historical retention, custom alerting, and full control over what gets tracked. This stack is built **alongside** Netdata (not as a replacement) to provide:

- Historical trending that can be queried (PromQL) — not just live snapshots
- Alerting tuned to this specific machine's conditions — not generic thresholds
- A dashboard that reflects genuine understanding of the hardware being monitored (e.g. why "CPU Package" temperature differs from the average of individual cores — see [technical notes](#things-worth-knowing))

### Hardware Being Monitored

| Item | Detail |
|---|---|
| Laptop model | ASUS ROG G531GD-I705G4T |
| CPU | Intel i7-9750H (6 cores / 12 threads) |
| RAM | 32GB (16GB + 16GB) |
| GPU | NVIDIA GeForce GTX 1050, 4GB VRAM (+ Intel UHD 630) |
| OS | Ubuntu 24.04 LTS |
| Network | Tailscale (dashboard access is restricted to this) |

Full details (storage, cooling, existing workload) are in [PRD.md §2](PRD.md#2-background--hardware-context).

**Maintenance log** (relevant context when interpreting temperature trends — baseline shifts after these dates):

| Date | Activity |
|---|---|
| August 13, 2026 | Thermal paste replaced with Arctic MX-6 |
| August 13, 2026 | Dust cleaned out (fans & heatsink) |
| April 2026 | Serviced at an ASUS Service Center |

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                Access restricted to Tailscale (VPN)         │
└───────────────────────────┬──────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │     Grafana      │  28 custom panels,
                    │      :3033       │  built from scratch
                    └────────┬────────┘
                             │ PromQL
                    ┌────────▼────────┐
                    │   Prometheus    │  scrape + alert eval
                    │      :9099      │  every 5s, 15d/5GB retention
                    └───────┬─────────┘
              scrape every 5s │
      ┌───────────┬──────────┼───────────┐
      │           │          │           │
┌─────▼─────┐ ┌───▼────┐ ┌───▼─────┐ ┌───▼──────────────┐
│node_exporter│ │nvidia_ │ │cAdvisor │ │docker-status.sh    │
│ host CPU/   │ │gpu_exp.│ │ per-    │ │(custom exporter,   │
│ RAM/disk/   │ │temp,   │ │container│ │ systemd timer, 5s) │
│ temp/fan/   │ │util of │ │CPU/RAM/ │ │ catches crash-loops│
│ load avg    │ │the GPU │ │network  │ │ that dodge scrapes │
└─────────────┘ └────────┘ └─────────┘ └────────────────────┘

      │ alert fires
      ▼
┌─────────────┐      ┌──────────┐
│ Alertmanager │ ───▶ │ Telegram │
│    :9093     │      │   Bot    │
└─────────────┘      └──────────┘
```

Full diagram and rationale for each component: [PRD.md §5](PRD.md#5-architecture--components-current-state).

## Status

| Phase | Status |
|---|---|
| Core metrics (Prometheus, exporters, Grafana) | ✅ Done |
| Custom dashboard (28 panels, not imported) | ✅ Done |
| Production-readiness audit | ✅ Done — 12 alert rules, reliable boot recovery, resource limits verified against real usage, a repeatable query validator |
| Downsampling / recording rules | ❌ Not started |
| Alertmanager → Telegram | ✅ Done — 12 alert rules routed and delivered live, validated with a genuine firing alert (not a synthetic test) |
| Logs (Loki + Promtail) | ❌ Not started |

Measured overhead on the host: ~1.8% of one CPU core combined across all 5
containers (≈0.15% of the host's 12 threads), ~424MB RAM — see
[PRD.md §13](PRD.md#13-success-criteria).

Full phase breakdown: [PRD.md §11](PRD.md#11-implementation-phases--status).

## Quick Start

```bash
git clone <repo-url>
cd homelab-observability
cp .env.example .env
```

Edit `.env` with, at minimum:
```bash
TAILSCALE_IP=<your-machine's-tailnet-ip>
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<change-me>

# For Telegram alerting — create a bot via @BotFather for the token, then
# message it once (/start) and read your chat ID back from
# https://api.telegram.org/bot<token>/getUpdates
TELEGRAM_BOT_TOKEN=<your-bot-token>
TELEGRAM_CHAT_ID=<your-chat-id>
```

The Telegram variables are **required** — Alertmanager renders its config
from them at startup, so the stack won't start without both set. The bot
token comes from @BotFather; the chat ID is the number you get back from
`getUpdates` after messaging the bot once.

```bash
docker compose up -d
```

Access Grafana at `http://<TAILSCALE_IP>:3033` (log in with the credentials from `.env`).

**Note:** every port is bound to `TAILSCALE_IP`, not `0.0.0.0` — so the stack is **unreachable** unless you're connected to the same tailnet. This is intentional (see [Security](#security)).

### Host prerequisites

- Docker + Docker Compose v2
- NVIDIA Container Toolkit (for `nvidia_gpu_exporter` — skip if there's no NVIDIA GPU)
- `lm-sensors` installed and configured (`sensors-detect`) on the host (for CPU/fan temperature via `node_exporter`)
- Two systemd units, installed once (both are plain files in [systemd/](systemd/)):

  ```bash
  sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now docker-status.timer          # crash-loop detection
  sudo systemctl enable --now homelab-observability.service # reliable boot recovery
  ```

  `docker-status.timer` feeds [docker-status.sh](node-exporter-textfile/docker-status.sh),
  which catches containers crash-looping faster than the scrape interval.

  `homelab-observability.service` runs [scripts/boot-up.sh](scripts/boot-up.sh) at
  boot. **This is not optional if you want the stack back after a reboot.**
  `restart: unless-stopped` alone is not enough here: dockerd can restore a
  container without re-publishing its ports, leaving it Up, healthy, and
  unreachable — see [PRD.md §14 #13](PRD.md#14-incidents--findings-during-development-changelog).

## Dashboard

The `Server Overview` dashboard (28 panels, [grafana/dashboards/overview.json](grafana/dashboards/overview.json)) opens on a top **Overview** row of quick gauges (CPU/GPU temp, RAM and disk usage percentages) with the exact numbers underneath (RAM and disk shown as used/free/total in GB), then the detailed sections below. CPU and GPU are kept fully separate:

1. **📊 Overview** — at-a-glance gauges: CPU temp (avg), GPU temp (avg), RAM usage %, and disk usage %, each paired with the exact number underneath (RAM and disk show used/free/total in GB)
2. **🖥️ CPU** — Package temp stat cards (Current/Avg/Min/Max), Package vs per-Core temperature (deliberately separated — see technical notes below), CPU usage, Load Average, CPU Fan RPM
3. **🎮 GPU** — GPU temp stat cards, GPU temperature graph, GPU utilization, GPU Fan RPM
4. **📊 System & Storage** — RAM and Disk usage, both with absolute GB alongside the percentage
5. **🐳 Containers** — running container count, top 10 containers by CPU usage, and a per-project RAM breakdown (grouped by the docker-compose project label cAdvisor already exposes — no extra collector needed) sorted descending
6. **📝 Maintenance Log** — the maintenance history table, pinned at the bottom (below the Containers section) so it stays as context without cluttering the monitoring sections

Every panel was built from scratch; every PromQL query was manually validated against real data — not just "looks like it's working." The bugs found during that validation process are logged in [PRD.md §14](PRD.md#14-incidents--findings-during-development-changelog).

## Things Worth Knowing

A few design decisions that came out of real debugging, not upfront assumptions:

- **"CPU Package" temperature is separated from per-Core temperature.** Package is a distinct physical sensor (Intel DTS) — not an average or maximum of the 6 individual cores — and it's what the BIOS/OS actually uses for thermal throttling decisions. The dashboard reflects this explicitly instead of blending every sensor into one generic number.
- **"Running Containers" initially miscounted** (92 vs. a manual count of 59) because the query counted raw cAdvisor time series rather than unique containers — some containers had a dozen-plus duplicate series. Fix: deduplicate first (`count by (name)`), then count.
- **cAdvisor isn't always enough.** A container crash-looping faster than the scrape interval can be entirely invisible to cAdvisor (it's never "up" at the exact moment of a scrape). The fix: a [small script](node-exporter-textfile/docker-status.sh) that reads `docker inspect` directly on the host, independent of Prometheus's scrape cycle.
- **The `ContainerCrashLooping` alert isn't a toy alert** — it genuinely caught 3 containers crash-looping hundreds of times due to a Docker network-attachment bug in an unrelated project on the same machine, and the fallout (a Prometheus cardinality explosion, elevated CPU load) was traceable through this very dashboard. Full story in [PRD.md §14](PRD.md#14-incidents--findings-during-development-changelog).

- **`restart: unless-stopped` is not a recovery strategy on its own.** After a
  host reboot this stack came back with every container reporting Up and
  healthy, and every port unreachable — dockerd had restored the containers but
  silently dropped their port bindings, which Docker does not consider a
  failure. A boot-time unit that verifies the bindings actually exist, and
  repairs the ones that do not, is what makes recovery real. Reproduced on two
  consecutive reboots before it was fixed.
- **A watchdog is worth exactly as much as its selector.** The alert meant to
  warn that crash-loop detection had gone blind was itself matching a label
  that never existed (bare filename vs. node_exporter's full path), so it could
  never fire. It only surfaced by querying the metric by hand during an audit.
- **The monitoring was a meaningful share of the load it was monitoring.** The
  crash-loop exporter shelled out to `docker inspect` once per container every
  5 seconds — ~2s of CPU per run, about 40% of a core, continuously. Batching it
  into a single call made it ~25× cheaper for identical output.

## Changing the Grafana Admin Password

Editing `GF_SECURITY_ADMIN_PASSWORD` in `.env` and restarting **does nothing**
once Grafana has started once before — that variable is only read the very
first time the database is created (in the `grafana-data` volume). After
that, Grafana ignores it silently, and repeated login attempts with a
password it doesn't recognize will trip its brute-force lockout, which then
blocks *even the correct password* for a few minutes.

To actually change it:

```bash
docker exec obs-grafana grafana cli admin reset-admin-password '<new-password>'
```

This resets the password directly in the database. Keep `.env` in sync so a
fresh `docker compose up` (e.g. after wiping the volume) still gets a sane
password on first boot.

## Security

- Every port is bound to the Tailscale IP, not `0.0.0.0` — no public internet exposure
- Grafana requires authentication (anonymous access disabled)
- Resource limits (CPU/memory) are set on every container — preventing a misbehaving exporter/cAdvisor from hogging resources on an already busy machine
- Secrets (Grafana admin password, Telegram token) live in `.env`, gitignored, with `.env.example` as the template

## Repository Structure

```
homelab-observability/
├── PRD.md                           # full spec + development incident log
├── docker-compose.yml
├── .env.example
├── prometheus/
│   ├── prometheus.yml               # scrape config, 5s interval
│   └── rules/alerting-rules.yml     # active alert rules
├── node-exporter-textfile/
│   └── docker-status.sh             # custom crash-loop exporter
├── scripts/
│   ├── boot-up.sh                   # boot convergence + port-binding repair
│   └── validate-dashboard.py        # re-runs every panel query against a live
│                                     #   Prometheus; catches "No data" and
│                                     #   topk/ranking bugs before they ship
├── systemd/                         # unit files for the two units above
└── grafana/
    ├── dashboards/overview.json     # 28 panels, built from scratch
    └── provisioning/                # datasource & dashboard auto-provisioning
```

## Roadmap

- [ ] Recording rules for downsampling (15-day raw → 90-day hourly → 2-year daily)
- [ ] Alertmanager + Telegram Bot integration
- [ ] Loki + Promtail for log aggregation
- [ ] `metric_relabel_configs` on the cAdvisor scrape job to mitigate cardinality explosions (see [PRD.md §7](PRD.md#7-retention--downsampling-strategy))

Full details: [PRD.md §11](PRD.md#11-implementation-phases--status).

## License

MIT — see [LICENSE](LICENSE).
