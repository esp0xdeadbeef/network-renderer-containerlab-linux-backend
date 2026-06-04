#!/usr/bin/env bash
set -euo pipefail

IMAGE="${CLAB_FRR_TOOLING_IMAGE:-clab-frr-plus-tooling:latest}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${DIR}/Dockerfile"
LABEL_KEY="org.esp0xdeadbeef.clab-frr-plus-tooling.dockerfile-sha256"
FORCE_REBUILD="${CLAB_FRR_TOOLING_REBUILD:-${CLAB_FRR_TOOLING_FORCE_REBUILD:-0}}"
SAVE_CACHE="${CLAB_FRR_TOOLING_SAVE_CACHE:-1}"
ALLOW_EXISTING_IMAGE="${CLAB_FRR_TOOLING_ALLOW_EXISTING_IMAGE:-0}"

dockerfile_hash() {
    sha256sum "${DOCKERFILE}" | awk '{print $1}'
}

CACHE_KEY="${CLAB_FRR_TOOLING_CACHE_KEY:-$(dockerfile_hash)}"
CACHE_DIR="${CLAB_FRR_TOOLING_CACHE_DIR:-}"

if [[ -z "${CACHE_DIR}" ]]; then
    if [[ -d /persist && -w /persist ]]; then
        CACHE_DIR="/persist/docker-image-cache/network-renderer-containerlab-linux-backend"
    else
        CACHE_DIR="${DIR}/.cache"
    fi
fi

CACHE_TAR="${CLAB_FRR_TOOLING_CACHE_TAR:-${CACHE_DIR}/clab-frr-plus-tooling-${CACHE_KEY}.tar}"
CACHE_ID_FILE="${CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE:-${CACHE_TAR}.image-id}"
BASE_IMAGE="${CLAB_FRR_TOOLING_BASE_IMAGE:-frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce}"

current_id() {
    docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true
}

current_cache_key() {
    docker image inspect --format "{{ index .Config.Labels \"${LABEL_KEY}\" }}" "$IMAGE" 2>/dev/null || true
}

cache_id() {
    if [[ -n "${CACHE_ID_FILE}" && -f "${CACHE_ID_FILE}" ]]; then
        cat "${CACHE_ID_FILE}"
    fi
}

base_image_ref() {
    local base_id=""
    local existing_id=""

    base_id="$(docker image inspect --format '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null || true)"
    if [[ -n "${base_id}" ]]; then
        printf '%s\n' "${base_id}"
        return 0
    fi

    existing_id="$(current_id)"
    if [[ -n "${existing_id}" ]]; then
        printf '%s\n' "${existing_id}"
        return 0
    fi

    printf '%s\n' "${BASE_IMAGE}"
}

image_matches_cache_key() {
    if [[ "$(current_cache_key)" == "${CACHE_KEY}" ]]; then
        return 0
    fi

    if [[ -n "$(cache_id)" && "$(current_id)" == "$(cache_id)" ]]; then
        return 0
    fi

    return 1
}

image_is_usable() {
    image_matches_cache_key && return 0

    if [[ "${ALLOW_EXISTING_IMAGE}" != "0" && "${ALLOW_EXISTING_IMAGE}" != "false" ]] && [[ -n "$(current_id)" ]]; then
        return 0
    fi

    return 1
}

verify_tooling_image() {
    docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
        for cmd in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff udhcpd radvd; do
            command -v "$cmd" >/dev/null || {
                echo "missing FRR tooling package command: $cmd" >&2
                exit 1
            }
        done

        grep -q "^bgpd=yes" /etc/frr/daemons || {
            echo "FRR bgpd daemon is not enabled" >&2
            exit 1
        }
        if ! grep -q "^staticd=yes" /etc/frr/daemons \
            && ! grep -q "staticd daemons are always started" /etc/frr/daemons; then
            echo "FRR staticd daemon is not enabled or explicitly always-started" >&2
            exit 1
        fi
    '
}

maybe_load_cached_image() {
    local local_id=""
    local desired_id=""

    [[ -n "${CACHE_TAR}" && -f "${CACHE_TAR}" ]] || return 0

    local_id="$(current_id)"
    desired_id="$(cache_id)"

    if image_is_usable && [[ -n "${local_id}" && ( -z "${desired_id}" || "${local_id}" == "${desired_id}" ) ]]; then
        return 0
    fi

    echo "[clab] loading FRR tooling image cache from ${CACHE_TAR}..."
    docker load -i "${CACHE_TAR}" >/dev/null
}

maybe_load_cached_image

if [[ "${FORCE_REBUILD}" == "1" || "${FORCE_REBUILD}" == "true" ]] || ! image_is_usable; then
    mkdir -p "${CACHE_DIR}"
    echo "[clab] building local FRR tooling image for Dockerfile ${CACHE_KEY}..."
    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}" docker build \
        --pull=false \
        --build-arg "CLAB_FRR_BASE_IMAGE=$(base_image_ref)" \
        --label "${LABEL_KEY}=${CACHE_KEY}" \
        -t "$IMAGE" \
        "$DIR"

    verify_tooling_image

    if [[ "${SAVE_CACHE}" != "0" && "${SAVE_CACHE}" != "false" ]]; then
        echo "[clab] saving FRR tooling image cache to ${CACHE_TAR}..."
        docker save "$IMAGE" -o "${CACHE_TAR}"
        current_id > "${CACHE_ID_FILE}"
    fi
else
    echo "[clab] using cached FRR tooling image ${IMAGE} (${CACHE_KEY})"
    verify_tooling_image
    if [[ "${SAVE_CACHE}" != "0" && "${SAVE_CACHE}" != "false" && ! -f "${CACHE_TAR}" ]]; then
        mkdir -p "${CACHE_DIR}"
        echo "[clab] seeding FRR tooling image cache at ${CACHE_TAR}..."
        docker save "$IMAGE" -o "${CACHE_TAR}"
        current_id > "${CACHE_ID_FILE}"
    fi
fi
