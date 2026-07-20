#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-030
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests CLAB cache-absent build-and-save path with evidence JSON verification.
# Isolates docker-clab-frr-plus-tooling/build.sh via fake docker binary.
# Non-destructive: no real Docker, no real image build.
#
# Acceptance predicates from SMS-030:
#  1. Cache-absent path builds the Docker image (imageBuilt=true)
#  2. Cache-absent path saves the cache artifact (cacheSaved=true)
#  3. Cache-absent path reports cachePresentAtStart=false
#  4. Seeded negative: cache absent but build skipped is rejected
#  5. Seeded negative: build succeeds but cache is not saved is rejected
#  6. Cache-present path reports cachePresentAtStart=true
#     (proves the test discriminates absent from present)
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
build_script="${repo_root}/docker-clab-frr-plus-tooling/build.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

# ---------------------------------------------------------------------------
# Fake docker binary: simulates build, save, load, inspect, run, and image-id
# tracking. Uses FAKE_DOCKER_STATE_DIR for persistent state across invocations.
# ---------------------------------------------------------------------------
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
    # Simulate loading: copy cached image ID into state
    if [[ -n "${FAKE_DOCKER_CACHE_ID_FILE:-}" && -f "${FAKE_DOCKER_CACHE_ID_FILE}" ]]; then
      cp "${FAKE_DOCKER_CACHE_ID_FILE}" "${image_id_file}"
      printf '%s\n' "${CLAB_FRR_TOOLING_CACHE_KEY}" >"${label_file}"
    fi
    printf 'loaded %s\n' "${cache_tar:-}"
    ;;
  build)
    # Simulate build: generate a synthetic image ID and match the cache key label
    printf 'sha256:built-%s\n' "${CLAB_FRR_TOOLING_CACHE_KEY}" >"${image_id_file}"
    printf '%s\n' "${CLAB_FRR_TOOLING_CACHE_KEY}" >"${label_file}"
    ;;
  run)
    # Simulate verify_tooling_image: always succeed
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

# ---------------------------------------------------------------------------
# Helper: run build.sh with controlled env and return the evidence JSON path.
# ---------------------------------------------------------------------------
run_build() {
  local case_name="$1"
  local cache_mode="$2"   # "absent" or "present"
  local case_dir="${tmp_dir}/${case_name}"
  local cache_dir="${case_dir}/cache"
  local state_dir="${case_dir}/state"
  local evidence="${case_dir}/evidence.json"
  local cache_tar="${cache_dir}/clab-frr-plus-tooling-contract-key-${case_name}.tar"
  local cache_id="${cache_tar}.image-id"

  mkdir -p "${cache_dir}" "${state_dir}"

  if [[ "${cache_mode}" == "present" ]]; then
    # Pre-create the cache tar and image-id file — simulates cache present at start
    printf 'fake cached image tar\n' >"${cache_tar}"
    printf 'sha256:cached-%s\n' "${case_name}" >"${cache_id}"
  fi

  PATH="${fake_bin}:${PATH}" \
  FAKE_DOCKER_STATE_DIR="${state_dir}" \
  FAKE_DOCKER_CACHE_ID_FILE="${cache_id}" \
  CLAB_FRR_TOOLING_IMAGE="fake-clab-tooling:${case_name}" \
  CLAB_FRR_TOOLING_CACHE_KEY="contract-key-${case_name}" \
  CLAB_FRR_TOOLING_CACHE_DIR="${cache_dir}" \
  CLAB_FRR_TOOLING_CACHE_TAR="${cache_tar}" \
  CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE="${cache_id}" \
  CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON="${evidence}" \
  CLAB_FRR_TOOLING_SAVE_CACHE=1 \
  CLAB_FRR_TOOLING_ALLOW_EXISTING_IMAGE=0 \
  "${build_script}" >/dev/null

  printf '%s\n' "${evidence}"
}

run_build_expect_failure() {
  local case_name="$1"
  local failure_mode="$2" # "build-skipped" or "save-missing"
  local case_dir="${tmp_dir}/${case_name}"
  local cache_dir="${case_dir}/cache"
  local state_dir="${case_dir}/state"
  local evidence="${case_dir}/evidence.json"
  local stderr="${case_dir}/stderr"
  local cache_tar="${cache_dir}/clab-frr-plus-tooling-contract-key-${case_name}.tar"
  local cache_id="${cache_tar}.image-id"
  local allow_existing=0
  local save_cache=1

  mkdir -p "${cache_dir}" "${state_dir}"

  if [[ "${failure_mode}" == "build-skipped" ]]; then
    allow_existing=1
    printf 'sha256:existing-%s\n' "${case_name}" >"${state_dir}/image-id"
    printf '%s\n' "contract-key-${case_name}" >"${state_dir}/label"
  elif [[ "${failure_mode}" == "save-missing" ]]; then
    save_cache=0
  else
    echo "unknown failure mode: ${failure_mode}" >&2
    return 2
  fi

  if PATH="${fake_bin}:${PATH}" \
    FAKE_DOCKER_STATE_DIR="${state_dir}" \
    FAKE_DOCKER_CACHE_ID_FILE="${cache_id}" \
    CLAB_FRR_TOOLING_IMAGE="fake-clab-tooling:${case_name}" \
    CLAB_FRR_TOOLING_CACHE_KEY="contract-key-${case_name}" \
    CLAB_FRR_TOOLING_CACHE_DIR="${cache_dir}" \
    CLAB_FRR_TOOLING_CACHE_TAR="${cache_tar}" \
    CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE="${cache_id}" \
    CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON="${evidence}" \
    CLAB_FRR_TOOLING_SAVE_CACHE="${save_cache}" \
    CLAB_FRR_TOOLING_ALLOW_EXISTING_IMAGE="${allow_existing}" \
    "${build_script}" >/dev/null 2>"${stderr}"; then
    echo "expected ${failure_mode} to fail, but build.sh passed" >&2
    return 1
  fi

  printf '%s\n' "${stderr}"
}

