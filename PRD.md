# PRD — Homelab Observability Stack

> **Implementation status:** Phase 1 (core metrics) and Phase 5 (custom dashboard) are complete, validated against real data, and hardened by a dedicated production-readiness audit (12 alert rules, reliable boot recovery, a repeatable query validator — see §14 #13-#20). Phase 2 (downsampling), Phase 3 (Alertmanager + Telegram — the Prometheus-side alert rules already exist, Telegram integration doesn't), and Phase 4 (logs/Loki) have not been started. Details per phase in §11.

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
| nvidia_gpu_exporter | `utkuozdemir/nvidia_gpu_exporter:latest` | `9835` | Temperature, utilization, memory of the GTX 1050 GPU | ✅ Running (GPU fan speed **not available via this exporter** — the GTX 1050 Mobile doesn't expose that sensor through `nvidia-smi`; GPU fan RPM is tracked separately via `node_exporter`'s hwmon collector instead — see §14 #12) |
| cAdvisor | `gcr.io/cadvisor/cadvisor:latest` | `8081` (moved from default `8080`, which conflicted with another project's dev stack on the same machine) | Per-container Docker metrics | ✅ Running |
| `docker-status.sh` (custom) | bash script + systemd timer, not a container | — | Exports `docker inspect` RestartCount/State to node_exporter's textfile collector, refreshed every 5s | ✅ Running |
| `boot-up.sh` (custom) | bash script + systemd unit, not a container | — | Boot-time convergence: waits for the Tailscale address, runs `docker compose up -d`, then repairs services that came back without their port bindings (see §14 #13) | ✅ Running |
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
| Raw (scrape interval **5 seconds**, finalized after resource testing) | Direct Prometheus scrape | 15 days **or** 5GB, whichever is hit first | ✅ Active |
| Hourly aggregate (avg/min/max) | Prometheus recording rules | 90 days | ❌ Not built |
| Daily aggregate (avg/min/max) | Prometheus recording rules | 2 years | ❌ Not built |

The 5GB size cap (`--storage.tsdb.retention.size`) was added during the production-readiness audit as a second, harder bound — see §14 #14. Current actual usage is a small fraction of that (~190MB at time of writing).

**Why 5 seconds (not Prometheus's 15-second default)?** The 6-core/12-thread CPU on this machine has enough headroom for 3x more frequent scraping, and it suits a demo/portfolio context where the dashboard needs to feel "alive" (visibly updating graphs). Trade-off: faster time-series disk growth (~3.5GB per 15-day retention window vs. ~1.2GB at 15-second intervals, based on ~9,000 active series under normal conditions) — still well under available storage, but worth watching since the host disk is already crowded by other workloads.

**A real cardinality incident (recorded as both evidence and a lesson learned):** a container stuck in a continuous crash loop (a bug in an unrelated project on the same machine, not a bug in this stack) caused Docker to keep creating new virtual network interfaces (`veth*`) on every restart. cAdvisor recorded each `veth*` as a new time series, and Prometheus kept them until they expired. Total time series spiked from ~9,000 to **~127,000** (a 13x increase) within hours, starving Prometheus itself of CPU (it got throttled) and contributing to elevated system load/CPU temperature. Root cause was traced to a specific container, fixed at the Docker network level, and load average returned to normal within minutes of the fix. **Not yet implemented as a preventive fix:** add `metric_relabel_configs` to the cAdvisor scrape config to drop the `id` label that's the source of the cardinality growth.

## 8. Alerting

**Status: 11 Prometheus-native alert rules are live and actively evaluated. Routing to Telegram (Alertmanager) has not been built** — alerts currently only show up as "firing" in the Prometheus UI, with no outbound notification yet.

### Alert rules currently running (`prometheus/rules/alerting-rules.yml`)

| Alert | Condition | Severity | Data source |
|---|---|---|---|
| `ContainerCrashLooping` | `increase(docker_container_restart_count[15m]) > 2`, for 2m | critical | `docker-status.sh` (not cAdvisor — see §5) |
| `ContainerRestartedRecently` | `increase(docker_container_restart_count[15m]) > 0` | warning | `docker-status.sh` |
| `DockerStatusExporterStale` | `time() - node_textfile_mtime_seconds{file=~".*/docker_status\.prom"} > 300`, for 1m | warning | Self-monitoring — if the textfile exporter dies, the two alerts above go blind |
| `DiskSpaceWarning` / `DiskSpaceCritical` | root filesystem > 85% (for 10m) / > 95% (for 5m) | warning / critical | node_exporter |
| `MemoryHigh` | RAM used > 90%, for 10m | warning | node_exporter |
| `CpuTemperatureWarning` / `CpuTemperatureCritical` | CPU Package > 85°C (for 5m) / > 95°C (for 2m) | warning / critical | node_exporter hwmon — Package sensor specifically, not a core average (§6) |
| `GpuTemperatureWarning` | GPU > 85°C, for 5m | warning | nvidia_gpu_exporter |
| `ExporterDown` | `up == 0`, for 2m | critical | Prometheus itself — without this a dead exporter just looks like flat graphs |
| `PrometheusTargetsMissing` | `count(up) < 4`, for 5m | critical | Catches the reboot failure mode in §14 #13, where a container is Up and passing its healthcheck but unreachable from outside the host |

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
├── scripts/
│   └── boot-up.sh                   # boot convergence + port-binding repair
├── systemd/
│   ├── docker-status.service        # systemd unit that runs docker-status.sh
│   ├── docker-status.timer          # triggers every 5 seconds
│   └── homelab-observability.service # runs boot-up.sh at boot
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

1. **Phase 1 — Core metrics:** ✅ **Done.** Prometheus + node_exporter + nvidia_gpu_exporter + cAdvisor + Grafana, all bound to the Tailscale IP, resource limits in place and re-tuned based on real incidents (see §9). Hardened in a dedicated audit pass (§14 #13-#19): reliable boot recovery, a hard TSDB size cap, container healthchecks, pinned datasource uid, and every panel query re-validated against `sensors`/`df`/`free`/`docker` as ground truth.
2. **Phase 2 — Downsampling:** ❌ **Not started.** Recording rules for hourly/daily aggregates haven't been created.
3. **Phase 3 — Alerting:** 🟡 **Partial.** Prometheus alert rules (`ContainerCrashLooping`, etc.) are live and have been validated against real incidents. Alertmanager + Telegram Bot integration hasn't been built.
4. **Phase 4 — Logs:** ❌ **Not started.** Loki + Promtail aren't part of the stack yet.
5. **Phase 5 — Custom dashboard & polish:** ✅ **Done** (ahead of schedule — worked on in parallel with Phase 1 due to the need for repeated validation). 25 custom panels grouped into a Maintenance Log plus 4 row sections (CPU, GPU, System & Storage, Containers — CPU and GPU deliberately kept in fully separate sections, each with its own temp stats, usage, and fan RPM), every query manually validated against Prometheus, several bugs found & fixed along the way (wrong RPM unit, threshold styling not rendering on the graph, duplicate legend rows from an instance-label change).
6. **Phase 6 — Portfolio documentation:** 🟡 **In progress.** This PRD + README.md.

## 12. Open Items / User Confirmation Needed

- [ ] `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (from @BotFather) — prerequisite for Phase 3
- [x] ~~Final ports for each service~~ — finalized: Prometheus `9099`, Grafana `3033`, cAdvisor `8081` (moved from 8080 due to a conflict with another project)
- [x] ~~Final scrape interval~~ — finalized: **5 seconds** (scrape, evaluation, dashboard refresh, and textfile collector timer — all consistent at the same interval)
- [x] ~~Alert threshold confirmation~~ — recalibrated from real data (see §8)
- [ ] Final project name for portfolio branding purposes (repo name, README title)
- [ ] Decision: continue to Phase 2/3/4 before pushing to GitHub, or push the Phase 1+5 state now as a checkpoint?

## 13. Success Criteria

- Stack runs stably 24/7 without disrupting the existing AI workload (overhead <5% CPU, <1GB additional RAM). ✅ Measured during the production-readiness audit: all 5 containers combined at ~1.8% of one core (≈0.15% of the host's 12 threads) and ~424MB RAM — well under target. Not yet measured over a multi-week window.
- Dashboard accessible from another device via Tailscale, showing real-time + historical data. ✅ Validated.
- Telegram alert successfully delivered when a threshold is breached. ❌ Not yet testable — Alertmanager doesn't exist yet. The underlying Prometheus alert rules **have** already been proven against real incidents (see §14) — 12 rules total, covering container health, host resources, and self-monitoring.
- Repo on GitHub: clear README, diagram present, custom dashboard present, no secrets committed. ✅ Validated — public at github.com/rozi-bb/homelab-observability.
- Real historical data (not mocked) available for at least a few days before being used as a portfolio piece. ✅ Data on hand back to August 19, 2026, with visible gaps from two host reboots — an honest gap (§14 #13) is arguably more useful portfolio material than an unbroken line would have been.

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
| 11 | Network Throughput panel showed suspiciously tiny values (hundreds of B/s) that never reflected real WiFi/Tailscale activity | `node_exporter` ran on the regular Docker bridge network, not `network_mode: host`. `/proc/net/dev` reflects the *reading process's own* network namespace regardless of how `/proc` is mounted, so node_exporter was only ever reporting its own virtual interface into the Docker bridge — never the host's real `wlo1`/`tailscale0` | Switched `node_exporter` to `network_mode: host` with an explicit `--web.listen-address=${TAILSCALE_IP}:9100` (since `ports:` is ignored under host networking, this flag is what keeps it off `0.0.0.0`); updated the Prometheus scrape target from the Docker DNS name to the literal Tailscale IP, since the container is no longer on the `observability` bridge network |
| 12 | GPU Fan Speed panel had been removed entirely (incident #6) on the assumption fan RPM wasn't available for this GPU at all | `nvidia-smi` genuinely doesn't expose it, but that's not the only source: `node_exporter`'s hwmon collector already picks up `fan1`/`fan2` from the `asus-isa-0000` sensor (the laptop's embedded controller, not the GPU itself) — `sensors asus-isa-0000` confirmed `cpu_fan` and `gpu_fan` are both read this way | Split the existing "CPU Fan RPM" panel (which had silently been graphing both fans together) into two: CPU Fan RPM (`fan1`) and a new GPU Fan RPM (`fan2`), with separate thresholds recalibrated to this machine's real values (5300 RPM / 4800 RPM) |
| 13 | **Stack came back from a host reboot unreachable.** `docker ps` showed every container Up with RestartCount 0, healthchecks passed, yet nothing outside the host could connect | dockerd restored the `restart: unless-stopped` containers but silently failed to re-publish their ports — `HostConfig.PortBindings` had the mapping, `NetworkSettings.Ports` was `{}`, and dockerd logged `error locating sandbox id ... not found`. Docker never treats this as a failure, so `unless-stopped` never fires; `docker compose up -d` does not repair it either, because the config hash is unchanged so compose reports the container up to date. Observed on two consecutive reboots (2026-08-19, 2026-08-20) — it is systematic, not a fluke | Added `scripts/boot-up.sh` + a `homelab-observability.service` systemd unit: waits for the Tailscale address to actually exist (ports bind to it explicitly), converges with `docker compose up -d`, then compares wanted vs. published bindings and force-recreates only the services that came back broken |
| 14 | Prometheus had a 15-day time retention but no size cap, on a host disk sitting at 94% | `--storage.tsdb.retention.time` bounds *age*, not *bytes*. A cardinality spike (this stack already had one: ~9k → ~127k series in hours, §7) turns "15 days of data" into an unbounded number of bytes. Prometheus filling the disk would have taken all ~60 containers on the host down with it | Added `--storage.tsdb.retention.size=5GB` as a hard second bound (current usage: ~190MB) |
| 15 | `DockerStatusExporterStale` could never fire — a watchdog that was itself blind | The rule matched `node_textfile_mtime_seconds{file="docker_status.prom"}`, but node_exporter labels that metric with the full in-container path, `file="/textfile_collector/docker_status.prom"`. The selector matched nothing, so the alert sat permanently inactive and would never have reported the crash-loop detection going dark | Changed the matcher to a suffix regex (`file=~".*/docker_status\.prom"`), which also survives a change of mount path |
| 16 | `docker-status.sh` burned ~2s of CPU every 5s — roughly 40% of a core, continuously, just to count container restarts | The script ran one `docker inspect` per container: 57 process spawns and 57 daemon round-trips per run, on a host already contended for CPU | Replaced the loop with a single batched `docker inspect $(docker ps -aq)`. Measured 1.72s → 0.17s wall, ~2.0s → ~0.07s CPU — about 25× cheaper for identical output |
| 17 | The `topk(10, ...)` in "Per-Container CPU Usage" rendered far more than 10 series, many of them broken fragments | `topk` is re-evaluated independently at every step of a range query, so membership of the top-10 changes as containers rise and fall. Measured over a 6h window: 25 series returned, 12 of them partial | Rank once over the whole range instead of per step: `<series> and topk(10, avg_over_time(<series>[$__range:5m]))`. Benchmarked against the alternatives — this returns exactly 10 unbroken series and stays cheap (0.00s at 6h, 0.32s at 24h) |
| 18 | Every panel relied on "whichever datasource happens to be default", and the provisioned datasource had no fixed `uid` | Grafana assigns a random uid to a datasource provisioned without one, so a `git clone` + `docker compose up` on another machine produces a dashboard whose panels point at a uid that does not exist there — the core reproducibility claim of this repo was untested and would have failed | Pinned `uid: homelab-prometheus` in datasource provisioning and referenced it explicitly on all 20 panels and their targets |
| 19 | The three CPU Package stat cards (Avg/Min/Max) reported temperatures a few degrees off | They lacked the `instance` filter the matching timeseries panels already had, so their `*_over_time` window spanned both the current series and the stale `node_exporter:9100` series left behind by the `network_mode: host` change (#11). `avg()` then averaged two series of very different lengths as equals. Measured: 68.73°C blended vs. 64.85°C correct | Added the same `instance` filter used by the timeseries panels |
| 20 | Changing `GF_SECURITY_ADMIN_PASSWORD` in `.env` and restarting did nothing — old and new password both rejected | `GF_SECURITY_ADMIN_PASSWORD` is only read on first-ever database initialization; Grafana silently ignores it afterward. The env change did nothing, and the resulting repeated failed logins (old password, which the DB still had, tried against a UI that had just been told to expect the new one) tripped Grafana's brute-force lockout, which then rejected the *correct* password too | `docker exec obs-grafana grafana cli admin reset-admin-password '<pw>'` resets it directly in the DB; the `login_attempt` table had to be cleared by hand (via a `docker cp` round-trip) to lift the lockout, then the copied-back file needed `chown 472:472` since `docker cp` restores it as root and the Grafana process can't open a db file it doesn't own — documented in [README](README.md#changing-the-grafana-admin-password) so this doesn't get rediscovered the hard way twice |
| 21 | CPU Fan RPM threshold (5300, user-supplied as "the hardware's rated max") sat below the sensor's *actual* sustained reading — sensor showed 100% of a 6h window above 5300, 15-day average 5420 RPM | No official ASUS spec publishes a max RPM for this fan; the closest reference found (aftermarket exact-fit replacement parts for this model) cites ~5000 RPM, itself below the observed 5600 RPM peak. A fan physically cannot exceed its true mechanical max, so a threshold it exceeds constantly cannot have been that max — it was an unverified estimate treated as a spec | Recalibrated both fan thresholds from 15 days of `max_over_time`/`avg_over_time` data instead of an external number: CPU green/yellow/red at (—/5600/5900), GPU at (—/5100/5400). CPU Package temp was 56°C at the time despite the fan running near its ceiling — the cooling is working as designed, this was a threshold-calibration issue, not a hardware fault |
