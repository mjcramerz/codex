#!/usr/bin/env bash
set -euo pipefail

LC_ALL=C
TZ=UTC
export LC_ALL TZ

usage() {
  cat <<'USAGE'
Usage: scripts/refresh_release_patch_3way.sh [--base-ref REF] [--keep-worktree] [--enable-rerere] <patch>

Refresh a release overlay patch against a new base using 3-way apply.

Arguments:
  <patch>                Path to patch file (typically debian/patches/*.patch).

Options:
  --base-ref REF         Base commit/ref to refresh against (default: HEAD).
  --keep-worktree        Keep temporary worktree on success.
  --enable-rerere        Persist rerere in the repository config for future conflict reuse.
  -h, --help             Show this help text.

Notes:
  - The refreshed patch is written in place.
  - A strict `git apply --check` is run at the end.
  - On 3-way conflict failure, the temporary worktree is preserved for manual resolution.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${REPO_ROOT}" ] || die "run this script inside a git repository"
cd "${REPO_ROOT}"
source "${REPO_ROOT}/scripts/release/common.sh"

BASE_REF="HEAD"
KEEP_WORKTREE="false"
ENABLE_RERERE="false"
PATCH_ARG=""

while [ $# -gt 0 ]; do
  case "${1}" in
    --base-ref)
      [ $# -ge 2 ] || die "--base-ref requires a value"
      BASE_REF="${2}"
      shift 2
      ;;
    --keep-worktree)
      KEEP_WORKTREE="true"
      shift
      ;;
    --enable-rerere)
      ENABLE_RERERE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: ${1}"
      ;;
    *)
      if [ -n "${PATCH_ARG}" ]; then
        die "only one patch path can be provided"
      fi
      PATCH_ARG="${1}"
      shift
      ;;
  esac
done

[ -n "${PATCH_ARG}" ] || die "missing patch path"
git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null || die "missing git ref '${BASE_REF}'"

PATCH_PATH="${PATCH_ARG}"
case "${PATCH_PATH}" in
  /*) ;;
  *) PATCH_PATH="${REPO_ROOT}/${PATCH_PATH}" ;;
esac
[ -f "${PATCH_PATH}" ] || die "patch file not found: ${PATCH_PATH}"

case "${PATCH_PATH}" in
  "${REPO_ROOT}"/*) ;;
  *) die "patch path must be inside repository: ${PATCH_PATH}" ;;
esac

mapfile -t PATCH_PATHS < <(
  awk '/^diff --git a\// { sub(/^diff --git a\//, ""); sub(/ b\/.*/, ""); print }' "${PATCH_PATH}" \
    | awk '!seen[$0]++'
)

[ "${#PATCH_PATHS[@]}" -gt 0 ] || die "patch does not contain diff entries: ${PATCH_PATH}"

if [ "${ENABLE_RERERE}" = "true" ]; then
  git config rerere.enabled true
  git config rerere.autoupdate true
fi

TMP_WORKTREE="$(create_release_scratch_dir "refresh-release-patch-3way")"
cleanup() {
  local rc=$?
  if [ -n "${TMP_WORKTREE:-}" ] && [ -d "${TMP_WORKTREE}" ] && [ "${KEEP_WORKTREE}" != "true" ]; then
    git -c color.ui=never worktree remove "${TMP_WORKTREE}" --force >/dev/null 2>&1 || true
    rm -rf "${TMP_WORKTREE}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}
trap cleanup EXIT INT TERM

git -c color.ui=never worktree add --detach "${TMP_WORKTREE}" "${BASE_REF}" >/dev/null

git -C "${TMP_WORKTREE}" config rerere.enabled true
git -C "${TMP_WORKTREE}" config rerere.autoupdate true

if ! git -C "${TMP_WORKTREE}" -c color.ui=never apply --3way "${PATCH_PATH}"; then
  KEEP_WORKTREE="true"
  cat <<EOM >&2
error: 3-way apply failed.
worktree preserved for manual conflict resolution:
  ${TMP_WORKTREE}
resolve conflicts there, then regenerate patch with:
  git -C "${TMP_WORKTREE}" diff --binary -- ${PATCH_PATHS[*]} > "${PATCH_PATH}"
EOM
  exit 1
fi

TMP_PATCH="$(create_release_scratch_file "refresh-release-patch")"
git -C "${TMP_WORKTREE}" -c color.ui=never diff --binary HEAD -- "${PATCH_PATHS[@]}" > "${TMP_PATCH}"

if [ ! -s "${TMP_PATCH}" ]; then
  rm -f "${TMP_PATCH}"
  die "refreshed patch is empty: ${PATCH_PATH}"
fi

mv "${TMP_PATCH}" "${PATCH_PATH}"

git -c color.ui=never apply --check "${PATCH_PATH}" || die "refreshed patch failed strict apply check"

echo "Refreshed patch: ${PATCH_PATH}"
echo "Base ref: ${BASE_REF}"
if [ "${ENABLE_RERERE}" = "true" ]; then
  echo "rerere persisted in repo config (rerere.enabled=true, rerere.autoupdate=true)"
fi
if [ "${KEEP_WORKTREE}" = "true" ]; then
  echo "temporary worktree kept at: ${TMP_WORKTREE}"
fi
