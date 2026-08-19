#!/usr/bin/env bash
# Exports per-container Docker restart count + state as Prometheus textfile
# metrics for node_exporter's textfile collector.
#
# Why this exists: cAdvisor only reports a container's stats while it is
# actually "up" at scrape time. A container stuck in a fast restart loop
# (crashing faster than the scrape interval) can show ZERO data points in
# cAdvisor/Prometheus, making it invisible to cAdvisor-based alerts. Docker
# itself tracks RestartCount as a persistent counter regardless of whether
# the container is up right now, so `docker inspect` catches it reliably.
#
# Run via cron every minute (see install instructions below).

set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT_DIR}/docker_status.prom"
TMP="${OUT}.tmp.$$"

{
  echo "# HELP docker_container_restart_count Number of times Docker has restarted this container (persistent counter, survives fast crash loops)"
  echo "# TYPE docker_container_restart_count counter"
  echo "# HELP docker_container_state Current state of the container, one series per (name,state) with value 1"
  echo "# TYPE docker_container_state gauge"

  docker ps -a --format '{{.Names}}' | while read -r name; do
    [ -z "${name}" ] && continue
    restarts=$(docker inspect "${name}" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
    state=$(docker inspect "${name}" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    echo "docker_container_restart_count{name=\"${name}\"} ${restarts}"
    echo "docker_container_state{name=\"${name}\",state=\"${state}\"} 1"
  done
} > "${TMP}"

mv "${TMP}" "${OUT}"
