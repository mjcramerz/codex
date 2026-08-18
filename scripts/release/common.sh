#!/usr/bin/env bash

if [ -n "${_RELEASE_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
_RELEASE_COMMON_SH_LOADED=1

PATCH_RELEASE_DIR="${PATCH_RELEASE_DIR:-debian/patches}"
PATCH_SERIES_FILE="${PATCH_SERIES_FILE:-${PATCH_RELEASE_DIR}/series}"
RELEASE_VERIFY_DIR="${RELEASE_VERIFY_DIR:-patches/release}"
RELEASE_CONTRACT_HELPER="${RELEASE_CONTRACT_HELPER:-${REPO_ROOT}/scripts/release/release_contract.py}"
RELEASE_PROTECTED_PATHS=(
  "AGENTS.override.md"
  ".gitlab-ci.yml"
  "Makefile"
  ".cirrus.yml"
  ".github"
  "debian"
  "scripts/release"
  "${RELEASE_VERIFY_DIR}"
  ".mcr"
  ".circleci"
  ".devcontainer"
  ".vscode"
  ".codex"
  ".agents"
  "bazel/release"
)
# Consumed by release scripts that source this library.
# shellcheck disable=SC2034
APPLY_EXCLUDES=(
  "--exclude=${PATCH_RELEASE_DIR}/ROLLOUT*"
  "--exclude=${PATCH_RELEASE_DIR}/rollouts/*"
)

log() {
  local level="$1"
  shift
  printf '%s %s\n' "${level}" "$*" >&2
}

info() {
  log "INFO:" "$@"
}

warn() {
  log "WARN:" "$@"
}

die() {
  log "ERROR:" "$@"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

run() {
  "$@"
}

release_scratch_root() {
  local root="${RELEASE_CACHE_ROOT:-/pool/cache/codex}"

  case "${root}" in
    /tmp|/tmp/*)
      die "release scratch storage must be disk-backed, not ${root}"
      ;;
    /*) ;;
    *)
      die "release scratch storage must be an absolute path: ${root}"
      ;;
  esac

  mkdir -p -- "${root}"
  printf '%s\n' "${root}"
}

create_release_scratch_dir() {
  local prefix="$1"
  local root

  root="$(release_scratch_root)"
  mktemp -d "${root}/${prefix}.XXXXXX"
}

create_release_scratch_file() {
  local prefix="$1"
  local root

  root="$(release_scratch_root)"
  mktemp "${root}/${prefix}.XXXXXX"
}

print_release_protected_paths() {
  local path

  for path in "${RELEASE_PROTECTED_PATHS[@]}"; do
    case "${path}" in
      *.md|*.yml)
        printf '       %s\n' "${path}"
        ;;
      *)
        printf '       %s/\n' "${path}"
        ;;
    esac
  done
}

release_path_is_overlay_owned() {
  local path="$1"

  case "${path}" in
    AGENTS.override.md|.gitlab-ci.yml|Makefile|.cirrus.yml|.github/*|debian/*|scripts/release/*|patches/release/*|.mcr/*|.circleci/*|.devcontainer/*|.vscode/*|.codex/*|.agents/*|bazel/release/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_release_overlay_root() {
  [ -f "${REPO_ROOT}/.gitlab-ci.yml" ] || die "missing ${REPO_ROOT}/.gitlab-ci.yml"
  [ -d "${REPO_ROOT}/${PATCH_RELEASE_DIR}" ] || die "missing ${REPO_ROOT}/${PATCH_RELEASE_DIR}"
  [ -d "${REPO_ROOT}/${RELEASE_VERIFY_DIR}" ] || die "missing ${REPO_ROOT}/${RELEASE_VERIFY_DIR}"
  [ -f "${RELEASE_CONTRACT_HELPER}" ] || die "missing ${RELEASE_CONTRACT_HELPER}"
}

resolve_default_base_ref() {
  local ref
  for ref in mcr/main origin/gitlab/mcr/main gitlab/mcr/main HEAD; do
    if git -C "${REPO_ROOT}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
      printf '%s\n' "${ref}"
      return 0
    fi
  done

  return 1
}

verify_release_patch_target_hygiene() {
  info "Verifying release patch target hygiene"
  run python3 \
    "${RELEASE_CONTRACT_HELPER}" \
    verify-patch-targets \
    --patches-dir "${REPO_ROOT}/${PATCH_RELEASE_DIR}" \
    --series-file "${REPO_ROOT}/${PATCH_SERIES_FILE}"
}

verify_release_patch_memory_exclusion() {
  info "Verifying release patches exclude memory logic"
  run python3 \
    "${RELEASE_CONTRACT_HELPER}" \
    verify-memory-exclusion \
    --patches-dir "${REPO_ROOT}/${PATCH_RELEASE_DIR}" \
    --series-file "${REPO_ROOT}/${PATCH_SERIES_FILE}"
}

load_release_patch_series() {
  local tmp_output
  tmp_output="$(create_release_scratch_file "release-series")"
  if ! run python3 \
    "${RELEASE_CONTRACT_HELPER}" \
    print-patch-series \
    --patches-dir "${REPO_ROOT}/${PATCH_RELEASE_DIR}" \
    --series-file "${REPO_ROOT}/${PATCH_SERIES_FILE}" \
    --format nul >"${tmp_output}"; then
    rm -f -- "${tmp_output}"
    return 1
  fi
  # Consumed by release scripts that source this library.
  # shellcheck disable=SC2034
  mapfile -d '' RELEASE_PATCHES < "${tmp_output}"
  rm -f -- "${tmp_output}"
}

run_release_verifier_if_present() {
  local worktree_dir="$1"
  local script_name="$2"
  local description="$3"
  local verifier="${worktree_dir}/${RELEASE_VERIFY_DIR}/${script_name}"

  if [ -f "${verifier}" ]; then
    info "${description}"
    run python3 "${verifier}" --repo-root "${worktree_dir}"
  fi
}
