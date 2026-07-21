#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
	echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: $*" >&2
	exit 1
}

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    renderer = builtins.getFlake (toString (builtins.getEnv "REPO_ROOT"));
    system = builtins.currentSystem;
    trace = "FS-540-HDS-010-SDS-010-SMS-020";
    row = renderer.inputs.network-labs + "/GAMP/SMT/${trace}";
    inventory = import (row + "/inventory-clab.nix");
    cpm = renderer.inputs.network-control-plane-model.libBySystem.${system}.compileAndBuild {
      input = import (row + "/intent.nix");
      inherit inventory;
    };
    artifact = {
      kind = "network-control-plane-artifact";
      artifactIdentity = "${trace}-clab-cpm";
      artifactDigest = builtins.hashString "sha256" (builtins.toJSON cpm.control_plane_model);
      inherit (cpm) control_plane_model;
    };
    bundle = renderer.inputs.network-realization-model.lib.realize {
      input = artifact;
      requestScope = {
        kind = "complete-artifact";
        identity = "${trace}-clab";
      };
      rootLockIdentity = "network-renderer-clab-flake-lock";
      producerRevision = renderer.inputs.network-realization-model.rev;
    };
    canonical = renderer.libBySystem.${system}.renderer.canonical;
    validated = canonical.validateInput { inherit bundle; };
    rawCpmRejected = !(builtins.tryEval (builtins.deepSeq (canonical.validateInput {
      bundle = cpm;
    }) true)).success;
    tamperedBundle = bundle // {
      network = bundle.network // {
        data = bundle.network.data // { rendererInventedDefault = true; };
      };
    };
    unvalidatedMutationRejected = !(builtins.tryEval (builtins.deepSeq (canonical.validateInput {
      bundle = tamperedBundle;
    }) true)).success;
  in {
    boundary = {
      releaseValid = bundle.validation.valid;
      identityPreserved = validated.bundleIdentity == bundle.bundleIdentity;
      inherit rawCpmRejected unvalidatedMutationRejected;
    };
    controlPlane = validated.controlPlaneEnvelope;
    inherit inventory;
  }
' >"${tmp_dir}/canonical-input.json"

jq -e '
  .boundary == {
    releaseValid: true,
    identityPreserved: true,
    rawCpmRejected: true,
    unvalidatedMutationRejected: true
  }
' "${tmp_dir}/canonical-input.json" >/dev/null ||
	fail "canonical release or fail-closed boundary check failed"

jq '.controlPlane' "${tmp_dir}/canonical-input.json" >"${tmp_dir}/cpm.json"
jq '.inventory' "${tmp_dir}/canonical-input.json" >"${tmp_dir}/inventory.json"

CLABGEN_RENDERER_INVENTORY_JSON="${tmp_dir}/inventory.json" \
	nix run "path:${repo_root}#generate-clab-config" -- \
	"${tmp_dir}/cpm.json" \
	"${tmp_dir}/fabric.clab.yml" \
	"${tmp_dir}/vm-bridges-generated.nix"

"${repo_root}/tests/validate-rendered-artifacts.sh" \
	"${tmp_dir}/fabric.clab.yml" \
	"${tmp_dir}/vm-bridges-generated.nix"
"${repo_root}/tests/validate-topology-conformance.sh" \
	"${tmp_dir}/cpm.json" \
	"${tmp_dir}/inventory.json" \
	"${tmp_dir}/fabric.clab.yml"

node_block() {
	local node="$1"
	local output="$2"
	awk -v header="    ${node}:" '
    $0 == header { inside = 1; print; next }
    inside && /^    [^ ].*:$/ { exit }
    inside { print }
  ' "${tmp_dir}/fabric.clab.yml" >"${output}"
	[[ -s "${output}" ]] || fail "rendered topology lacks node ${node}"
}

prefix="mini-smt-FS-540-HDS-010-SDS-010-SMS-020"
node_block "${prefix}-access-dns" "${tmp_dir}/access.block"
node_block "${prefix}-resolver-node" "${tmp_dir}/core.block"

for expected in \
	'clab.dns.runtime: unbound' \
	'forward-zone:' \
	'forward-addr: \"10.2.255.6\"' \
	'forward-addr: \"fd42:21c:fe::6\"' \
	'forward-first: no'; do
	grep -Fq "${expected}" "${tmp_dir}/access.block" ||
		fail "access DNS output lacks ${expected}"
done

for expected in \
	'clab.dns.runtime: unbound' \
	'ip addr replace 10.20.0.20/24 dev' \
	'net.ipv6.conf.wan0.accept_ra=2' \
	'select-modeled-dns-egress' \
	'allow-dns-service-egress'; do
	grep -Fq "${expected}" "${tmp_dir}/core.block" ||
		fail "core DNS output lacks ${expected}"
done

if grep -Fq 'forward-zone:' "${tmp_dir}/core.block"; then
	fail "iterative core unexpectedly renders a forward zone"
fi

for output in "${tmp_dir}/access.block" "${tmp_dir}/core.block"; do
	if rg -q '1[.]1[.]1[.]1|8[.]8[.]8[.]8|9[.]9[.]9[.]9|2606:4700' "${output}"; then
		fail "renderer invented a public DNS fallback"
	fi
done

grep -Fq '"dns540c"' "${tmp_dir}/vm-bridges-generated.nix" ||
	fail "CLAB endpoint bridge dns540c is absent"
grep -Fq '"vlan": 412' "${tmp_dir}/vm-bridges-generated.nix" ||
	fail "CLAB endpoint bridge is not isolated on the controlled test VLAN"
grep -Fq '"testnet-vlan4"' "${tmp_dir}/vm-bridges-generated.nix" ||
	fail "CLAB core has no modeled testnet egress binding"

PYTHONPATH="${repo_root}/clabgen/s88/CM:${repo_root}" python3 - <<'PY'
import socket
import struct

import clabgen.s88.CM.dns_proxy_runtime as runtime
from clabgen.s88.CM.dns_proxy_protocol import encode_name


query = (
    struct.pack("!HHHHHH", 0x5402, 0x0100, 1, 0, 0, 0)
    + encode_name("cache.nixos.org.")
    + struct.pack("!HH", 1, 1)
)


def unavailable(_config, _query, _family):
    raise TimeoutError("seeded upstream timeout")


original = runtime.forward_udp
try:
    runtime.forward_udp = unavailable
    answer = runtime._resolve_or_servfail({}, query, socket.AF_INET)
finally:
    runtime.forward_udp = original

if answer[:2] != query[:2] or struct.unpack("!H", answer[2:4])[0] & 0x000F != 2:
    raise SystemExit("DNS proxy did not recover from the seeded timeout with SERVFAIL")
PY

echo "PASS FS-540 canonical CLAB DNS materialization, isolation, and recovery"
