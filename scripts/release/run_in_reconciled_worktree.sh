#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

LC_ALL=C
TZ=UTC
export LC_ALL TZ

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/run_in_reconciled_worktree.sh <command> [args...]

Create a temporary reconciled worktree rooted at the current release overlay,
then run the provided command from that worktree root.
EOF
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 1
fi

read_toolchain_channel() {
  local toolchain_file="$1"

  python3 - "${toolchain_file}" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

channel = data["toolchain"].get("channel")
if not channel:
    raise SystemExit("missing toolchain.channel")
print(channel)
PY
}

sync_lockfile_if_needed() {
  local manifest_path="$1"
  local lockfile_path
  local toolchain_file
  local toolchain_channel
  local before_hash
  local after_hash

  lockfile_path="$(dirname "${manifest_path}")/Cargo.lock"
  [ -f "${lockfile_path}" ] || return 0
  toolchain_file="$(dirname "${manifest_path}")/rust-toolchain.toml"

  before_hash="$(sha256sum "${lockfile_path}" | awk '{print $1}')"
  if [ -f "${toolchain_file}" ]; then
    toolchain_channel="$(read_toolchain_channel "${toolchain_file}")"
    if ! cargo +"${toolchain_channel}" metadata \
      --manifest-path "${manifest_path}" \
      --format-version 1 \
      --offline \
      >/dev/null 2>&1; then
      printf 'INFO: offline Cargo.lock refresh missed cached dependencies; retrying online\n' >&2
      cargo +"${toolchain_channel}" metadata \
        --manifest-path "${manifest_path}" \
        --format-version 1 \
        >/dev/null
    fi
  else
    if ! cargo metadata \
      --manifest-path "${manifest_path}" \
      --format-version 1 \
      --offline \
      >/dev/null 2>&1; then
      printf 'INFO: offline Cargo.lock refresh missed cached dependencies; retrying online\n' >&2
      cargo metadata \
        --manifest-path "${manifest_path}" \
        --format-version 1 \
        >/dev/null
    fi
  fi
  after_hash="$(sha256sum "${lockfile_path}" | awk '{print $1}')"

  if [ "${before_hash}" != "${after_hash}" ]; then
    printf 'INFO: refreshed Cargo.lock in reconciled worktree\n' >&2
  fi
}

WORKTREE_DIR="$(create_release_scratch_dir "reconcile-run")"
cleanup() {
  local rc=$?
  if [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR}" ]; then
    git -C "${REPO_ROOT}" -c color.ui=never worktree remove "${WORKTREE_DIR}" --force >/dev/null 2>&1 || true
    rm -rf -- "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}
trap cleanup EXIT INT TERM

"${REPO_ROOT}/scripts/release/reconcile.sh" \
  --base-ref HEAD \
  --keep-worktree \
  --skip-generated-artifacts \
  --worktree-dir "${WORKTREE_DIR}" >/dev/null

cd -- "${WORKTREE_DIR}"
if [ -f codex-rs/Cargo.toml ]; then
  sync_lockfile_if_needed "${WORKTREE_DIR}/codex-rs/Cargo.toml"
fi
"$@"
