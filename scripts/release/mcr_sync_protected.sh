#!/usr/bin/env bash
set -euo pipefail

LC_ALL=C
TZ=UTC
export LC_ALL TZ

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/mcr_sync_protected.sh [--release-tag TAG] [--no-push] [mirror-ref ...]

Sync flow:
  1) Fetch origin
  2) Merge mirror refs into mcr/main while preserving protected paths:
EOF
  print_release_protected_paths
  cat <<'EOF'
  3) Fast-forward mcr/main -> mcr/staging
  4) Check release patches on mcr/staging
  5) Fast-forward mcr/staging -> mcr/release
  6) Push mcr/main, mcr/staging, and mcr/release (unless --no-push)
  7) Optionally create and push a release tag on mcr/release tip

Default mirror ref: origin/gitlab/mcr/main
Allowed mirror refs:
  origin/gitlab/mcr/main
  origin/gitlab/mcr/staging
  gitlab/mcr/main
  gitlab/mcr/staging
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_clean_tracked_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree has tracked changes; commit/stash first"
  fi
}

is_merge_in_progress() {
  git rev-parse --verify --quiet MERGE_HEAD >/dev/null
}

validate_mirror_ref() {
  case "${1}" in
    origin/gitlab/mcr/main|origin/gitlab/mcr/staging|gitlab/mcr/main|gitlab/mcr/staging)
      ;;
    *)
      die "unsupported mirror ref '${1}'"
      ;;
  esac
}

require_ref() {
  local ref="${1}"
  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null \
    || die "missing git ref '${ref}'"
}

restore_protected_paths_from_ref() {
  local source_ref="$1"
  local path

  for path in "${RELEASE_PROTECTED_PATHS[@]}"; do
    if git ls-tree --name-only "${source_ref}" -- "${path}" | grep -Fxq "${path}"; then
      git restore --source="${source_ref}" --staged --worktree -- "${path}"
    else
      git rm -r --force --cached --ignore-unmatch -- "${path}" >/dev/null 2>&1 || true
      rm -rf -- "${path}"
    fi
  done
}

checkout_branch() {
  local branch="${1}"
  git checkout "${branch}" >/dev/null
}

merge_mirror_into_main_preserving_paths() {
  local mirror_ref="${1}"
  local main_before merge_rc unresolved

  checkout_branch mcr/main
  if git merge-base --is-ancestor "${mirror_ref}" mcr/main; then
    echo "mcr/main already contains ${mirror_ref}"
    return 0
  fi

  main_before="$(git rev-parse HEAD)"

  set +e
  git merge --no-ff --no-commit "${mirror_ref}"
  merge_rc=$?
  set -e

  # Protected paths are never imported from gitlab/* mirrors.
  restore_protected_paths_from_ref "${main_before}"

  unresolved="$(git diff --name-only --diff-filter=U || true)"
  if [ -n "${unresolved}" ]; then
    echo "unresolved merge conflicts after protected-path restore:" >&2
    printf '%s\n' "${unresolved}" >&2
    return 1
  fi

  if is_merge_in_progress; then
    git commit -m "merge: sync ${mirror_ref} into mcr/main preserving protected paths"
    return 0
  fi

  if [ "${merge_rc}" -ne 0 ]; then
    die "merge from ${mirror_ref} failed before commit"
  fi
}

merge_main_into_staging() {
  checkout_branch mcr/staging
  if git merge-base --is-ancestor mcr/main mcr/staging; then
    echo "mcr/staging already contains mcr/main"
    return 0
  fi
  git merge --ff-only mcr/main
}

check_release_patches_on_staging() {
  checkout_branch mcr/staging
  scripts/check_release_patches.sh HEAD
}

fast_forward_release_from_staging() {
  checkout_branch mcr/release
  git merge --ff-only mcr/staging
}

push_branches() {
  git push origin mcr/main mcr/staging mcr/release
}

create_release_tag() {
  local tag="${1}"
  if [ -z "${tag}" ]; then
    return 0
  fi

  if ! printf '%s' "${tag}" | grep -Eq '(^[0-9]{1,10}$|^.*[^0-9][0-9]{1,10}$)'; then
    die "release tag must end in a numeric suffix (1-10 digits): ${tag}"
  fi

  checkout_branch mcr/release
  git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null \
    && die "tag already exists: ${tag}"

  git tag "${tag}" mcr/release
  git push origin "${tag}"
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${repo_root}" ] || die "run inside a git repository"
cd "${repo_root}"

start_branch="$(git branch --show-current || true)"
cleanup() {
  local rc=$?
  if is_merge_in_progress; then
    git merge --abort >/dev/null 2>&1 || true
  fi
  if [ -n "${start_branch}" ] && [ "${start_branch}" != "$(git branch --show-current || true)" ]; then
    git checkout "${start_branch}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}
trap cleanup EXIT

release_tag=""
should_push="true"
mirror_refs=()

while [ $# -gt 0 ]; do
  case "${1}" in
    --help|-h)
      usage
      exit 0
      ;;
    --release-tag)
      [ $# -ge 2 ] || die "--release-tag requires a value"
      release_tag="${2}"
      shift 2
      ;;
    --no-push)
      should_push="false"
      shift
      ;;
    *)
      mirror_refs+=("${1}")
      shift
      ;;
  esac
done

if [ "${#mirror_refs[@]}" -eq 0 ]; then
  mirror_refs=("origin/gitlab/mcr/main")
fi

for mirror_ref in "${mirror_refs[@]}"; do
  validate_mirror_ref "${mirror_ref}"
done

require_clean_tracked_tree

for branch in mcr/main mcr/staging mcr/release; do
  require_ref "${branch}"
done

git fetch origin --prune --prune-tags

for mirror_ref in "${mirror_refs[@]}"; do
  require_ref "${mirror_ref}"
  merge_mirror_into_main_preserving_paths "${mirror_ref}"
done

merge_main_into_staging
check_release_patches_on_staging
fast_forward_release_from_staging

if [ "${should_push}" = "true" ]; then
  push_branches
fi

create_release_tag "${release_tag}"

echo "Sync complete."
