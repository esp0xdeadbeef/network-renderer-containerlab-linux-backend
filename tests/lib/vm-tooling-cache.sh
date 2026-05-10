#!/usr/bin/env bash
set -euo pipefail

ensure_host_tooling_image_cache() {
  local current_id=""
  local cached_id=""

  mkdir -p "${host_cache_root}"

  if ! docker version >/dev/null 2>&1; then
    log "host Docker daemon unavailable; skipping host-side ${tooling_image} cache export"
    host_tooling_cache_available=0
    return 0
  fi

  while ! mkdir "${host_image_cache_lock}" 2>/dev/null; do
    sleep 1
  done

  trap 'rmdir "${host_image_cache_lock}" >/dev/null 2>&1 || true' RETURN

  if ! docker image inspect "${tooling_image}" >/dev/null 2>&1; then
    log "building ${tooling_image} on host"
    ( cd "${repo_root}" && ./docker-clab-frr-plus-tooling/build.sh )
  fi

  current_id="$(docker image inspect --format '{{.Id}}' "${tooling_image}")"
  if [[ -f "${host_image_cache_id}" ]]; then
    cached_id="$(<"${host_image_cache_id}")"
  fi

  if [[ ! -f "${host_image_cache_tar}" || "${cached_id}" != "${current_id}" ]]; then
    log "exporting ${tooling_image} to host cache"
    docker save -o "${host_image_cache_tar}.tmp" "${tooling_image}"
    mv "${host_image_cache_tar}.tmp" "${host_image_cache_tar}"
    printf '%s\n' "${current_id}" > "${host_image_cache_id}"
  fi
}

stage_tooling_cache_into_vm() {
  local host_id
  local vm_id=""

  ensure_host_tooling_image_cache
  if [[ "${host_tooling_cache_available}" -ne 1 ]]; then
    return 0
  fi
  host_id="$(<"${host_image_cache_id}")"

  vm_id="$(ssh_vm_once "test -f '${vm_image_cache_id}' && cat '${vm_image_cache_id}'" 2>/dev/null || true)"
  if [[ "${vm_id}" == "${host_id}" ]]; then
    return 0
  fi

  log "staging ${tooling_image} cache into the VM"
  scp_vm_file "${host_image_cache_tar}" "${vm_image_cache_tar}"
  scp_vm_file "${host_image_cache_id}" "${vm_image_cache_id}"
}
