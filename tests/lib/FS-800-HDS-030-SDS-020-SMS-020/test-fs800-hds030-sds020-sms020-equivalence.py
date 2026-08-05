#!/usr/bin/env python3
"""Ordinal 5 equivalence test: Compare NixOS and CLAB normalized PPPoE IPv6/PD artifacts.
Checks that both renderers produce equivalent customer-side behavior."""

import json, os, re, subprocess, sys
from copy import deepcopy

repo_root = os.environ.get(
    "SMS_TEST_REPO_ROOT",
    subprocess.run(
        ["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    ).stdout.strip(),
)
sys.path.insert(0, repo_root)
from clabgen.s88.CM.pppoe_runtime import render  # noqa: E402


def normalize_pppoe_output(text: str) -> dict:
    """Extract normalized customer-side features from rendered output."""
    feats: dict = {}
    m = re.search(r"iaid (\d+)", text)
    feats["iaid"] = int(m.group(1)) if m else None
    m = re.search(r"ia_pd (\d+)", text)
    feats["ia_pd"] = int(m.group(1)) if m else None
    feats["nohook_resolv"] = "nohook resolv.conf" in text
    feats["noipv6rs"] = "noipv6rs" in text
    feats["noipv4"] = "noipv4" in text
    feats["ipv6only"] = "ipv6only" in text
    m = re.search(r"interface (\S+)", text)
    feats["interface"] = m.group(1) if m else None
    feats["has_restricted_firewall"] = (
        "iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546" in text
    )
    dport547 = text.count("udp dport 547")
    restricted = text.count(
        "iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546"
    )
    feats["firewall_tight"] = restricted >= 1 and dport547 == restricted
    return feats


def check_equivalence_int(ref_output: str, candidate_output: str) -> bool:
    """Return True if normalized features match; raise AssertionError if not."""
    r = normalize_pppoe_output(ref_output)
    c = normalize_pppoe_output(candidate_output)
    if r != c:
        raise AssertionError(f"Equivalence broken: ref={r} != candidate={c}")
    return True


# --- Nominal artifacts ---
ipv6 = {
    "mode": "dhcpv6-pd", "defaultRoute": True, "iaid": 7,
    "prefixDelegationRequestId": 11, "duidMode": "persistent",
    "resolverMode": "disabled", "ipv4Mode": "disabled",
    "routerSolicitation": False, "fallbackPolicy": "none",
}
client = {
    "interface": "provider-handoff", "runtimeInterface": "ppp-test",
    "defaultRoute": True, "usePeerDns": False, "mtu": 1492,
    "credentials": {
        "usernameFile": "/run/secrets/test-username",
        "passwordFile": "/run/secrets/test-password",
    },
    "ipv6": ipv6,
}

# Compute NixOS reference artifact via nix eval
nixos_repo = "/home/deadbeef/github/network-renderer-nixos"
nixos_expr = """\
  let
    repoRoot = "/home/deadbeef/github/network-renderer-nixos";
    flake = builtins.getFlake ("path:" + repoRoot);
    lib = flake.inputs.nixpkgs.lib;
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    ipv6 = {
      mode = "dhcpv6-pd";  defaultRoute = true;  iaid = 7;
      prefixDelegationRequestId = 11;  duidMode = "persistent";
      resolverMode = "disabled";  ipv4Mode = "disabled";
      routerSolicitation = false;  fallbackPolicy = "none";
    };
    renderedModel = {
      unitName = "test-core";
      interfaces.provider-handoff.containerInterfaceName = "ens20";
      services.pppoe.client = {
        interface = "provider-handoff";
        runtimeInterface = "ppp-test";
        defaultRoute = true;
        usePeerDns = false;
        mtu = 1492;
        credentials = {
          usernameFile = "/run/secrets/test-username";
          passwordFile = "/run/secrets/test-password";
        };
        inherit ipv6;
      };
    };
    module = import (repoRoot + "/s88/ControlModule/render/containers/module/pppoe.nix") {
      inherit lib pkgs renderedModel;
    };
    evaluated = lib.nixosSystem {
      inherit system;
      modules = [ module.config ];
    };
  in builtins.readFile evaluated.config.environment.etc."s88/pppoe-ipv6-provider-handoff.conf".source\
"""
nixos_dhcpcd = subprocess.run(
    ["nix", "eval", "--impure", "--raw", "--expr", nixos_expr],
    capture_output=True, text=True, cwd=nixos_repo, timeout=120,
).stdout

# Compute CLAB artifact
clab_output = "\n".join(
    render("test-core", {"services": {"pppoe": {"client": client}}}, {"provider-handoff": "eth1"})
)

# Nominal: both renderers produce equivalent normalized features
check_equivalence_int(nixos_dhcpcd, clab_output)

# --- Mutation: change IAID to break equivalence ---
mutant_client = deepcopy(client)
mutant_client["ipv6"]["iaid"] = 0
mutant_clab = "\n".join(
    render("test-core", {"services": {"pppoe": {"client": mutant_client}}}, {"provider-handoff": "eth1"})
)
try:
    check_equivalence_int(nixos_dhcpcd, mutant_clab)
    raise AssertionError(
        "FS-800 ordinal 5: mutated CLAB IAID was accepted as equivalent to NixOS reference"
    )
except AssertionError as e:
    if "Equivalence broken" not in str(e):
        raise

print("PASS FS-800-HDS-030-SDS-020-SMS-020 ordinal 5: NixOS/CLAB artifact equivalence")
