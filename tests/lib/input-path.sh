#!/usr/bin/env bash
set -euo pipefail

require_github_input_origin() {
  local input_name="$1"
  local input_origin
  input_origin="$(
    INPUT_NAME="${input_name}" FLAKE_LOCK="${repo_root}/flake.lock" \
    nix eval --impure --raw --expr '
      let
        lock = builtins.fromJSON (builtins.readFile (builtins.getEnv "FLAKE_LOCK"));
        name = builtins.getEnv "INPUT_NAME";
        node = lock.nodes.${name} or null;
        original = if node == null then null else node.original or null;
      in
        if original == null then
          "missing-origin"
        else if (original.type or null) == "github" then
          "github:" + (original.owner or "") + "/" + (original.repo or "")
        else if (original.type or null) == "git" then
          (original.url or "missing-origin")
        else
          (original.type or "unknown")
    '
  )"

  if [[ "${input_origin}" == missing-origin || -z "${input_origin}" ]]; then
    echo "tests: missing origin metadata for input ${input_name} in flake.lock" >&2
    return 1
  fi

  case "${input_origin}" in
    github:*) ;;
    http://github.com/*|https://github.com/*|git+https://github.com/*) ;;
    git://github.com/*|git+ssh://*|ssh://git@github.com/*|git@github.com:*) 
      echo "tests: input ${input_name} is not pinned to GitHub HTTPS flake URL (${input_origin})" >&2
      return 1
      ;;
    *)
      echo "tests: input ${input_name} has unexpected origin ${input_origin}" >&2
      return 1
      ;;
  esac
}

resolve_input_path() {
  local input_name="$1"
  local archive_json
  local archive_stderr
  local input_path

  require_github_input_origin "${input_name}"

  archive_json="$(mktemp)"
  archive_stderr="$(mktemp)"
  if ! nix flake archive --json "path:${repo_root}" >"${archive_json}" 2>"${archive_stderr}"; then
    echo "tests: failed to evaluate flake inputs via nix flake archive" >&2
    echo "tests: expected GitHub access to network inputs from the flake" >&2
    if [[ -s "${archive_stderr}" ]]; then
      cat "${archive_stderr}" >&2
    fi
    rm -f "${archive_json}" "${archive_stderr}"
    return 1
  fi

  if [[ ! -s "${archive_json}" ]]; then
    echo "tests: nix flake archive produced no output; cannot resolve ${input_name}" >&2
    if [[ -s "${archive_stderr}" ]]; then
      cat "${archive_stderr}" >&2
    fi
    rm -f "${archive_json}" "${archive_stderr}"
    return 1
  fi

  input_path="$(
    INPUT_NAME="${input_name}" ARCHIVE_JSON="${archive_json}" \
    nix eval --impure --raw --expr '
      let
        archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
        name = builtins.getEnv "INPUT_NAME";
        input = archived.inputs.${name} or null;
        p = if input == null then null else input.path or null;
      in
        if p == null then
          throw "tests: missing archived input path for " + name
        else
          p
    '
  )"

  rm -f "${archive_json}" "${archive_stderr}"

  [[ -n "${input_path}" ]] || { echo "tests: missing archived input path for ${input_name}" >&2; return 1; }
  [[ -d "${input_path}" ]] || { echo "tests: invalid input path for ${input_name}: ${input_path}" >&2; return 1; }

  printf '%s
' "${input_path}"
}

resolve_labs_model_dir() {
  local labs_path="$1"
  local model_name="$2"

  local example_dir="${labs_path}/examples/${model_name}"
  if [[ -f "${example_dir}/intent.nix" ]]; then
    printf '%s\n' "${example_dir}"
    return 0
  fi

  local lab_dir="${labs_path}/labs/lab-s-sigma/${model_name}"
  if [[ -f "${lab_dir}/intent.nix" ]]; then
    printf '%s\n' "${lab_dir}"
    return 0
  fi

  echo "tests: missing model ${model_name} under examples/ or labs/lab-s-sigma/" >&2
  return 1
}
