
docker-clab-frr-plus-tooling/build.sh

containerlab deploy -t fabric.clab.yml -d --reconfigure

for c in $(docker ps --format '{{.Names}}' | grep clab-fabric-esp0xdeadbeef-site-a)
 do  
   echo "=================================================="
   echo "NODE: $c"
   echo "--------------------------------------------------"
   echo "[ip route]"
   docker exec "$c" ip route
   echo
   echo "[ip -6 route]"
   docker exec "$c" ip -6 route
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
 done
