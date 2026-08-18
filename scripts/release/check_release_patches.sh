#!/usr/bin/env bash
set -euo pipefail

LC_ALL=C
TZ=UTC
export LC_ALL TZ

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${SCRIPT_DIR}/common.sh"

require_release_overlay_root
cd "${REPO_ROOT}"

base_ref="${1:-HEAD}"

if ! git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
  if [ "${base_ref}" != "HEAD" ]; then
    echo "warning: ${base_ref} not found; falling back to HEAD" >&2
  fi
  base_ref="HEAD"
fi

verify_release_patch_target_hygiene
verify_release_patch_memory_exclusion

echo "Validating release patches against the post-sync base ${base_ref}."

patches=()
enforce_independent_apply="${RELEASE_PATCH_ENFORCE_INDEPENDENT_APPLY:-0}"
load_release_patch_series
patches=("${RELEASE_PATCHES[@]}")

if [ "${#patches[@]}" -eq 0 ]; then
  echo "No release patches found under ${PATCH_RELEASE_DIR}/"
  exit 0
fi

tmp_worktree="$(create_release_scratch_dir "patch-check")"
target_cache_dir="${CARGO_TARGET_DIR:-}"
owns_target_cache_dir=0
if [ -z "${target_cache_dir}" ]; then
  target_cache_dir="$(create_release_scratch_dir "patch-check-target")"
  owns_target_cache_dir=1
fi
case "${target_cache_dir}" in
  /tmp|/tmp/*)
    die "patch-check Cargo target directory must be disk-backed, not ${target_cache_dir}"
    ;;
esac
independent_worktree=""
cleanup() {
  if [ -n "${tmp_worktree:-}" ] && [ -d "${tmp_worktree}" ]; then
    git -c color.ui=never worktree remove "${tmp_worktree}" --force >/dev/null 2>&1 || true
    rm -rf "${tmp_worktree}" >/dev/null 2>&1 || true
  fi
  if [ -n "${independent_worktree:-}" ] && [ -d "${independent_worktree}" ]; then
    git -c color.ui=never worktree remove "${independent_worktree}" --force >/dev/null 2>&1 || true
    rm -rf "${independent_worktree}" >/dev/null 2>&1 || true
  fi
  if [ "${owns_target_cache_dir}" = "1" ] && [ -n "${target_cache_dir:-}" ] && [ -d "${target_cache_dir}" ]; then
    rm -rf "${target_cache_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if [ "${enforce_independent_apply}" = "1" ]; then
  echo "Verifying independent patch applicability in a clean worktree (${base_ref})..."
  independent_worktree="$(create_release_scratch_dir "patch-independent")"
  git -c color.ui=never worktree add --detach "${independent_worktree}" "${base_ref}" >/dev/null
  for patch in "${patches[@]}"; do
    echo "Checking independent release patch ${patch}"
    git -C "${independent_worktree}" -c color.ui=never apply --check "${APPLY_EXCLUDES[@]}" "${patch}"
  done
else
  echo "Skipping independent patch applicability checks; ordered application is the enforced contract."
fi

echo "Reconciling ordered patch application in a clean worktree (${base_ref})..."
CARGO_TARGET_DIR="${target_cache_dir}" \
  "${REPO_ROOT}/scripts/release/reconcile.sh" \
    --base-ref "${base_ref}" \
    --worktree-dir "${tmp_worktree}" \
    --skip-generated-artifacts \
    --keep-worktree >/dev/null

if [ -f "${tmp_worktree}/${RELEASE_VERIFY_DIR}/verify_prompt_inventory_contract.py" ]; then
  echo "Verifying tracked non-Rust instruction artifacts against the ordered patch application..."
  python3 "${tmp_worktree}/${RELEASE_VERIFY_DIR}/verify_prompt_inventory_contract.py" \
    --repo-root "${tmp_worktree}" \
    --artifacts-root "${REPO_ROOT}" \
    --skip-config
fi

echo "Verifying migration numeric versions are unique after ordered patch application..."
python3 "${tmp_worktree}/${RELEASE_VERIFY_DIR}/verify_unique_migration_versions.py" \
  --migrations-dir "${tmp_worktree}/codex-rs/state/migrations"

echo "Verifying Debian GNU release bin contract after ordered patch application..."
python3 "${tmp_worktree}/${RELEASE_VERIFY_DIR}/verify_release_bin_contract.py" \
  --repo-root "${tmp_worktree}"

echo "Verifying Rust release source contracts after ordered patch application..."
python3 "${tmp_worktree}/${RELEASE_VERIFY_DIR}/verify_rust_release_source_contract.py" \
  --repo-root "${tmp_worktree}"

echo "Skipping compile/build verification in scripts/check_release_patches.sh by policy."
echo "Run tiny, targeted cargo commands manually outside this script if source validation is needed."

if [ "${enforce_independent_apply}" = "1" ]; then
  echo "Release patches apply cleanly both independently and in order (${#patches[@]} patch(es)) on ${base_ref}."
else
  echo "Release patches apply cleanly in order (${#patches[@]} patch(es)) on ${base_ref}."
fi
