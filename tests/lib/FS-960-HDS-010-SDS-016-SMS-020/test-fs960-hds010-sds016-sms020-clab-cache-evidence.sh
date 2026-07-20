#!/usr/bin/env bash
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
build_script="${repo_root}/docker-clab-frr-plus-tooling/build.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_DOCKER_STATE_DIR:?}"
image_id_file="${state_dir}/image-id"
label_file="${state_dir}/label"

case "$1" in
  image)
    [[ "$2" == "inspect" ]] || exit 2
    format=""
    if [[ "${3:-}" == "--format" ]]; then
      format="$4"
    fi
    if [[ ! -f "${image_id_file}" ]]; then
      exit 1
    fi
    if [[ "${format}" == "{{.Id}}" ]]; then
      cat "${image_id_file}"
    elif [[ "${format}" == *".Config.Labels"* ]]; then
      cat "${label_file}" 2>/dev/null || true
    else
      cat "${image_id_file}"
    fi
    ;;
  load)
    while (($# > 0)); do
      case "$1" in
        -i)
          cache_tar="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    cp "${FAKE_DOCKER_CACHE_ID_FILE}" "${image_id_file}"
    printf '%s\n' "${CLAB_FRR_TOOLING_CACHE_KEY}" >"${label_file}"
    printf 'loaded %s\n' "${cache_tar:-}"
    ;;
  build)
    printf 'sha256:built\n' >"${image_id_file}"
    printf '%s\n' "${CLAB_FRR_TOOLING_CACHE_KEY}" >"${label_file}"
    ;;
  run)
    exit 0
    ;;
  save)
    output=""
    while (($# > 0)); do
      case "$1" in
        -o)
          output="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "${output}" ]] || exit 2
    mkdir -p "$(dirname "${output}")"
    printf 'fake image tar\n' >"${output}"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

run_build() {
  local case_name="$1"
  local cache_mode="$2"
  local case_dir="${tmp_dir}/${case_name}"
  local cache_dir="${case_dir}/cache"
  local state_dir="${case_dir}/state"
  local evidence="${case_dir}/evidence.json"
  local cache_tar="${cache_dir}/tooling.tar"
  local cache_id="${cache_tar}.image-id"

  mkdir -p "${cache_dir}" "${state_dir}"
  if [[ "${cache_mode}" == "present" ]]; then
    printf 'fake cached image tar\n' >"${cache_tar}"
    printf 'sha256:cached\n' >"${cache_id}"
  fi

  PATH="${fake_bin}:${PATH}" \
  FAKE_DOCKER_STATE_DIR="${state_dir}" \
  FAKE_DOCKER_CACHE_ID_FILE="${cache_id}" \
  CLAB_FRR_TOOLING_IMAGE="fake-clab-tooling:${case_name}" \
  CLAB_FRR_TOOLING_CACHE_KEY="contract-key-${case_name}" \
  CLAB_FRR_TOOLING_CACHE_TAR="${cache_tar}" \
  CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE="${cache_id}" \
  CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON="${evidence}" \
  "${build_script}" >/dev/null

  python3 - "${evidence}" "${cache_mode}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mode = sys.argv[2]
assert payload["schema"] == "clab-frr-tooling-cache-evidence.v1"
if mode == "present":
    assert payload["cachePresentAtStart"] is True
    assert payload["cacheLoaded"] is True
    assert payload["imageBuilt"] is False
    assert payload["cacheSaved"] is False
    assert payload["existingImageUsed"] is True
    assert payload["finalImageId"] == "sha256:cached"
else:
    assert payload["cachePresentAtStart"] is False
    assert payload["cacheLoaded"] is False
    assert payload["imageBuilt"] is True
    assert payload["cacheSaved"] is True
    assert payload["existingImageUsed"] is False
    assert payload["finalImageId"] == "sha256:built"
PY
}

run_build cache-present present
run_build cache-absent absent

echo "PASS clab-tooling-cache-evidence"
