#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

timeout 5s env PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.CM.linux_addressing import _first_usable_host, _peer_in_subnet

assert _first_usable_host("fd42:dead:beef:70::/64") == "fd42:dead:beef:70::1/64"
assert _peer_in_subnet("fd42:dead:beef:70::1/64") == "fd42:dead:beef:70::2"
assert _peer_in_subnet("fd42:dead:beef:70::/64") == "fd42:dead:beef:70::1"
assert _peer_in_subnet("10.20.70.1/24") == "10.20.70.2"
assert _peer_in_subnet("10.20.70.0/24") == "10.20.70.1"
assert _peer_in_subnet("10.20.70.0/32") is None
PY
