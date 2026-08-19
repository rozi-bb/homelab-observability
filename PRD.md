# PRD — Homelab Observability Stack

> **Implementation status:** Phase 1 (core metrics) and Phase 5 (custom dashboard) are complete and validated against real data. Phase 2 (downsampling), Phase 3 (Alertmanager + Telegram — the Prometheus-side alert rules already exist, Telegram integration doesn't), and Phase 4 (logs/Loki) have not been started. Details per phase in §11.

## 1. Summary

Building an industry-standard observability stack (Prometheus + Grafana + Alertmanager + Loki) to monitor an **ASUS ROG Strix G531GD** laptop running as a 24/7 server for self-hosted AI workloads (Ollama, LiteLLM, Dify, Langfuse, ClickHouse, etc. — 50+ Docker containers).

This project is built as a **portfolio piece** for recruiters/interviewers (DevOps/SRE/Platform/Infra roles), so beyond simply working, it also needs to be:
- Self-contained & reproducible (`git clone` + `docker compose up` just works)
- Well-documented (README, architecture diagram, rationale behind decisions)
- Evidence of a genuinely unique context: monitoring AI infrastructure with a GPU workload, not an empty server

**Not** intended to replace the already-installed Netdata — this stack stands on its own, a new service, separate from the Grafana/Netdata instances already running on this machine.

## 2. Background & Hardware Context

| Item | Detail |
|---|---|
| Model | ASUS ROG G531GD-I705G4T |
| CPU | Intel i7-9750H (6 cores / 12 threads) |
| GPU | NVIDIA GTX 1050 Mobile (4GB) + Intel UHD 630 |
| RAM | 32GB |
| Storage | NVMe, main partition ~316GB (note: consistently sat around ~93-95% used throughout development — outside this stack's control, but the reason behind several deliberately resource-frugal design decisions) |
| OS | Ubuntu 24.04 LTS |
| Cooling | External cooling pad, upright standing position for airflow |
| Network | Tailscale installed, tailnet IP: `100.77.191.60` |
| Existing workload | 55-60 active Docker containers: Ollama, LiteLLM, Dify, Langfuse, ClickHouse (multiple instances), Postgres, Redis, Grafana (a separate instance), Portainer, WhatsApp bridge, etc. |
| Existing monitoring | Netdata (active, `127.0.0.1:19999`, local-only) — **left running as-is**, not touched |

### Maintenance Log

Relevant context for interpreting temperature trends — the baseline shifts around these dates, so data before/after isn't strictly apples-to-apples:

| Date | Activity |
|---|---|
| August 13, 2026 | Thermal paste replaced with Arctic MX-6 |
| August 13, 2026 | Dust cleaned out (fans & heatsink) |
| April 2026 | Serviced at an ASUS Service Center |

## 3. Goals

1. Monitor real-time and historical: CPU usage, RAM usage, disk usage, CPU/GPU temperature, fan RPM, load average, network I/O, per-container resource usage (Docker), and container up/down/crash-loop status.
2. Tiered data retention (downsampling) for storage efficiency: high-resolution raw data short-term, hourly/daily aggregates long-term. *(not yet implemented — see §11 Phase 2)*
3. Automatic alerting to Telegram when metrics cross critical thresholds. *(Prometheus-side alert rules exist — see §8; Alertmanager→Telegram integration does not yet)*
4. Dashboard access **only** via Tailscale (no public internet exposure).
5. All services are new and self-contained (not piggybacking on the Grafana/other services already running for other projects).
6. Full observability: metrics **+ logs** (not just metrics) — for a stronger portfolio story ("full observability," not just basic monitoring). *(logs/Loki not yet implemented)*
7. Final deliverable worth publishing on GitHub as a portfolio piece: clear README, architecture diagram, custom dashboards (not just an imported ID from grafana.com), documented design decisions.

## 4. Non-Goals

- No HA/multi-node cluster (this is single-node, single-laptop).
- No Thanos/Mimir for distributed long-term storage — overkill for one machine; Prometheus recording rules are enough for downsampling.
- Not replacing or shutting down the Netdata or Grafana instances already running for other projects.
- No exposure to the public internet (Tailscale only) — unless the user explicitly requests otherwise later.
- No WhatsApp UI/notifications in this phase (Telegram only, already decided as the primary channel).

## 5. Architecture & Components (Current State)

```
┌─────────────────────────────────────────────────────────────┐
│                     Tailscale-only access                    │
│                     (100.77.191.60)                          │
└───────────────────────────┬───────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │     Grafana      │  :3033 (dashboard, 25 custom panels)
                    │  512M mem limit  │
                    └────────┬────────┘
                             │ queries
                    ┌────────▼────────┐
                    │   Prometheus    │  :9099, scrape/eval every 5s
                    │  (TSDB, 15d)    │  raw retention only (no recording
                    │  + alert rules  │  rules / downsampling yet)
                    └───────┬─────────┘
              scrape every 5s │
      ┌───────────┬──────────┼───────────┐
      │           │          │           │
┌─────▼─────┐ ┌───▼────┐ ┌───▼─────┐ ┌───▼──────────────┐
│node_exporter│ │nvidia_ │ │cAdvisor │ │docker-status.sh    │
│  :9100      │ │gpu_exp.│ │ :8081   │ │(custom script,     │
│ host: CPU,  │ │ :9835  │ │per-     │ │systemd timer 5s,   │
│ RAM, disk,  │ │        │ │container│ │writes to node_exp.'s│
│ temp, fan,  │ │        │ │CPU/RAM/ │ │textfile collector  │
│ load avg,   │ │        │ │network  │ │→ catches crash-loops│
│ network     │ │        │ │(~60     │ │ that dodge cAdvisor │
│             │ │        │ │container│ │ scrapes)            │
└─────────────┘ └────────┘ └─────────┘ └────────────────────┘

── Not yet implemented (Phase 3/4) ──
Alertmanager (routes alerts → Telegram Bot API)
Loki + Promtail (log aggregation)
```

### Components & versions (current state, not just recommendations anymore)

| Service | Image | Port (host, Tailscale-only) | Function | Status |
|---|---|---|---|---|
| Prometheus | `prom/prometheus:latest` | `9099` | Time-series DB, scraping, alert rule evaluation | ✅ Running |
| Grafana | `grafana/grafana:latest` | `3033` | Visual dashboard, 25 custom panels | ✅ Running |
| node_exporter | `prom/node-exporter:latest` | `9100` | Host metrics: CPU, RAM, disk, network, temperature, fan, load average | ✅ Running |
| nvidia_gpu_exporter | `utkuozdemir/nvidia_gpu_exporter:latest` | `9835` | Temperature, utilization, memory of the GTX 1050 GPU | ✅ Running (GPU fan speed **not available** — this laptop GPU doesn't expose that sensor via `nvidia-smi`) |
| cAdvisor | `gcr.io/cadvisor/cadvisor:latest` | `8081` (moved from default `8080`, which conflicted with another project's dev stack on the same machine) | Per-container Docker metrics | ✅ Running |
| `docker-status.sh` (custom) | bash script + systemd timer, not a container | — | Exports `docker inspect` RestartCount/State to node_exporter's textfile collector, refreshed every 5s | ✅ Running |
| Alertmanager | `prom/alertmanager` | — | Alert routing & deduplication → Telegram | ❌ Not built |
| Loki | `grafana/loki` | — | Log aggregation storage | ❌ Not built |
| Promtail | `grafana/promtail` | — | Log shipper from all containers to Loki | ❌ Not built |

Everything is orchestrated via a **single `docker-compose.yml`**, with a separate `.env` for secrets (Telegram token, Grafana credentials — not committed to git).

### Why does `docker-status.sh` exist outside the original plan?

Discovered during development: cAdvisor can only report metrics for a container that is **up at the exact moment of a scrape**. A container crash-looping faster than the scrape interval (e.g. restarting every 1-2 seconds) can go **entirely undetected** by cAdvisor — not a single data point recorded, despite the container clearly being broken.

The fix: a small script running on the **host** (not inside an observability container, since it needs direct `docker inspect` access) via a systemd timer every 5 seconds, reading `RestartCount` straight from Docker (a persistent counter maintained by dockerd, regardless of whether the container happened to be "up" at scrape time), then written out in Prometheus textfile format, which node_exporter picks up automatically. This is the basis for the `ContainerCrashLooping` alert (§8).

## 6. Metrics Collected (current state)

**Host:**
- CPU usage (%, aggregate), load average (1/5/15 min)
- RAM usage (%, used/available)
- Disk usage (%, root partition)
- Temperature: **CPU Package** (single sensor, deliberately separated from per-core — see note below), **CPU per-core** (Core 0-5), **GPU**
- Fan RPM (CPU fan only — `asus-isa-0000` sensor, 2 fans: `cpu_fan` & `gpu_fan` from the ASUS embedded controller, not read directly from the GPU)
- Network throughput (rx/tx, excluding virtual interfaces like `veth*`/`docker*`/`br-*`)

**Docker (per container, ~60 containers):**
- Per-container CPU usage (top 10 shown, `topk(10, ...)`)
- Running container count (deduplicated by `name`, not a raw series count — see the bug note in §14)
- Restart count / crash-loop detection (via `docker-status.sh`, not cAdvisor)

**Not yet collected (Phase 4):**
- Container stdout/stderr logs (planned: Promtail + Docker log driver → Loki)

**Important technical note — CPU Package vs. Core:**
"CPU Package" (the Intel DTS sensor, `Package id 0`) is **not** an average or maximum of the 6 individual cores — it's a physically separate sensor located elsewhere on the CPU die, and it's what the BIOS/OS actually uses for thermal throttling decisions. The dashboard deliberately separates the Package panel (used for alerting & overview stats) from the per-Core panels (used for debugging which specific core is running hottest) — mirroring how comparable tools work (HWiNFO, the MSI Afterburner overlay).

## 7. Retention & Downsampling Strategy

| Resolution | Method | Retention | Status |
|---|---|---|---|
| Raw (scrape interval **5 seconds**, finalized after resource testing) | Direct Prometheus scrape | 15 days | ✅ Active |
| Hourly aggregate (avg/min/max) | Prometheus recording rules | 90 days | ❌ Not built |
| Daily aggregate (avg/min/max) | Prometheus recording rules | 2 years | ❌ Not built |

**Why 5 seconds (not Prometheus's 15-second default)?** The 6-core/12-thread CPU on this machine has enough headroom for 3x more frequent scraping, and it suits a demo/portfolio context where the dashboard needs to feel "alive" (visibly updating graphs). Trade-off: faster time-series disk growth (~3.5GB per 15-day retention window vs. ~1.2GB at 15-second intervals, based on ~9,000 active series under normal conditions) — still well under available storage, but worth watching since the host disk is already crowded by other workloads.

**A real cardinality incident (recorded as both evidence and a lesson learned):** a container stuck in a continuous crash loop (a bug in an unrelated project on the same machine, not a bug in this stack) caused Docker to keep creating new virtual network interfaces (`veth*`) on every restart. cAdvisor recorded each `veth*` as a new time series, and Prometheus kept them until they expired. Total time series spiked from ~9,000 to **~127,000** (a 13x increase) within hours, starving Prometheus itself of CPU (it got throttled) and contributing to elevated system load/CPU temperature. Root cause was traced to a specific container, fixed at the Docker network level, and load average returned to normal within minutes of the fix. **Not yet implemented as a preventive fix:** add `metric_relabel_configs` to the cAdvisor scrape config to drop the `id` label that's the source of the cardinality growth.

## 8. Alerting

**Status: Prometheus-native alert rules are live and actively evaluated. Routing to Telegram (Alertmanager) has not been built** — alerts currently only show up as "firing" in the Prometheus UI, with no outbound notification yet.

### Alert rules currently running (`prometheus/rules/alerting-rules.yml`)

| Alert | Condition | Severity | Data source |
|---|---|---|---|
| `ContainerCrashLooping` | `increase(docker_container_restart_count[15m]) > 2`, for 2m | critical | `docker-status.sh` (not cAdvisor — see §5) |
| `ContainerRestartedRecently` | `increase(docker_container_restart_count[15m]) > 0` | warning | `docker-status.sh` |
| `DockerStatusExporterStale` | `time() - node_textfile_mtime_seconds{file="docker_status.prom"} > 300`, for 1m | warning | Self-monitoring — if the textfile exporter dies, the two alerts above go blind |

These three alerts have been **validated against real incidents** during development (see §14) — not untested placeholder alerts.

**Planned channel:** Telegram Bot (via an Alertmanager webhook receiver)
**Prerequisite:** user creates a bot via @BotFather, providing `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (stored in `.env`, not committed)

**Dashboard temperature thresholds (Grafana panel config, not Prometheus alert rules) — recalibrated from real data, not assumptions:**

| Metric | Warning | Critical | Note |
|---|---|---|---|
| CPU Package Temp | 70°C (avg) / 75°C (max) | 90°C (avg) / 95°C (max) | |
| GPU Temp | 65°C (avg) | 85°C (avg) | |
| CPU Fan RPM | 5000 RPM | 6500 RPM | Recalibrated — the initial default values (3000/4000) turned out to be well below this machine's normal operating range (~5100-5600 RPM at idle-to-moderate load) |
| Disk usage (/) | 85% | 95% | No Prometheus alert rule for this yet — still planned |
| RAM usage | 90% | — | No Prometheus alert rule for this yet — still planned |

## 9. Security

- Every service port (`Prometheus :9099`, `Grafana :3033`, `node_exporter :9100`, `nvidia_gpu_exporter :9835`, `cAdvisor :8081`) is bound to the Tailscale IP only — **not** `0.0.0.0`. Validated via `docker port` & `docker inspect` during development.
- Grafana uses authentication (not anonymous access) — `GF_AUTH_ANONYMOUS_ENABLED=false`.
- Resource limits (CPU/memory) are set per container in `docker-compose.yml`. **Real incident:** the initial Grafana limit (256M) turned out to be too tight for a modern Grafana build (unified storage/bleve indexing) — the container got OOM-killed repeatedly, breaking sessions/tokens and leaving the dashboard stuck "loading" indefinitely in the browser. Fixed by raising the limit to 512M; RestartCount has been stable at 0 since.
- Secrets (Telegram token, Grafana admin password) live in `.env`, gitignored, with `.env.example` as a template in the repo.

## 10. Repository Structure (current state)

```
homelab-observability/
├── PRD.md
├── README.md                        # main documentation + architecture diagram
├── docker-compose.yml
├── .env.example
├── .gitignore
├── prometheus/
│   ├── prometheus.yml               # scrape config, scrape_interval: 5s
│   └── rules/
│       └── alerting-rules.yml       # 3 alert rules (container-health + self-monitoring)
├── node-exporter-textfile/
│   └── docker-status.sh             # custom crash-loop exporter (committed;
│                                     #   its *.prom output is gitignored)
├── systemd/
│   ├── docker-status.service        # systemd unit that runs docker-status.sh
│   └── docker-status.timer          # triggers every 5 seconds
└── grafana/
    ├── dashboards/
    │   └── overview.json            # 25 custom panels, built from scratch
    └── provisioning/
        ├── datasources/             # Prometheus auto-provisioning
        └── dashboards/              # provider config

Not yet present (Phase 2/3/4):
├── prometheus/rules/recording-rules.yml   # hourly/daily downsampling
├── alertmanager/alertmanager.yml          # routing to Telegram
├── loki/loki-config.yml
└── promtail/promtail-config.yml
```

## 11. Implementation Phases — Status

1. **Phase 1 — Core metrics:** ✅ **Done.** Prometheus + node_exporter + nvidia_gpu_exporter + cAdvisor + Grafana, all bound to the Tailscale IP, resource limits in place and re-tuned based on real incidents (see §9).
2. **Phase 2 — Downsampling:** ❌ **Not started.** Recording rules for hourly/daily aggregates haven't been created.
3. **Phase 3 — Alerting:** 🟡 **Partial.** Prometheus alert rules (`ContainerCrashLooping`, etc.) are live and have been validated against real incidents. Alertmanager + Telegram Bot integration hasn't been built.
4. **Phase 4 — Logs:** ❌ **Not started.** Loki + Promtail aren't part of the stack yet.
5. **Phase 5 — Custom dashboard & polish:** ✅ **Done** (ahead of schedule — worked on in parallel with Phase 1 due to the need for repeated validation). 25 custom panels, 4 row groups (Temperature Overview, System Resources, Thermal & Cooling, GPU & Containers), every query manually validated against Prometheus, 2 bugs found & fixed (wrong RPM unit, threshold styling not rendering on the graph).
6. **Phase 6 — Portfolio documentation:** 🟡 **In progress.** This PRD + README.md.

## 12. Open Items / User Confirmation Needed

- [ ] `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (from @BotFather) — prerequisite for Phase 3
- [x] ~~Final ports for each service~~ — finalized: Prometheus `9099`, Grafana `3033`, cAdvisor `8081` (moved from 8080 due to a conflict with another project)
- [x] ~~Final scrape interval~~ — finalized: **5 seconds** (scrape, evaluation, dashboard refresh, and textfile collector timer — all consistent at the same interval)
- [x] ~~Alert threshold confirmation~~ — recalibrated from real data (see §8)
- [ ] Final project name for portfolio branding purposes (repo name, README title)
- [ ] Decision: continue to Phase 2/3/4 before pushing to GitHub, or push the Phase 1+5 state now as a checkpoint?

## 13. Success Criteria

- Stack runs stably 24/7 without disrupting the existing AI workload (overhead <5% CPU, <1GB additional RAM). *(not formally measured long-term yet)*
- Dashboard accessible from another device via Tailscale, showing real-time + historical data. ✅ Validated.
- Telegram alert successfully delivered when a threshold is breached. ❌ Not yet testable — Alertmanager doesn't exist yet. The underlying Prometheus alert rule itself **has** already been proven against a real incident (see §14).
- Repo on GitHub: clear README, diagram present, custom dashboard present, no secrets committed.
- Real historical data (not mocked) available for at least a few days before being used as a portfolio piece.

## 14. Incidents & Findings During Development (Changelog)

This section is deliberately kept as evidence of a genuine engineering process — not just "wrote the config, done." Useful material for interview conversations.

| # | Finding | Root Cause | Fix |
|---|---|---|---|
| 1 | "Running Containers" panel showed 92, manual `docker ps` showed only 59 | Query `count(container_last_seen{...})` counted stale/duplicate cAdvisor series, not unique containers | Switched to `count(count by (name) (container_memory_usage_bytes{...}))` — dedup first |
| 2 | After fix #1, the result was 58, not 59 | One container (`dify-init_permissions-1`) was crash-looping faster than the scrape interval, never caught by cAdvisor | Built `docker-status.sh` as a complementary exporter (see §5) |
| 3 | GPU temperature stuck at a low reading, initially thought to be a dead sensor | GPU was genuinely idle (0% utilization), not a bug | No fix needed — normal behavior, documented |
| 4 | Grafana dashboard stuck in infinite loading | Repeated OOM-kills (256M limit too tight for a modern Grafana build) | Raised the limit to 512M |
| 5 | 3 containers turned out to be crash-looping (`langfuse-web`, `vanna_senior_care_ui`, `clickhouse_senior_care`) | Corrupted Docker network attachment after a host reboot — containers claimed network membership but weren't actually listed as connected | Manual `docker network connect` + restart |
| 6 | GPU Fan Speed panel was always empty | Metric `nvidia_smi_fan_speed_ratio` was never exposed — the GTX 1050 Mobile has no fan-speed sensor readable via `nvidia-smi` (a hardware/driver limitation, not a config bug) | Panel removed |
| 7 | CPU Fan RPM threshold was always red | Default values (3000/3500/4000) were set before any real data existed; this machine's normal range turned out to be 5100-5600 RPM | Recalibrated thresholds to 5000/6000/6500 |
| 8 | High CPU Package temp (83-98°C) — initially suspected a monitoring bug | Genuine: system load average spiked to 6.5-7 from the cardinality explosion (see §7) plus a container crash-loop consuming 87-99% CPU | Not a dashboard bug — root cause traced to a different container, fixed at the Docker network level |
| 9 | "rpm" unit on the CPU Fan RPM panel didn't match Grafana's convention | Grafana's valid unit ID is `rotrpm`, not `rpm` (confirmed from Grafana's JS bundle) | Changed to `rotrpm` |
| 10 | Threshold colors defined on the CPU Fan RPM panel weren't rendering as a line on the graph | `custom.thresholdsStyle.mode` wasn't set (Grafana default: `off`) | Added `thresholdsStyle: {mode: "line"}` |
