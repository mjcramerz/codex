#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

LC_ALL=C
TZ=UTC
umask 022
export LC_ALL TZ

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/reconcile.sh [options]

Create a detached worktree at the selected base ref, copy the local release
overlay into it, apply the release patch series, regenerate the config schema,
and rebuild the tracked .mcr instruction/config artifacts from the patched tree.

Options:
  --base-ref REF        Git ref to checkout before applying release patches.
                        Defaults to the first available ref in:
                        origin/gitlab/mcr/main, gitlab/mcr/main, mcr/main.
  --worktree-dir DIR    Explicit worktree directory to reuse/create.
                        Must not be under /tmp.
  --keep-worktree       Preserve the reconciled worktree on exit.
  --skip-generated-artifacts
                        Skip config-schema and generated .mcr refresh.
  --sync-generated      Copy generated .mcr artifacts back into the source repo.
  -h, --help            Show this help text.
EOF
}

require_repo_root() {
  require_release_overlay_root
  [ -f "${REPO_ROOT}/justfile" ] || die "missing ${REPO_ROOT}/justfile"
  [ -f "${REPO_ROOT}/codex-rs/Cargo.toml" ] || die "missing ${REPO_ROOT}/codex-rs/Cargo.toml"
  [ -f "${REPO_ROOT}/scripts/release/instruct.pl" ] || die "missing scripts/release/instruct.pl"
  [ -f "${REPO_ROOT}/scripts/release/config.py" ] || die "missing scripts/release/config.py"
  [ -f "${REPO_ROOT}/scripts/release/instruction_inventory.json" ] || die "missing scripts/release/instruction_inventory.json"
}

copy_overlay_into_worktree() {
  local worktree_dir="$1"
  local path

  for path in "${RELEASE_PROTECTED_PATHS[@]}"; do
    [ -n "${worktree_dir}" ] || die "worktree directory must not be empty"
    [ -n "${path}" ] || die "release overlay path must not be empty"
    rm -rf -- "${worktree_dir:?}/${path:?}"
    if [ ! -e "${REPO_ROOT}/${path}" ]; then
      continue
    fi
    mkdir -p -- "$(dirname -- "${worktree_dir}/${path}")"
    cp -R -- "${REPO_ROOT}/${path}" "${worktree_dir}/${path}"
  done
}

apply_release_patches() {
  local worktree_dir="$1"
  local -a patches=()
  local patch

  mapfile -t patches < <(
    python3 "${worktree_dir}/scripts/release/release_contract.py" \
      print-patch-series \
      --patches-dir "${worktree_dir}/${PATCH_RELEASE_DIR}" \
      --series-file "${worktree_dir}/${PATCH_SERIES_FILE}"
  )
  [ "${#patches[@]}" -gt 0 ] || die "release patch series is empty"

  (
    cd -- "${worktree_dir}"
    info "Applying ordered Debian patch series from ${PATCH_RELEASE_DIR}"
    for patch in "${patches[@]}"; do
      info "Checking release patch ${patch}"
      run git apply --check -- "${patch}"
      info "Applying release patch ${patch}"
      run git apply -- "${patch}"
    done
  )
}

generate_overlay_artifacts() {
  local worktree_dir="$1"
  local schema_jobs="${MCR_SCHEMA_JOBS:-1}"
  local schema_debug="${MCR_SCHEMA_DEV_DEBUG:-0}"

  info "Regenerating config schema inside ${worktree_dir} (CARGO_BUILD_JOBS=${schema_jobs}, CARGO_PROFILE_DEV_DEBUG=${schema_debug})"
  (
    cd -- "${worktree_dir}"
    run env \
      CARGO_BUILD_JOBS="${schema_jobs}" \
      CARGO_INCREMENTAL=0 \
      CARGO_PROFILE_DEV_DEBUG="${schema_debug}" \
      just write-config-schema
  )

  info "Generating instruction artifacts inside ${worktree_dir}/.mcr"
  run perl "${worktree_dir}/scripts/release/instruct.pl" \
    --repo-root "${worktree_dir}" \
    --output-root "${worktree_dir}/.mcr"

  info "Generating config placeholder inside ${worktree_dir}/.mcr/config.toml"
  run python3 "${worktree_dir}/scripts/release/config.py" \
    --repo-root "${worktree_dir}" \
    --output-file "${worktree_dir}/.mcr/config.toml"
}

