#!/usr/bin/env bash
set -euo pipefail

topo_file="${CLAB_TOPO_FILE:-fabric.clab.yml}"
bridge_wait_seconds="${CLAB_BRIDGE_WAIT_SECONDS:-120}"
docker_wait_seconds="${CLAB_DOCKER_WAIT_SECONDS:-120}"
docker_info_timeout_seconds="${CLAB_DOCKER_INFO_TIMEOUT_SECONDS:-10}"
systemctl_timeout_seconds="${CLAB_SYSTEMCTL_TIMEOUT_SECONDS:-60}"
cleanup_timeout_seconds="${CLAB_CLEANUP_TIMEOUT_SECONDS:-120}"
deploy_timeout_seconds="${CLAB_DEPLOY_TIMEOUT_SECONDS:-900}"
deploy_idle_timeout_seconds="${CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS:-180}"
deploy_attempts="${CLAB_DEPLOY_ATTEMPTS:-3}"
deploy_retry_delay_seconds="${CLAB_DEPLOY_RETRY_DELAY_SECONDS:-5}"
deploy_max_workers="${CLAB_DEPLOY_MAX_WORKERS:-1}"
containerlab_api_timeout="${CLAB_CONTAINERLAB_API_TIMEOUT:-10m}"

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
    timeout --foreground "${systemctl_timeout_seconds}" \
      systemctl start docker >/dev/null 2>&1 || true
  fi

  hash -r 2>/dev/null || true

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
    if last_stderr="$(timeout --foreground "${docker_info_timeout_seconds}" "${docker_cmd[@]}" info 2>&1 >/dev/null)"; then
      return 0
    fi
    if [[ "${last_stderr}" == *"permission denied"* ]] || [[ "${last_stderr}" == *"Permission denied"* ]]; then
      printf 'docker permission denied — user not authorized to access Docker daemon (verify docker group membership or sudo NOPASSWD configuration)\n' >&2
      exit 1
    elif [[ "${last_stderr}" == *"password is required"* ]]; then
      printf 'docker privilege check failed — sudo -n requires NOPASSWD or an active sudo ticket\n' >&2
      exit 1
    fi
    sleep 1
  done

  # FS-960-HDS-010-SDS-016-SMS-050: distinguishable failure diagnostics.
  printf 'docker did not become ready after %ss (daemon may not be running or unreachable)\n' "${docker_wait_seconds}" >&2
  exit 1
}

cleanup_stale_lab() {
  timeout --foreground "${cleanup_timeout_seconds}" \
    containerlab destroy --all --cleanup --yes >/dev/null 2>&1 || true
  docker ps -aq --filter 'name=^clab-fabric-' | xargs -r docker rm -f >/dev/null 2>&1 || true
}

stop_containerlab_deploy() {
  local deploy_pid="$1"
  kill -- "-${deploy_pid}" >/dev/null 2>&1 || kill "${deploy_pid}" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL -- "-${deploy_pid}" >/dev/null 2>&1 || kill -KILL "${deploy_pid}" >/dev/null 2>&1 || true
}

run_containerlab_deploy_once() {
  local deploy_log="$1"
  local deploy_pipe
  local deploy_fd
  local deploy_pid
  local line
  local rc
  local saw_erro=0
  local saw_idle_timeout=0
  local message

  deploy_pipe="$(mktemp -u "${TMPDIR:-/tmp}/containerlab-deploy.XXXXXX.pipe")"
  mkfifo "${deploy_pipe}"
  if command -v setsid >/dev/null 2>&1; then
    setsid timeout --foreground "${deploy_timeout_seconds}" \
      containerlab deploy -t "${topo_file}" --reconfigure --timeout "${containerlab_api_timeout}" --max-workers "${deploy_max_workers}" \
      >"${deploy_pipe}" 2>&1 &
  else
    timeout --foreground "${deploy_timeout_seconds}" \
      containerlab deploy -t "${topo_file}" --reconfigure --timeout "${containerlab_api_timeout}" --max-workers "${deploy_max_workers}" \
      >"${deploy_pipe}" 2>&1 &
  fi
  deploy_pid="$!"
  exec {deploy_fd}<"${deploy_pipe}"

  while true; do
    if ! IFS= read -r -t "${deploy_idle_timeout_seconds}" line <&"${deploy_fd}"; then
      if kill -0 "${deploy_pid}" >/dev/null 2>&1; then
        saw_idle_timeout=1
        message="Containerlab deploy produced no output for ${deploy_idle_timeout_seconds}s; stopping attempt"
        printf '%s\n' "${message}" >&2
        printf '%s\n' "${message}" >>"${deploy_log}"
        stop_containerlab_deploy "${deploy_pid}"
      fi
      break
    fi
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >>"${deploy_log}"
    if [[ "${line}" =~ (^|[[:space:]])ERRO([[:space:]]|$) ]]; then
      saw_erro=1
      printf 'Containerlab deploy emitted ERRO; stopping attempt\n' >&2
      stop_containerlab_deploy "${deploy_pid}"
      break
    fi
  done

  exec {deploy_fd}<&-
  wait "${deploy_pid}"
  rc="$?"
  rm -f "${deploy_pipe}"

  if ((saw_erro == 1)); then
    return 66
  elif ((saw_idle_timeout == 1)); then
    return 67
  fi
  return "${rc}"
}

