#!/usr/bin/env bash
set -euo pipefail

assert_node_exec() {
  local mode="$1"
  local topology="$2"
  local node="$3"
  local needle="$4"
  local system

  case "$(uname -m)" in
    x86_64) system="x86_64-linux" ;;
    aarch64|arm64) system="aarch64-linux" ;;
    *) echo "unsupported test host architecture: $(uname -m)" >&2; return 1 ;;
  esac

  nix shell --inputs-from "${repo_root}" --impure \
    --expr "(builtins.getFlake (toString ${repo_root})).inputs.nixpkgs.legacyPackages.${system}.python3.withPackages (ps: [ ps.pyyaml ])" \
    -c \
    python3 "${repo_root}/tests/lib/clab_yaml/assert_node_exec.py" \
      "${mode}" "${topology}" "${node}" "${needle}"
}
