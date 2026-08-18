#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

LC_ALL=C
TZ=UTC
export LC_ALL TZ

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${SCRIPT_DIR}/common.sh"

require_cmd bash
require_cmd dpkg-parsechangelog
require_cmd python3
require_cmd git

cd -- "${REPO_ROOT}"

verify_release_patch_target_hygiene
verify_release_patch_memory_exclusion

for script_path in \
  scripts/release/common.sh \
  scripts/release/reconcile.sh \
  scripts/release/check_release_patches.sh \
  scripts/release/build-codex.sh \
  scripts/release/run_in_reconciled_worktree.sh \
  scripts/release/refresh_release_patch_3way.sh
do
  bash -n "${script_path}"
done

python3 -m py_compile \
  patches/release/verify_release_bin_contract.py \
  patches/release/verify_rust_release_source_contract.py \
  scripts/release/codex_version.py \
  scripts/release/release_contract.py \
  scripts/release/test_release_tools.py
python3 scripts/release/test_release_tools.py
python3 scripts/release/codex_version.py validate 0.147.0

dpkg-parsechangelog -SSource >/dev/null
dpkg-parsechangelog -SVersion >/dev/null

git diff --check
