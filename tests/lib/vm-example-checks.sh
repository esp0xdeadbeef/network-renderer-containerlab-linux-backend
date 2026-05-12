#!/usr/bin/env bash
set -euo pipefail

check_single_wan() {
  local access
  local core
  local topo_file="${vm_remote_topology_file:-${repo_root}/fabric.clab.yml}"
  access="$(resolve_container_name "${MGMT_SITE}" "${MGMT_LOGICAL}")"
  core="$(resolve_container_name "${MGMT_SITE}" "s-router-core-wan")"
  test -n "${access}"
  test -n "${core}"
  ssh_vm_once "
    containerlab inspect -t '${topo_file}' >/dev/null
    docker exec '${access}' sh -c '
      set -e
      gw=\$(ip route | awk \"/^default via / { print \\\$3; exit }\")
      ip -4 addr
      ip route
      ip route get 8.8.8.8
      test -n \"\$gw\"
      ping -c1 -W 2 \"\$gw\"
      ip route | grep -q \"^default via \"
    '
    docker exec '${core}' sh -c '
      set -e
      ip -4 addr show dev eth2
      ip route
      ip route get 8.8.8.8
      ping -c1 -W 3 8.8.8.8
    '
  " || return 1
}

check_site_a_wan_core_egress() {
  local core
  local topo_file="${vm_remote_topology_file:-${repo_root}/fabric.clab.yml}"
  core="$(resolve_container_name "site-a" "s-router-core-wan")"
  test -n "${core}"
  ssh_vm_once "
    containerlab inspect -t '${topo_file}' >/dev/null
    docker exec '${core}' sh -c '
      set -e
      ip -4 addr show dev eth2
      ip route
      ip route get 8.8.8.8
      ping -c1 -W 3 8.8.8.8
    '
  " || return 1
}

check_dual_wan_overlay() {
  local sitea_core siteb_core branch_access
  local topo_file="${vm_remote_topology_file:-${repo_root}/fabric.clab.yml}"
  sitea_core="$(resolve_container_name "${SITEA_CORE_SITE}" "${SITEA_CORE_LOGICAL}")"
  siteb_core="$(resolve_container_name "${SITEB_CORE_SITE}" "${SITEB_CORE_LOGICAL}")"
  branch_access="$(resolve_container_name "${BRANCH_SITE}" "${BRANCH_ACCESS_LOGICAL}")"
  ssh_vm '
    set -euo pipefail
    containerlab inspect -t '"${topo_file}"' >/dev/null
    docker ps --format "{{.Names}}" | grep -q "^'"${sitea_core}"'$"
    docker ps --format "{{.Names}}" | grep -q "^'"${siteb_core}"'$"
    docker exec "'"${branch_access}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
    "
  '
}

check_dual_wan_overlay_bgp() {
  local branch_policy branch_access
  local topo_file="${vm_remote_topology_file:-${repo_root}/fabric.clab.yml}"
  branch_policy="$(resolve_container_name "${BRANCH_POLICY_SITE}" "${BRANCH_POLICY_LOGICAL}")"
  branch_access="$(resolve_container_name "${BRANCH_ACCESS_SITE}" "${BRANCH_ACCESS_LOGICAL}")"
  ssh_vm '
    set -euo pipefail
    containerlab inspect -t '"${topo_file}"' >/dev/null
    docker exec "'"${branch_access}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
    "
    docker exec "'"${branch_policy}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
      ip -6 route get '"${SITEA_LOOP6}"' >/dev/null
    "
  '
}
