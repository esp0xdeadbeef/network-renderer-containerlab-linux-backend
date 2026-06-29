#!/usr/bin/env bash
set -euo pipefail

topo_file="${CLAB_TOPO_FILE:-fabric.clab.yml}"
bridge_wait_seconds="${CLAB_BRIDGE_WAIT_SECONDS:-120}"
docker_wait_seconds="${CLAB_DOCKER_WAIT_SECONDS:-120}"

required_bridges() {
  awk '
    $1 == "clab.link.bridge:" && $2 != "" { print $2 }
  ' "${topo_file}" | sort -u
}

wait_for_required_bridges() {
  local deadline=$((SECONDS + bridge_wait_seconds))
  local missing=()
  local bridge

  mapfile -t missing < <(
    while read -r bridge; do
      [[ -n "${bridge}" ]] || continue
      if ! ip link show "${bridge}" >/dev/null 2>&1; then
        printf '%s\n' "${bridge}"
      fi
    done < <(required_bridges)
  )

  while ((${#missing[@]} > 0)) && ((SECONDS < deadline)); do
    sleep 1
    mapfile -t missing < <(
      while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        if ! ip link show "${bridge}" >/dev/null 2>&1; then
          printf '%s\n' "${bridge}"
        fi
      done < <(required_bridges)
    )
  done

  if ((${#missing[@]} > 0)); then
    printf 'missing required host bridges after %ss:\n' "${bridge_wait_seconds}" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

wait_for_docker() {
  # FS-960-HDS-010-SDS-016-SMS-050: privileged Docker inspection with distinguishable
  # failure diagnostics (permission denial, daemon absence, sudo misconfiguration).
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker >/dev/null 2>&1 || true
  fi

  local docker_cmd=(docker)
  local euid="${CLAB_TEST_EUID:-${EUID:-$(id -u 2>/dev/null || echo 0)}}"
  if [[ "${euid}" -ne 0 ]]; then
    if [[ "${CLAB_TEST_DISABLE_SUDO:-0}" != "1" ]] && command -v sudo >/dev/null 2>&1; then
      docker_cmd=(sudo -n docker)
    fi
  fi

  local deadline=$((SECONDS + docker_wait_seconds))
  local last_stderr=""
  while ((SECONDS < deadline)); do
    if last_stderr="$("${docker_cmd[@]}" info 2>&1 >/dev/null)"; then
      return 0
    fi
    sleep 1
  done

  # FS-960-HDS-010-SDS-016-SMS-050: distinguishable failure diagnostics.
  if [[ "${last_stderr}" == *"permission denied"* ]] || [[ "${last_stderr}" == *"Permission denied"* ]]; then
    printf 'docker permission denied — user not authorized to access Docker daemon (verify docker group membership or sudo NOPASSWD configuration)\n' >&2
    exit 1
  elif [[ "${last_stderr}" == *"password is required"* ]]; then
    printf 'docker privilege check failed — sudo -n requires NOPASSWD or an active sudo ticket\n' >&2
    exit 1
  else
    printf 'docker did not become ready after %ss (daemon may not be running or unreachable)\n' "${docker_wait_seconds}" >&2
    exit 1
  fi
}

wait_for_docker
docker-clab-frr-plus-tooling/build.sh

# Example switching reuses the same VM and lab name (`fabric`).
# This script runs inside a dedicated test VM, so clear any stale lab state
# before deploying the next rendered topology.
containerlab destroy --all --cleanup --yes >/dev/null 2>&1 || true
docker ps -aq --filter 'name=^clab-fabric-' | xargs -r docker rm -f >/dev/null 2>&1 || true

wait_for_required_bridges
containerlab deploy -t "${topo_file}" --reconfigure
containerlab inspect -t "${topo_file}" >/dev/null

for c in $(docker ps --format '{{.Names}}' | grep clab-fabric | sort )
do
  echo "=================================================="
  echo "NODE: $c"
  echo "--------------------------------------------------"
  echo

  ROLE=$(echo "$c" | sed 's/.*-site-a-//')
  echo "ROLE: $ROLE"
  echo "TIME: $(date -Iseconds)"
  echo

  echo "[ ip -br link ]"
  docker exec "$c" ip -br link
  echo

  echo "[ ip -br addr ]"
  docker exec "$c" ip -br addr
  echo

  echo "[ ip route ]"
  docker exec "$c" ip route
  echo

  echo "[ ip -6 route ]"
  docker exec "$c" ip -6 route
  echo

  echo "[ ip neigh ]"
  docker exec "$c" ip neigh
  echo

  echo "[ ip route get 8.8.8.8 ]"
  docker exec "$c" ip route get 8.8.8.8 || true
  echo

  #echo "[ traceroute -> s-router-access (10.10.0.0) ]"
  #docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 10.10.0.0 || true
  #echo

  #echo "[ traceroute -> s-router-core-isp-a (10.10.0.2) ]"
  #docker exec "$c" traceroute -I -n -w 1 -q 1 -m 5 10.10.0.2 || true
  #echo

  echo "[ traceroute -> internet (8.8.8.8) ]"
  docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 8.8.8.8 || true
  echo

  echo " [ FIREWALL - nft list ruleset]"
  docker exec "$c" nft list ruleset || true
  echo

done
