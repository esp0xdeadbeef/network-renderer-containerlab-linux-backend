#!/usr/bin/env bash
set -euo pipefail

IMAGE="${CLAB_FRR_TOOLING_IMAGE:-clab-frr-plus-tooling:latest}"
DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_TAR="${CLAB_FRR_TOOLING_CACHE_TAR:-}"
CACHE_ID_FILE="${CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE:-}"

current_id() {
    docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true
}

cache_id() {
    if [[ -n "${CACHE_ID_FILE}" && -f "${CACHE_ID_FILE}" ]]; then
        cat "${CACHE_ID_FILE}"
    fi
}

maybe_load_cached_image() {
    local local_id=""
    local desired_id=""

    [[ -n "${CACHE_TAR}" && -f "${CACHE_TAR}" ]] || return 0

    local_id="$(current_id)"
    desired_id="$(cache_id)"

    if [[ -n "${local_id}" && ( -z "${desired_id}" || "${local_id}" == "${desired_id}" ) ]]; then
        return 0
    fi

    echo "[clab] loading FRR tooling image cache from ${CACHE_TAR}..."
    docker load -i "${CACHE_TAR}" >/dev/null
}

maybe_load_cached_image

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[clab] building local FRR tooling image..."
    docker build -t "$IMAGE" "$DIR"
fi
