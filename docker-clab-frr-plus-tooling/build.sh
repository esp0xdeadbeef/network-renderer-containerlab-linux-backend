#!/usr/bin/env bash
set -euo pipefail

IMAGE="${CLAB_FRR_TOOLING_IMAGE:-clab-frr-plus-tooling:latest}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${DIR}/Dockerfile"
MATERIALIZER="${DIR}/protected-reservation-materializer.py"
LABEL_KEY="org.esp0xdeadbeef.clab-frr-plus-tooling.dockerfile-sha256"
FORCE_REBUILD="${CLAB_FRR_TOOLING_REBUILD:-${CLAB_FRR_TOOLING_FORCE_REBUILD:-0}}"
SAVE_CACHE="${CLAB_FRR_TOOLING_SAVE_CACHE:-1}"
ALLOW_EXISTING_IMAGE="${CLAB_FRR_TOOLING_ALLOW_EXISTING_IMAGE:-0}"
CACHE_EVIDENCE_JSON="${CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON:-}"
CACHE_PRESENT_AT_START=0
CACHE_LOADED=0
CACHE_BUILT=0
CACHE_SAVED=0
CACHE_SEEDED=0
CACHE_USED_EXISTING=0

dockerfile_hash() {
    sha256sum "${DOCKERFILE}" "${MATERIALIZER}" | sha256sum | awk '{print $1}'
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
BASE_IMAGE="${CLAB_FRR_TOOLING_BASE_IMAGE:-debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb}"

[[ -n "${CACHE_TAR}" && -f "${CACHE_TAR}" ]] && CACHE_PRESENT_AT_START=1

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

    base_id="$(docker image inspect --format '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null || true)"
    if [[ -n "${base_id}" ]]; then
        printf '%s\n' "${base_id}"
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
        for cmd in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff dhcpcd udhcpc udhcpd dnsmasq knotd knotc unbound unbound-checkconf vtysh python3 jq kea-dhcp4 kea-dhcp6 clab-protected-reservation-materializer; do
            command -v "$cmd" >/dev/null || {
                echo "missing FRR tooling package command: $cmd" >&2
                exit 1
            }
        done

        grep -q "^bgpd=yes" /etc/frr/daemons || {
            echo "FRR bgpd daemon is not enabled" >&2
            exit 1
        }
        test -x /usr/lib/frr/zebra || { echo "missing FRR zebra daemon" >&2; exit 1; }
        test -x /usr/lib/frr/bgpd || { echo "missing FRR bgpd daemon" >&2; exit 1; }
        test -x /usr/lib/frr/staticd || { echo "missing FRR staticd daemon" >&2; exit 1; }
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
    CACHE_LOADED=1
}

write_cache_evidence() {
    [[ -n "${CACHE_EVIDENCE_JSON}" ]] || return 0

    mkdir -p "$(dirname "${CACHE_EVIDENCE_JSON}")"
    CACHE_FINAL_IMAGE_ID="$(current_id)" \
    CACHE_FINAL_CACHE_KEY="$(current_cache_key)" \
    CACHE_PRESENT_AT_START="${CACHE_PRESENT_AT_START}" \
    CACHE_LOADED="${CACHE_LOADED}" \
    CACHE_BUILT="${CACHE_BUILT}" \
    CACHE_SAVED="${CACHE_SAVED}" \
    CACHE_SEEDED="${CACHE_SEEDED}" \
    CACHE_USED_EXISTING="${CACHE_USED_EXISTING}" \
    CACHE_IMAGE="${IMAGE}" \
    CACHE_KEY="${CACHE_KEY}" \
    CACHE_TAR="${CACHE_TAR}" \
    CACHE_ID_FILE="${CACHE_ID_FILE}" \
    CACHE_SAVE_ENABLED="${SAVE_CACHE}" \
    CACHE_ALLOW_EXISTING_IMAGE="${ALLOW_EXISTING_IMAGE}" \
    "${CLABGEN_PYTHON:-python3}" - "${CACHE_EVIDENCE_JSON}" <<'PY'
import json
import os
import sys
from pathlib import Path


def bool_env(name: str) -> bool:
    return os.environ.get(name) in {"1", "true"}


payload = {
    "schema": "clab-frr-tooling-cache-evidence.v1",
    "image": os.environ["CACHE_IMAGE"],
    "cacheKey": os.environ["CACHE_KEY"],
    "cacheTar": os.environ["CACHE_TAR"],
    "cacheImageIdFile": os.environ["CACHE_ID_FILE"],
    "cachePresentAtStart": bool_env("CACHE_PRESENT_AT_START"),
    "cacheLoaded": bool_env("CACHE_LOADED"),
    "imageBuilt": bool_env("CACHE_BUILT"),
    "cacheSaved": bool_env("CACHE_SAVED"),
    "cacheSeeded": bool_env("CACHE_SEEDED"),
    "existingImageUsed": bool_env("CACHE_USED_EXISTING"),
    "saveCacheEnabled": os.environ["CACHE_SAVE_ENABLED"] not in {"0", "false"},
    "allowExistingImage": os.environ["CACHE_ALLOW_EXISTING_IMAGE"] not in {"0", "false"},
    "finalImageId": os.environ.get("CACHE_FINAL_IMAGE_ID", ""),
    "finalCacheKey": os.environ.get("CACHE_FINAL_CACHE_KEY", ""),
}
Path(sys.argv[1]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "[clab] wrote FRR tooling image cache evidence to ${CACHE_EVIDENCE_JSON}"
}

maybe_load_cached_image

if [[ "${FORCE_REBUILD}" == "1" || "${FORCE_REBUILD}" == "true" ]] || ! image_is_usable; then
    mkdir -p "${CACHE_DIR}"
    echo "[clab] building local FRR tooling image for Dockerfile ${CACHE_KEY}..."
    CACHE_BUILT=1
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
        CACHE_SAVED=1
    fi
else
    echo "[clab] using cached FRR tooling image ${IMAGE} (${CACHE_KEY})"
    CACHE_USED_EXISTING=1
    verify_tooling_image
    if [[ "${SAVE_CACHE}" != "0" && "${SAVE_CACHE}" != "false" && ! -f "${CACHE_TAR}" ]]; then
        mkdir -p "${CACHE_DIR}"
        echo "[clab] seeding FRR tooling image cache at ${CACHE_TAR}..."
        docker save "$IMAGE" -o "${CACHE_TAR}"
        current_id > "${CACHE_ID_FILE}"
        CACHE_SAVED=1
        CACHE_SEEDED=1
    fi
fi

if [[ "${CACHE_PRESENT_AT_START}" == "0" && "${CACHE_BUILT}" != "1" ]]; then
    echo "diagnostic.clab-cache-absent-build-skipped: cache was absent but locked-source image build did not run" >&2
    exit 1
fi

if [[ "${CACHE_PRESENT_AT_START}" == "0" && "${CACHE_SAVED}" != "1" ]]; then
    echo "diagnostic.clab-cache-save-missing-before-ready: cache was absent and no cache artifact was saved before readiness" >&2
    exit 1
fi

write_cache_evidence
