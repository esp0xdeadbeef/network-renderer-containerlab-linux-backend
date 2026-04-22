#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  ./run-clab-generator.sh <control-plane-model.json|output-solver.json> [topology_out] [bridges_out]

defaults:
  - No default input is assumed.
  - Prefer generating a fresh CPM JSON in a temp dir (see ./start-vm.sh).

EOF
}

validate_input_or_explain() {
  local path="$1"

  # If the input is a CPM JSON, it must include `runtimeTargets` per site. We
  # validate early to avoid deleting outputs and to provide a clear error.
  python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
raw = p.read_text()

lines = raw.splitlines()
while lines and lines[0].lstrip().startswith("#"):
    lines.pop(0)
raw2 = "\n".join(lines).strip()

try:
    root = json.loads(raw2 or raw)
except Exception as exc:
    print(f"[run-clab-generator] invalid JSON: {p}: {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(root, dict):
    print(f"[run-clab-generator] invalid JSON: {p}: top-level must be an object", file=sys.stderr)
    sys.exit(2)

cpm = root.get("control_plane_model")
if cpm is None:
    # Not CPM JSON; assume solver JSON and let clabgen validate.
    sys.exit(0)

if not isinstance(cpm, dict):
    print(f"[run-clab-generator] invalid CPM JSON: {p}: control_plane_model must be an object", file=sys.stderr)
    sys.exit(2)

data = cpm.get("data")
if not isinstance(data, dict):
    print(f"[run-clab-generator] invalid CPM JSON: {p}: control_plane_model.data must be an object", file=sys.stderr)
    sys.exit(2)

missing = []
for ent, sites in data.items():
    if not isinstance(sites, dict):
        continue
    for site, site_obj in sites.items():
        if not isinstance(site_obj, dict):
            continue
        if not isinstance(site_obj.get("runtimeTargets"), dict):
            missing.append(f"{ent}.{site}")

if missing:
    joined = ", ".join(missing[:10])
    suffix = "" if len(missing) <= 10 else f" (+{len(missing)-10} more)"
    print(
        "[run-clab-generator] CPM input is missing required site.runtimeTargets for: "
        f"{joined}{suffix}\n"
        "[run-clab-generator] This usually means you are pointing the renderer at an older/legacy CPM output.\n"
        "[run-clab-generator] Build a fresh CPM JSON (via network-control-plane-model) and pass it as the first argument.",
        file=sys.stderr,
    )
    sys.exit(3)

sys.exit(0)
PY
}

INPUT="${1:-}"
TOPO_OUT="${2:-fabric.clab.yml}"
BRIDGES_OUT="${3:-vm-bridges-generated.nix}"

if [[ -z "$INPUT" ]]; then
  usage
  exit 1
fi

validate_input_or_explain "$INPUT"

nix run "path:${repo_root}#generate-clab-config" -- "$INPUT" "$TOPO_OUT" "$BRIDGES_OUT"

"${repo_root}/tests/validate-rendered-artifacts.sh" "$TOPO_OUT" "$BRIDGES_OUT"

echo "links generated:"
sed -n '/links:/,$p' "$TOPO_OUT" 2>/dev/null || true
echo "bridges (nix):"
cat "./$BRIDGES_OUT" 2>/dev/null || true
