#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_script="${repo_root}/docker-clab-frr-plus-tooling/build.sh"
image="${CLAB_FRR_TOOLING_IMAGE:-clab-frr-plus-tooling:latest}"
network_name="pppoe-runtime-test-$RANDOM-$$"
provider_name="pppoe-runtime-provider-$RANDOM-$$"
client_name="pppoe-runtime-client-$RANDOM-$$"

cleanup() {
  docker rm -f "${provider_name}" "${client_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL provider-access-pppoe-runtime: missing docker" >&2
  exit 1
fi

if [[ ! -e /dev/ppp ]]; then
  echo "FAIL provider-access-pppoe-runtime: host is missing /dev/ppp" >&2
  exit 1
fi

"${build_script}" >/dev/null

docker network create "${network_name}" >/dev/null
docker run -d --name "${provider_name}" --hostname "${provider_name}" --privileged --network "${network_name}" "${image}" /bin/sh -c 'sleep infinity' >/dev/null
docker run -d --name "${client_name}" --hostname "${client_name}" --privileged --network "${network_name}" "${image}" /bin/sh -c 'sleep infinity' >/dev/null

docker exec "${provider_name}" /bin/sh -ec '
  ip link set eth0 up
  mkdir -p /etc/ppp /run/ppp
  printf "hat-pppoe * hat-pppoe *\n* * hat-pppoe *\n" >/etc/ppp/chap-secrets
  printf "hat-pppoe * hat-pppoe *\n* * hat-pppoe *\n" >/etc/ppp/pap-secrets
  cat >/tmp/pppoe-server.options <<EOF
require-pap
refuse-chap
refuse-mschap
refuse-mschap-v2
refuse-eap
noauth
nobsdcomp
nodeflate
noccp
novj
+ipv6
ipv6cp-accept-local
ipv6cp-accept-remote
lcp-echo-interval 10
lcp-echo-failure 3
mtu 1492
mru 1492
ms-dns 203.0.113.5
debug
logfile /tmp/pppoe-server-child.log
EOF
  : >/tmp/pppoe-server-child.log
  : >/tmp/pppoe-server.log
  nohup pppoe-server \
    -I eth0 \
    -L 203.0.113.5 \
    -R 203.0.113.4 \
    -O /tmp/pppoe-server.options \
    -q /usr/sbin/pppd \
    -Q /usr/sbin/pppoe \
    -N 32 >/tmp/pppoe-server.log 2>&1 &
'

set +e
timeout 30 docker exec "${client_name}" /bin/sh -ec '
  ip link set eth0 up
  mkdir -p /etc/ppp /run/ppp
  printf "hat-pppoe * hat-pppoe *\n" >/etc/ppp/chap-secrets
  printf "hat-pppoe * hat-pppoe *\n" >/etc/ppp/pap-secrets
  exec pppd pty "pppoe -I eth0" \
    ifname ppp9 \
    user hat-pppoe \
    password hat-pppoe \
    noauth \
    noipdefault \
    defaultroute \
    replacedefaultroute \
    usepeerdns \
    debug \
    logfile /tmp/pppoe-client.log \
    updetach \
    +ipv6 \
    ipv6cp-accept-local \
    ipv6cp-accept-remote \
    mtu 1492 \
    mru 1492
'
client_status=$?
set -e

client_log="$(docker exec "${client_name}" /bin/sh -c 'sed -n "1,160p" /tmp/pppoe-client.log 2>/dev/null || true')"
server_child_log="$(docker exec "${provider_name}" /bin/sh -c 'sed -n "1,160p" /tmp/pppoe-server-child.log 2>/dev/null || true')"
server_log="$(docker exec "${provider_name}" /bin/sh -c 'sed -n "1,160p" /tmp/pppoe-server.log 2>/dev/null || true')"
client_link="$(docker exec "${client_name}" /bin/sh -c 'ip -o link show ppp9 2>/dev/null || true')"
client_route="$(docker exec "${client_name}" /bin/sh -c 'ip route get 1.1.1.1 2>/dev/null || true')"

if grep -q 'Fatal signal 4' <<<"${server_child_log}"; then
  echo "FAIL provider-access-pppoe-runtime: provider-side pppd crashed with SIGILL" >&2
  printf '%s\n' "${server_child_log}" >&2
  exit 1
fi

if (( client_status != 0 )); then
  echo "FAIL provider-access-pppoe-runtime: client pppd exited ${client_status}" >&2
  printf '%s\n' "${client_log}" >&2
  printf '%s\n' "${server_child_log}" >&2
  printf '%s\n' "${server_log}" >&2
  exit 1
fi

if [[ -z "${client_link}" ]] || ! grep -q 'UP,LOWER_UP' <<<"${client_link}"; then
  echo "FAIL provider-access-pppoe-runtime: PPP interface did not reach UP" >&2
  printf '%s\n' "${client_log}" >&2
  printf '%s\n' "${server_child_log}" >&2
  printf '%s\n' "${client_link}" >&2
  exit 1
fi

if [[ -z "${client_route}" ]] || ! grep -q ' dev ppp9 ' <<<"${client_route}"; then
  echo "FAIL provider-access-pppoe-runtime: client has no route to 1.1.1.1 through PPP" >&2
  printf '%s\n' "${client_log}" >&2
  printf '%s\n' "${server_child_log}" >&2
  printf '%s\n' "${client_route}" >&2
  exit 1
fi

echo "PASS provider-access-pppoe-runtime"
