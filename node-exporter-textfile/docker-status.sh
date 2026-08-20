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
# Run via the docker-status.timer systemd unit (every 5s, matching the
# Prometheus scrape interval). See systemd/ in the repo root.

set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT_DIR}/docker_status.prom"
TMP="${OUT}.tmp.$$"

# Write-to-temp-then-rename keeps node_exporter from ever reading a half-written
# file, but the temp file leaks if we're killed mid-run (a host reboot during a
# `docker inspect` loop left one behind on 2026-08-19). Clean up on any exit,
# and sweep any orphans from previous runs that died before this trap existed.
trap 'rm -f "${TMP}"' EXIT INT TERM
find "${OUT_DIR}" -maxdepth 1 -name 'docker_status.prom.tmp.*' -mmin +5 -delete 2>/dev/null || true

{
  echo "# HELP docker_container_restart_count Number of times Docker has restarted this container (persistent counter, survives fast crash loops)"
  echo "# TYPE docker_container_restart_count counter"
  echo "# HELP docker_container_state Current state of the container, one series per (name,state) with value 1"
  echo "# TYPE docker_container_state gauge"

  # One `docker inspect` for every container at once, rather than one call per
  # container. The per-container loop cost ~2s of CPU per run on this host (57
  # containers => 57 process spawns + 57 daemon round-trips); at a 5s timer
  # interval that was ~40% of a core burned continuously just to count
  # restarts. Batching it is the same data for roughly a tenth of the cost.
  #
  # `docker ps -aq` can legitimately be empty (no containers at all), and
  # `docker inspect` with no arguments is an error, so guard for that.
  ids=$(docker ps -aq)
  if [ -n "${ids}" ]; then
    # shellcheck disable=SC2086
    docker inspect ${ids} --format \
      '{{.Name}}|{{.RestartCount}}|{{.State.Status}}' 2>/dev/null |
    while IFS='|' read -r name restarts state; do
      name="${name#/}"                       # inspect prefixes names with "/"
      [ -z "${name}" ] && continue
      echo "docker_container_restart_count{name=\"${name}\"} ${restarts:-0}"
      echo "docker_container_state{name=\"${name}\",state=\"${state:-unknown}\"} 1"
    done
  fi
} > "${TMP}"

mv "${TMP}" "${OUT}"