deploy_containerlab() {
  local attempt
  local deploy_log
  local rc
  local retryable

  deploy_log="$(mktemp "${TMPDIR:-/tmp}/containerlab-deploy.XXXXXX.log")"
  for attempt in $(seq 1 "${deploy_attempts}"); do
    if ((attempt > 1)); then
      printf 'retrying Containerlab deploy after cleanup (attempt %s/%s)\n' "${attempt}" "${deploy_attempts}" >&2
      cleanup_stale_lab
      wait_for_required_bridges
      sleep "${deploy_retry_delay_seconds}"
    fi

    : >"${deploy_log}"
    set +e
    run_containerlab_deploy_once "${deploy_log}"
    rc="$?"
    set -e

    if [[ "${rc}" -eq 0 ]] && ! grep -Eq '(^|[[:space:]])ERRO([[:space:]]|$)' "${deploy_log}"; then
      rm -f "${deploy_log}"
      return 0
    fi

    retryable=0
    if grep -q 'failed to Statfs "/proc/0/ns/net"' "${deploy_log}"; then
      printf 'Containerlab deploy hit netns pid 0 error on attempt %s/%s\n' "${attempt}" "${deploy_attempts}" >&2
      retryable=1
    elif grep -Eq 'failed deploy links.*file exists' "${deploy_log}"; then
      printf 'Containerlab deploy hit stale link file-exists error on attempt %s/%s\n' "${attempt}" "${deploy_attempts}" >&2
      retryable=1
    elif [[ "${rc}" -eq 124 ]]; then
      printf 'Containerlab deploy timed out after %ss on attempt %s/%s\n' "${deploy_timeout_seconds}" "${attempt}" "${deploy_attempts}" >&2
      retryable=1
    elif [[ "${rc}" -eq 67 ]]; then
      printf 'Containerlab deploy idle-timed out after %ss on attempt %s/%s\n' "${deploy_idle_timeout_seconds}" "${attempt}" "${deploy_attempts}" >&2
      retryable=1
    else
      printf 'Containerlab deploy failed on attempt %s/%s; see log above\n' "${attempt}" "${deploy_attempts}" >&2
      rm -f "${deploy_log}"
      return 1
    fi

    if ((retryable != 1 || attempt >= deploy_attempts)); then
      printf 'Containerlab deploy did not complete cleanly after %s attempt(s)\n' "${attempt}" >&2
      rm -f "${deploy_log}"
      return 1
    fi
  done

  rm -f "${deploy_log}"
  return 1
}

wait_for_docker
docker-clab-frr-plus-tooling/build.sh

# Example switching reuses the same VM and lab name (`fabric`).
# This script runs inside a dedicated test VM, so clear any stale lab state
# before deploying the next rendered topology.
cleanup_stale_lab

wait_for_required_bridges
deploy_containerlab
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
  if docker exec "$c" sh -c 'ip route show default | grep -q "^default "'; then
    docker exec "$c" ip route get 8.8.8.8 || true
  else
    echo "skipped: no main-table default route"
  fi
  echo

  #echo "[ traceroute -> s-router-access (10.10.0.0) ]"
  #docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 10.10.0.0 || true
  #echo

  #echo "[ traceroute -> s-router-core-isp-a (10.10.0.2) ]"
  #docker exec "$c" traceroute -I -n -w 1 -q 1 -m 5 10.10.0.2 || true
  #echo

  echo "[ traceroute -> internet (8.8.8.8) ]"
  if docker exec "$c" sh -c 'ip route show default | grep -q "^default "'; then
    docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 8.8.8.8 || true
  else
    echo "skipped: no main-table default route"
  fi
  echo

  echo " [ FIREWALL - nft list ruleset]"
  docker exec "$c" nft list ruleset || true
  echo

done
