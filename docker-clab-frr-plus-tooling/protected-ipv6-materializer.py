#!/usr/bin/env python3
"""Derive one tenant prefix or exact IID address from a protected parent."""

from __future__ import annotations

import argparse
import ipaddress
from pathlib import Path
import sys


DIAGNOSTIC = "diagnostic.runtime-protected-ipv6-invalid"


class PrefixContractError(Exception):
    """A protected prefix or its public derivation metadata is invalid."""


def require(condition: bool) -> None:
    if not condition:
        raise PrefixContractError


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--delegated-prefix-length", type=int, required=True)
    parser.add_argument("--tenant-prefix-length", type=int, required=True)
    parser.add_argument("--slot", type=int, required=True)
    parser.add_argument("--interface-identifier")
    return parser.parse_args()


def derive(args: argparse.Namespace) -> str:
    source_text = args.source.read_text(encoding="utf-8").strip()
    require(source_text != "")
    parent = ipaddress.ip_network(source_text, strict=True)
    require(parent.version == 6)
    require(str(parent) == source_text)
    require(parent.prefixlen == args.delegated_prefix_length)
    require(parent.prefixlen <= args.tenant_prefix_length <= 128)
    available_bits = args.tenant_prefix_length - parent.prefixlen
    require(0 <= args.slot < (1 << available_bits))
    offset = args.slot << (128 - args.tenant_prefix_length)
    tenant = ipaddress.ip_network(
        (int(parent.network_address) + offset, args.tenant_prefix_length),
        strict=True,
    )
    require(tenant.subnet_of(parent))
    if args.interface_identifier is None:
        return str(tenant)

    require(tenant.prefixlen == 64)
    identifier = ipaddress.IPv6Address(args.interface_identifier)
    require(int(identifier) < (1 << 64))
    address = ipaddress.IPv6Address(int(tenant.network_address) | int(identifier))
    require(address in tenant)
    return f"{address}/128"


def main() -> None:
    try:
        print(derive(parse_args()))
    except Exception:
        print(
            f"{DIAGNOSTIC}: protected source or derivation metadata rejected",
            file=sys.stderr,
        )
        raise SystemExit(1)


if __name__ == "__main__":
    main()
