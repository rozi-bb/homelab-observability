#!/usr/bin/env bash
# Bring the observability stack up at boot, and make sure it is actually
# *reachable* — not merely "Up" in `docker ps`.
#
# Why this exists (observed twice on this host, 2026-08-19 and 2026-08-20):
# after a host reboot, dockerd restores `restart: unless-stopped` containers
# but can silently fail to re-establish their published port bindings. The
# container reports Up, RestartCount stays 0, and even its healthcheck can
# pass (healthchecks run inside the container), yet from outside the host the
# port is dead:
#
#     HostConfig.PortBindings -> {"9090/tcp":[{HostIp:100.77.191.60,...}]}   (wanted)
#     NetworkSettings.Ports   -> {}                                          (actual)
#
# dockerd logged `error locating sandbox id ... not found` during that restore.
# Because Docker never considers this a failure, `restart: unless-stopped`
# never kicks in — the stack looks healthy and serves nothing. Plain
# `docker compose up -d` does not repair it either: the compose config hash is
# unchanged, so compose declares the container up to date and leaves it alone.
# Only recreating the container rebuilds the sandbox and the binding.
#
# So: wait for the Tailscale IP to exist (every port binds to it, and binding
# to a missing address fails), converge with `up -d`, then verify the actual
# runtime bindings and force-recreate only the services that came back broken.

set -uo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COMPOSE_DIR" || exit 1

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
: "${TAILSCALE_IP:?TAILSCALE_IP must be set in .env}"

log() { echo "[boot-up] $*"; }

# 1. Wait for the Tailscale address. Ports are bound to it explicitly, so
#    starting before tailscaled has assigned it guarantees a broken stack.
# Deliberately not a `ip ... | grep -q` pipeline: under `set -o pipefail`,
# grep -q exits as soon as it matches, `ip` then dies on SIGPIPE, and pipefail
# reports the whole pipeline as failed — so the check returns "not found" even
# when the address is present. Capture first, match in-shell.
has_tailscale_ip() {
    local addrs
    addrs="$(ip -4 -o addr show 2>/dev/null)" || return 1
    [[ "$addrs" == *"inet ${TAILSCALE_IP}/"* ]]
}

log "waiting for ${TAILSCALE_IP} to be assigned (timeout 120s)..."
for _ in $(seq 1 120); do
    has_tailscale_ip && break
    sleep 1
done
if ! has_tailscale_ip; then
    log "ERROR: ${TAILSCALE_IP} never appeared; refusing to start (ports would fail to bind)"
    exit 1
fi
log "${TAILSCALE_IP} is up"

# 2. Normal convergence.
log "docker compose up -d"
docker compose up -d

# 3. Verify what actually got published, and repair what didn't. A service is
#    broken when compose says it wants port bindings but the running container
#    has none.
broken=()
while read -r svc; do
    [ -z "$svc" ] && continue
    cid="$(docker compose ps -q "$svc" 2>/dev/null)"
    [ -z "$cid" ] && { log "WARN: $svc has no container"; broken+=("$svc"); continue; }

    wanted="$(docker inspect "$cid" --format '{{len .HostConfig.PortBindings}}' 2>/dev/null || echo 0)"
    actual="$(docker inspect "$cid" --format '{{len .NetworkSettings.Ports}}' 2>/dev/null || echo 0)"
    if [ "$wanted" -gt 0 ] && [ "$actual" -eq 0 ]; then
        log "BROKEN: $svc wants $wanted port binding(s) but has none published"
        broken+=("$svc")
    fi
done < <(docker compose config --services)

if [ ${#broken[@]} -gt 0 ]; then
    log "recreating: ${broken[*]}"
    docker compose up -d --force-recreate "${broken[@]}"
else
    log "all services have their expected port bindings"
fi

log "done"
