#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${repo_root}"

if command -v ruff >/dev/null 2>&1; then
  ruff format --check generate-clab-config.py clabgen
else
  nix shell --inputs-from . nixpkgs#ruff -c ruff format --check generate-clab-config.py clabgen
fi
