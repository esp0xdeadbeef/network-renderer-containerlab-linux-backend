#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"
source "${repo_root}/tests/lib/vm-cpm-context.sh"
example="${CLAB_FRR_TOOLING_CACHE_EXAMPLE:-single-wan}"
ssh_host="${CLAB_VM_SSH_HOST:-127.0.0.1}"
ssh_port="${CLAB_VM_SSH_PORT:-2222}"
default_cache_dir="${repo_root}/docker-clab-frr-plus-tooling/.cache"
cache_dir="${CLAB_FRR_TOOLING_REPO_CACHE_DIR:-}"
state_root="${CLAB_FRR_TOOLING_CACHE_STATE_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/clab-frr-tooling-cache}"
state_dir="${CLAB_VM_STATE_DIR:-}"
ephemeral_state_dir=""
vm_pid=""

if [[ -z "${cache_dir}" ]]; then
    if [[ "${repo_root}" == /nix/store/* ]]; then
        echo "renderer repository is under /nix/store; set CLAB_FRR_TOOLING_REPO_CACHE_DIR to a writable user-supplied cache/export directory" >&2
        exit 2
    fi
    if [[ ! -w "$(dirname "${default_cache_dir}")" ]]; then
        echo "renderer repository cache parent is not writable; set CLAB_FRR_TOOLING_REPO_CACHE_DIR to a writable user-supplied cache/export directory" >&2
        exit 2
    fi
    cache_dir="${default_cache_dir}"
fi

if [[ "${cache_dir}" == /nix/store/* ]]; then
    echo "CLAB_FRR_TOOLING_REPO_CACHE_DIR must not point into /nix/store: ${cache_dir}" >&2
    exit 2
fi

mkdir -p "${state_root}" "${cache_dir}"
if [[ ! -w "${cache_dir}" ]]; then
    echo "CLAB_FRR_TOOLING_REPO_CACHE_DIR is not writable: ${cache_dir}" >&2
    exit 2
fi

if [[ -z "${state_dir}" ]]; then
    ephemeral_state_dir="$(mktemp -d "${state_root}/state.XXXXXX")"
    state_dir="${ephemeral_state_dir}"
fi
cpm_json="${state_dir}/${example}.cpm.json"

ssh_opts=(
    -T
    -o BatchMode=yes
    -o ConnectTimeout="${VM_SSH_CONNECT_TIMEOUT_SECONDS:-5}"
    -o ConnectionAttempts=1
    -o LogLevel=ERROR
    -o StrictHostKeyChecking=no
    -o GlobalKnownHostsFile=/dev/null
    -o UserKnownHostsFile=/dev/null
    -o UpdateHostKeys=no
    -p "${ssh_port}"
)

cleanup() {
    if [[ -n "${vm_pid}" ]]; then
        ssh "${ssh_opts[@]}" "root@${ssh_host}" shutdown -h now >/dev/null 2>&1 || true
        wait "${vm_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${ephemeral_state_dir}" ]]; then
        rm -rf "${ephemeral_state_dir}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

wait_for_ssh() {
    local deadline=$((SECONDS + ${VM_SSH_WAIT_SECONDS:-600}))

    while ((SECONDS < deadline)); do
        if ssh "${ssh_opts[@]}" "root@${ssh_host}" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

printf '[clab-cache] starting nixos-shell VM for %s\n' "${example}"
labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
compile_example_cpm "${example}" "${cpm_json}" "${labs_path}" "${cpm_path}"
(
    cd "${repo_root}"
    CLAB_VM_STATE_DIR="${state_dir}" \
    CLAB_VM_SSH_HOST="${ssh_host}" \
    CLAB_VM_SSH_PORT="${ssh_port}" \
        ./start-vm.sh "${cpm_json}"
) >"${state_dir}/nixos-shell-cache-update.log" 2>&1 &
vm_pid="$!"

if ! wait_for_ssh; then
    cat "${state_dir}/nixos-shell-cache-update.log" >&2 || true
    echo "nixos-shell VM did not become reachable" >&2
    exit 1
fi

printf '[clab-cache] refreshing repository Docker image cache at %s\n' "${cache_dir}"
{
    printf 'set -euo pipefail\n'
    printf 'repo_root=%q\n' "${repo_root}"
    printf 'cache_dir=%q\n' "${cache_dir}"
    cat <<'REMOTE_CACHE_UPDATE'
cd "${repo_root}"
dockerfile="docker-clab-frr-plus-tooling/Dockerfile"
hash="$(sha256sum "${dockerfile}" | awk '{print $1}')"
cache_tar="${cache_dir}/clab-frr-plus-tooling-${hash}.tar"
cache_id="${cache_tar}.image-id"

CLAB_FRR_TOOLING_CACHE_DIR="${cache_dir}" \
CLAB_FRR_TOOLING_SAVE_CACHE=1 \
    ./docker-clab-frr-plus-tooling/build.sh

label="$(
    docker image inspect \
        --format '{{ index .Config.Labels "org.esp0xdeadbeef.clab-frr-plus-tooling.dockerfile-sha256" }}' \
        clab-frr-plus-tooling:latest
)"
test "${label}" = "${hash}"
test -s "${cache_tar}"
test -s "${cache_id}"

docker run --rm --entrypoint /bin/sh clab-frr-plus-tooling:latest -ec '
    for cmd in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff udhcpc udhcpd vtysh python3; do
        command -v "$cmd" >/dev/null || exit 1
    done
    grep -q "^bgpd=yes" /etc/frr/daemons
    test -x /usr/lib/frr/zebra
    test -x /usr/lib/frr/bgpd
    test -x /usr/lib/frr/staticd
'

printf 'CACHE_TAR=%s\n' "${cache_tar}"
printf 'CACHE_ID=%s\n' "${cache_id}"
REMOTE_CACHE_UPDATE
} | ssh "${ssh_opts[@]}" "root@${ssh_host}" /run/current-system/sw/bin/bash --noprofile --norc -s

printf '[clab-cache] repository Docker image cache is current\n'
