#!/usr/bin/env bash
# GAMP-ID: FS-780-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: All controlled CLAB examples compile before VM execution.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/input-path.sh"
source "${repo_root}/tests/lib/vm-cpm-context.sh"

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
work_dir="$(mktemp -d /tmp/fs780-example-compilation.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT

mapfile -t examples < <(
  find "${labs_path}/examples" -mindepth 2 -maxdepth 2 -type f -name inventory-clab.nix -printf '%h\n' \
    | while read -r directory; do
        [[ -f "${directory}/intent.nix" ]] && basename "${directory}"
      done \
    | LC_ALL=C sort
)

for example in "${examples[@]}"; do
  compile_example_cpm "${example}" "${work_dir}/${example}.json" "${labs_path}" "${cpm_path}"
done

printf 'PASS FS-780-HDS-010-SDS-010-SMS-010: compiled %s CLAB example(s)\n' "${#examples[@]}"
