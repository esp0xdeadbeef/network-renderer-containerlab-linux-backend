#!/usr/bin/env bash

docker-clab-frr-plus-tooling/build.sh

containerlab deploy -t fabric.clab.yml -d --reconfigure

for c in $(docker ps --format '{{.Names}}' | grep clab-fabric)
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

  echo "[ ip route get 1.1.1.1 ]"
  docker exec "$c" ip route get 1.1.1.1
  echo

  echo "[ traceroute -> s-router-access (10.10.0.0) ]"
  docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 10.10.0.0 || true
  echo

  echo "[ traceroute -> s-router-core-isp-a (10.10.0.2) ]"
  docker exec "$c" traceroute -I -n -w 1 -q 1 -m 5 10.10.0.2 || true
  echo

  echo "[ traceroute -> internet (1.1.1.1) ]"
  docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 1.1.1.1 || true
  echo

  echo " [ FIREWALL - nft list ruleset]"
  docker exec "$c" nft list ruleset || true
  echo

done
