#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tests/validate-topology-conformance.sh <cpm.json> <renderer-inventory.json> <fabric.clab.yml>
EOF
}

cpm_json="${1:-}"
renderer_inventory_json="${2:-}"
topology_yaml="${3:-}"

if [[ -z "${cpm_json}" || -z "${renderer_inventory_json}" || -z "${topology_yaml}" ]]; then
  usage
  exit 1
fi

[[ -s "${cpm_json}" ]] || { echo "conformance: missing or empty cpm json: ${cpm_json}" >&2; exit 1; }
[[ -s "${renderer_inventory_json}" ]] || {
  echo "conformance: missing or empty renderer inventory json: ${renderer_inventory_json}" >&2
  exit 1
}
[[ -s "${topology_yaml}" ]] || { echo "conformance: missing or empty topology yaml: ${topology_yaml}" >&2; exit 1; }

PYTHONPATH="${repo_root}" python3 - "${cpm_json}" "${renderer_inventory_json}" "${topology_yaml}" <<'PY'
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

from clabgen.s88.enterprise.enterprise import Enterprise


def fail(msg: str) -> None:
    raise SystemExit(f"conformance: {msg}")


def parse_topology_yaml(text: str) -> tuple[set[str], Counter[tuple[str, ...]]]:
    lines = text.splitlines()

    in_nodes = False
    in_links = False
    nodes: set[str] = set()
    link_endpoints: list[list[str]] = []
    current_endpoints: list[str] | None = None

    node_re = re.compile(r"^\s{4}([^:\s][^:]*):\s*$")
    endpoint_re = re.compile(r"^\s{4}-\s+(.+?)\s*$")

    for line in lines:
        if line.startswith("  nodes:"):
            in_nodes = True
            in_links = False
            continue
        if line.startswith("  links:"):
            in_nodes = False
            in_links = True
            continue

        if in_nodes:
            m = node_re.match(line)
            if m:
                nodes.add(m.group(1))
            continue

        if in_links:
            if line.startswith("  - endpoints:"):
                if current_endpoints is not None:
                    link_endpoints.append(current_endpoints)
                current_endpoints = []
                continue

            if current_endpoints is not None:
                m = endpoint_re.match(line)
                if m:
                    ep = m.group(1).strip()
                    if ep.startswith('"') and ep.endswith('"') and len(ep) >= 2:
                        ep = ep[1:-1]
                    current_endpoints.append(ep)
                    continue

    if current_endpoints is not None:
        link_endpoints.append(current_endpoints)

    links_counter: Counter[tuple[str, ...]] = Counter()
    for eps in link_endpoints:
        if len(eps) >= 2:
            links_counter[tuple(sorted(eps))] += 1

    return nodes, links_counter


def expected_topology(
    cpm_path: Path, renderer_inventory_path: Path
) -> tuple[set[str], Counter[tuple[str, ...]]]:
    renderer_inventory = json.loads(renderer_inventory_path.read_text())
    if not isinstance(renderer_inventory, dict):
        fail("renderer inventory json must be an object")

    rendered = Enterprise.from_solver_json(
        cpm_path,
        renderer_inventory=renderer_inventory,
    ).render()

    topo = rendered.get("topology") or {}
    nodes = topo.get("nodes") or {}
    links = topo.get("links") or []

    if not isinstance(nodes, dict):
        fail("rendered topology nodes must be an object")
    if not isinstance(links, list):
        fail("rendered topology links must be an array")

    expected_nodes: set[str] = set(nodes.keys())
    expected_links: Counter[tuple[str, ...]] = Counter()
    for link in links:
        if not isinstance(link, dict):
            continue
        eps = link.get("endpoints") or []
        if not isinstance(eps, list) or len(eps) < 2:
            continue
        expected_links[tuple(sorted(str(e) for e in eps))] += 1

    return expected_nodes, expected_links


def summarize_counter_delta(a: Counter[tuple[str, ...]], b: Counter[tuple[str, ...]]) -> list[str]:
    lines: list[str] = []
    for key, count in sorted((a - b).items(), key=lambda x: x[0]):
        lines.append(f"{' | '.join(key)} (x{count})")
    return lines


def main() -> None:
    cpm_path = Path(sys.argv[1])
    renderer_inventory_path = Path(sys.argv[2])
    topology_path = Path(sys.argv[3])

    expected_nodes, expected_links = expected_topology(cpm_path, renderer_inventory_path)
    actual_nodes, actual_links = parse_topology_yaml(topology_path.read_text())

    missing_nodes = sorted(expected_nodes - actual_nodes)
    extra_nodes = sorted(actual_nodes - expected_nodes)

    missing_links = summarize_counter_delta(expected_links, actual_links)
    extra_links = summarize_counter_delta(actual_links, expected_links)

    if missing_nodes:
        fail(f"missing nodes in YAML: {missing_nodes[:10]}")
    if extra_nodes:
        fail(f"unexpected nodes in YAML: {extra_nodes[:10]}")
    if missing_links:
        fail(f"missing links in YAML: {missing_links[:10]}")
    if extra_links:
        fail(f"unexpected links in YAML: {extra_links[:10]}")
    duplicate_links = [
        f"{' | '.join(key)} (x{count})"
        for key, count in sorted(actual_links.items(), key=lambda x: x[0])
        if count > 1
    ]
    if duplicate_links:
        fail(f"duplicate links in YAML: {duplicate_links[:10]}")


if __name__ == "__main__":
    main()
PY
