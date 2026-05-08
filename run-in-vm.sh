#!/usr/bin/env bash
set -euo pipefail

topo_file="${CLAB_TOPO_FILE:-fabric.clab.yml}"

docker-clab-frr-plus-tooling/build.sh

# Example switching reuses the same VM and lab name (`fabric`).
# This script runs inside a dedicated test VM, so clear any stale lab state
# before deploying the next rendered topology.
containerlab destroy --all --cleanup --yes >/dev/null 2>&1 || true
docker ps --format '{{.Names}}' | grep '^clab-fabric-' | xargs -r docker rm -f >/dev/null 2>&1 || true

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
