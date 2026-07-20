#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
host_module="${repo_root}/host-module.nix"

grep -F 'pkgs.procps' "${host_module}" >/dev/null || {
  echo "FAIL FS-380 host bridge netfilter: host-module runtimeInputs must include procps for sysctl" >&2
  exit 1
}

python3 - "${host_module}" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()
required = [
    "net.bridge.bridge-nf-call-iptables",
    "net.bridge.bridge-nf-call-ip6tables",
    "net.bridge.bridge-nf-call-arptables",
]
missing = [value for value in required if value not in content]
if missing:
    raise SystemExit(
        "FAIL FS-380 host bridge netfilter: missing sysctl keys: "
        + ", ".join(missing)
    )

sysctl_pos = content.find("net.bridge.bridge-nf-call-iptables")
setup_pos = content.find("bash '$work_dir/setup-bridge-links.sh'")
if (
    'CLAB_HOST_TOPOLOGY=\'$work_dir/fabric.clab.yml\'' not in content
    or 'containerlab deploy -t "$topology_file"' not in content
):
    raise SystemExit(
        "FAIL FS-380 host bridge netfilter: host deploy script must consume "
        "the staged fabric.clab.yml topology"
    )
deploy_pos = content.find("bash '$work_dir/deploy-containerlab-on-host.sh'")
post_setup_pos = content.find("bash '$work_dir/setup-bridge-links.sh'", deploy_pos)
retry_pos = content.find("bash '$work_dir/retry-wan-dhcp.sh'", deploy_pos)
reconcile_pos = content.find(
    "bash '$work_dir/reconcile-access-advertisements.sh'", deploy_pos
)
verify_pos = content.find("bash '$work_dir/verify-containerlab-deploy.sh'", deploy_pos)
if not (
    0
    <= sysctl_pos
    < setup_pos
    < deploy_pos
    < post_setup_pos
    < retry_pos
    < reconcile_pos
    < verify_pos
):
    raise SystemExit(
        "FAIL FS-380 host bridge netfilter: bridge-netfilter sysctl must be "
        "generated into setup-bridge-links.sh, setup must run before and after "
        "deploy, and post-deploy reconciliation must run before verification"
    )

print("PASS FS-380 host bridge netfilter guard")
PY
