#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-050
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests wait_for_docker privileged inspection with distinguishable failure modes:
# permission denial, daemon absence, sudo misconfiguration, and success paths.
# Uses CLAB_TEST_EUID to control root/non-root simulation without modifying
# the readonly EUID shell variable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_script="${repo_root}/deploy-clab.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

# Isolate the wait_for_docker function from deploy-clab.sh.
# The function uses 'fail' which is defined at the top of deploy-clab.sh.
fail() { printf '[deploy-clab] error: %s\n' "$*" >&2; exit 1; }

# Extract wait_for_docker from deploy-clab.sh for isolated testing.
eval "$(
  awk '/^wait_for_docker\(\) \{/,/^\}/' "${deploy_script}"
)"

failures=0

# ---------------------------------------------------------------------------
# Test 1: Docker daemon not running — "Cannot connect" on stderr.
# Simulates non-root (CLAB_TEST_EUID=1000) without sudo, so docker runs
# directly and reports "Cannot connect".
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
exit 1
SH
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${fake_bin}/systemctl"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test1.stderr"; then
  echo "FAIL test1: expected daemon-absence failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker did not become ready after 2s (daemon may not be running or unreachable)' "${tmp_dir}/test1.stderr"; then
    echo "PASS test1: daemon-absence distinguished"
  else
    echo "FAIL test1: wrong error message" >&2
    cat "${tmp_dir}/test1.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Permission denied — "Got permission denied" on stderr.
# Simulates non-root without sudo, docker socket permission error.
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
exit 1
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test2.stderr"; then
  echo "FAIL test2: expected permission-denied failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker permission denied' "${tmp_dir}/test2.stderr"; then
    echo "PASS test2: permission-denied distinguished"
  else
    echo "FAIL test2: wrong error message" >&2
    cat "${tmp_dir}/test2.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: sudo -n fails with "password is required".
# Simulates non-root with sudo available, but sudo -n rejects.
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "FAIL: docker called directly when sudo was expected" >&2
exit 99
SH
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/sudo" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
shift
exec "$@"
SH
chmod +x "${fake_bin}/sudo"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  wait_for_docker
) 2>"${tmp_dir}/test3.stderr"; then
  echo "FAIL test3: expected sudo-password failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker privilege check failed' "${tmp_dir}/test3.stderr"; then
    echo "PASS test3: sudo-password-required distinguished"
  else
    echo "FAIL test3: wrong error message" >&2
    cat "${tmp_dir}/test3.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: Success path — root context (CLAB_TEST_EUID=0)
# Docker info returns 0, no sudo needed.
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Server Version: 27.0.0" >&2
exit 0
SH
chmod +x "${fake_bin}/docker"

rm -f "${fake_bin}/sudo"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=0
  wait_for_docker
) 2>"${tmp_dir}/test4.stderr"; then
  echo "PASS test4: success path (root) works"
else
  echo "FAIL test4: root success path failed" >&2
  cat "${tmp_dir}/test4.stderr" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 5 (seeded negative): Lowercase "permission denied" detection.
# Ensures the case-insensitive matching works.
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "error: permission denied" >&2
exit 1
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test2.stderr"; then
  echo "FAIL test5: expected lowercase permission-denied failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker permission denied' "${tmp_dir}/test2.stderr"; then
    echo "PASS test5: lowercase permission-denied detected"
  else
    echo "FAIL test5: lowercase permission-denied not detected" >&2
    cat "${tmp_dir}/test2.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 6 (seeded negative): Success via sudo -n.
# Non-root (CLAB_TEST_EUID=1000) with sudo available and working.
# The direct docker binary is rigged to fail — only sudo -n docker should succeed.
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "docker called directly when sudo was expected" >&2
exit 99
SH
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/sudo" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  shift
  if [[ "$1" == "docker" && "$2" == "info" ]]; then
    echo "Server Version: 27.0.0" >&2
    exit 0
  fi
fi
echo "sudo: unexpected arguments: $*" >&2
exit 1
SH
chmod +x "${fake_bin}/sudo"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  wait_for_docker
) 2>"${tmp_dir}/test6.stderr"; then
  echo "PASS test6: success path (non-root via sudo -n) works"
else
  echo "FAIL test6: non-root sudo success path failed" >&2
  cat "${tmp_dir}/test6.stderr" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-050: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-050: all 6 acceptance predicates covered"
