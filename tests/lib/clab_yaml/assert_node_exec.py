from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml


def fail(message: str) -> None:
    raise SystemExit(message)


def node_exec(topology_path: Path, node_name: str) -> list[str]:
    with topology_path.open() as fh:
        topology = yaml.safe_load(fh)

    if not isinstance(topology, dict):
        fail(f"topology YAML must be an object: {topology_path}")

    nodes = topology.get("topology", {}).get("nodes", {})
    if not isinstance(nodes, dict):
        fail(f"topology.nodes must be an object: {topology_path}")

    node = nodes.get(node_name)
    if not isinstance(node, dict):
        fail(f"missing node {node_name!r} in {topology_path}")

    exec_cmds = node.get("exec", [])
    if not isinstance(exec_cmds, list):
        fail(f"node {node_name!r} exec must be a list")

    return [cmd for cmd in exec_cmds if isinstance(cmd, str)]


def main(argv: list[str]) -> None:
    if len(argv) != 5:
        fail("usage: assert_node_exec.py <contains|matches> <topology> <node> <needle>")

    mode = argv[1]
    topology_path = Path(argv[2])
    node_name = argv[3]
    needle = argv[4]
    exec_text = "\n".join(node_exec(topology_path, node_name))

    if mode == "contains":
        if needle in exec_text:
            return
    elif mode == "matches":
        if re.search(needle, exec_text, re.MULTILINE | re.DOTALL):
            return
    else:
        fail(f"unknown assertion mode {mode!r}")

    print(f"missing in {node_name}: {needle}", file=sys.stderr)
    print(f"--- {node_name} exec ---", file=sys.stderr)
    print(exec_text, file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv)