failures=0

# ---------------------------------------------------------------------------
# Test 1: Cache-absent path — no cache tar at start.
#   build.sh should: detect no cache → build image → save cache → write evidence.
#   Expected evidence: cachePresentAtStart=false, imageBuilt=true, cacheSaved=true.
# ---------------------------------------------------------------------------
evidence_file="$(run_build cache-absent absent)"

python3 - "${evidence_file}" "absent" <<'PY'
import json, sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mode = sys.argv[2]

assert payload["schema"] == "clab-frr-tooling-cache-evidence.v1", f"bad schema: {payload['schema']}"
assert payload["cachePresentAtStart"] is False, f"expected cachePresentAtStart=false, got {payload['cachePresentAtStart']}"
assert payload["imageBuilt"] is True, f"expected imageBuilt=true, got {payload['imageBuilt']}"
assert payload["cacheSaved"] is True, f"expected cacheSaved=true, got {payload['cacheSaved']}"
assert payload["cacheLoaded"] is False, f"expected cacheLoaded=false, got {payload['cacheLoaded']}"
assert payload["existingImageUsed"] is False, f"expected existingImageUsed=false, got {payload['existingImageUsed']}"
assert payload["finalImageId"].startswith("sha256:built-"), f"bad finalImageId: {payload['finalImageId']}"
assert payload["finalCacheKey"] == payload["cacheKey"], "finalCacheKey should match cacheKey"
PY

if (( $? == 0 )); then
  echo "PASS test1: cache-absent path evidence correct (built, saved, not present at start)"
else
  echo "FAIL test1: cache-absent evidence check failed" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 2 (seeded negative): Cache absent but build skipped.
#   Existing image use is not enough for cache-miss readiness; the locked-source
#   build must run before parent readiness can pass.
# ---------------------------------------------------------------------------
stderr_file="$(run_build_expect_failure cache-absent-build-skipped build-skipped)"
if grep -q 'diagnostic.clab-cache-absent-build-skipped' "${stderr_file}"; then
  echo "PASS test2: seeded negative — cache absent but build skipped rejected"
else
  echo "FAIL test2: missing build-skipped diagnostic" >&2
  cat "${stderr_file}" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 3 (seeded negative): Build succeeds but cache is not saved.
#   Parent readiness must not pass until the /persist cache artifact is saved.
# ---------------------------------------------------------------------------
stderr_file="$(run_build_expect_failure cache-absent-save-missing save-missing)"
if grep -q 'diagnostic.clab-cache-save-missing-before-ready' "${stderr_file}"; then
  echo "PASS test3: seeded negative — build without cache save rejected before readiness"
else
  echo "FAIL test3: missing cache-save diagnostic" >&2
  cat "${stderr_file}" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 4: Cache-present path — inject a cache tar at start.
#   build.sh should: detect cache → load it → use existing image (no build).
#   Expected evidence: cachePresentAtStart=true, imageBuilt=false, cacheLoaded=true.
#   This proves the test discriminates absent from present.
# ---------------------------------------------------------------------------
evidence_file2="$(run_build cache-present-seeded present)"

python3 - "${evidence_file2}" "present" <<'PY'
import json, sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mode = sys.argv[2]

assert payload["schema"] == "clab-frr-tooling-cache-evidence.v1", f"bad schema: {payload['schema']}"
assert payload["cachePresentAtStart"] is True, f"expected cachePresentAtStart=true, got {payload['cachePresentAtStart']}"
assert payload["cacheLoaded"] is True, f"expected cacheLoaded=true, got {payload['cacheLoaded']}"
assert payload["imageBuilt"] is False, f"expected imageBuilt=false, got {payload['imageBuilt']}"
assert payload["existingImageUsed"] is True, f"expected existingImageUsed=true, got {payload['existingImageUsed']}"
PY

if (( $? == 0 )); then
  echo "PASS test4: cache-present path correctly distinguished"
else
  echo "FAIL test4: cache-present evidence check failed" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-030: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-030: cache-absent build/save acceptance predicates covered with active seeded negatives"