sync_generated_artifacts_back() {
  local worktree_dir="$1"
  local source_root="${worktree_dir}/.mcr"
  local dest_root="${REPO_ROOT}/.mcr"

  [ -d "${source_root}/override-instructions" ] || die "missing ${source_root}/override-instructions"
  [ -d "${source_root}/static-instructions" ] || die "missing ${source_root}/static-instructions"
  [ -f "${source_root}/config.toml" ] || die "missing ${source_root}/config.toml"

  mkdir -p -- "${dest_root}"
  rm -rf -- "${dest_root}/override-instructions" "${dest_root}/static-instructions"
  cp -R -- "${source_root}/override-instructions" "${dest_root}/"
  cp -R -- "${source_root}/static-instructions" "${dest_root}/"
  cp -- "${source_root}/config.toml" "${dest_root}/config.toml"
}

BASE_REF=""
WORKTREE_DIR=""
KEEP_WORKTREE="false"
SKIP_GENERATED_ARTIFACTS="false"
SYNC_GENERATED="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref)
      [ $# -ge 2 ] || die "--base-ref requires a value"
      BASE_REF="$2"
      shift 2
      ;;
    --worktree-dir)
      [ $# -ge 2 ] || die "--worktree-dir requires a value"
      WORKTREE_DIR="$2"
      shift 2
      ;;
    --keep-worktree)
      KEEP_WORKTREE="true"
      shift
      ;;
    --skip-generated-artifacts)
      SKIP_GENERATED_ARTIFACTS="true"
      shift
      ;;
    --sync-generated)
      SYNC_GENERATED="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd git
require_cmd just
require_cmd perl
require_cmd python3
require_repo_root

verify_release_patch_target_hygiene
verify_release_patch_memory_exclusion

if [ -z "${BASE_REF}" ]; then
  BASE_REF="$(resolve_default_base_ref)" || die "failed to resolve a default base ref"
fi
git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null \
  || die "missing git ref: ${BASE_REF}"

if [ -z "${WORKTREE_DIR}" ]; then
  WORKTREE_DIR="$(create_release_scratch_dir "reconcile")"
fi
case "${WORKTREE_DIR}" in
  /tmp|/tmp/*)
    die "reconciled worktree must use disk-backed release storage, not ${WORKTREE_DIR}"
    ;;
  /*) ;;
  *)
    die "reconciled worktree must be an absolute path: ${WORKTREE_DIR}"
    ;;
esac

cleanup() {
  local rc=$?
  if [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR}" ] && [ "${KEEP_WORKTREE}" != "true" ]; then
    git -C "${REPO_ROOT}" -c color.ui=never worktree remove "${WORKTREE_DIR}" --force >/dev/null 2>&1 || true
    rm -rf -- "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  elif [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR}" ]; then
    warn "reconciled worktree preserved at ${WORKTREE_DIR}"
  fi
  return "${rc}"
}
trap cleanup EXIT INT TERM

load_release_patch_series
[ "${#RELEASE_PATCHES[@]}" -gt 0 ] || die "no release patches found under ${REPO_ROOT}/${PATCH_RELEASE_DIR}"

info "Creating detached worktree at ${WORKTREE_DIR} from ${BASE_REF}"
run git -C "${REPO_ROOT}" -c color.ui=never worktree add --detach "${WORKTREE_DIR}" "${BASE_REF}"

info "Copying local release overlay into ${WORKTREE_DIR}"
copy_overlay_into_worktree "${WORKTREE_DIR}"

info "Applying ordered release patch stack"
apply_release_patches "${WORKTREE_DIR}"

if [ "${SKIP_GENERATED_ARTIFACTS}" != "true" ]; then
  generate_overlay_artifacts "${WORKTREE_DIR}"

  run_release_verifier_if_present \
    "${WORKTREE_DIR}" \
    "verify_prompt_inventory_contract.py" \
    "Validating instruction inventory after patch application"

  if [ "${SYNC_GENERATED}" = "true" ]; then
    info "Copying generated .mcr artifacts back into ${REPO_ROOT}"
    sync_generated_artifacts_back "${WORKTREE_DIR}"
  fi
elif [ "${SYNC_GENERATED}" = "true" ]; then
  die "--sync-generated requires generated artifacts; omit --skip-generated-artifacts"
fi

printf '%s\n' "${WORKTREE_DIR}"
