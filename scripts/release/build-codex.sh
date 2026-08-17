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

DEFAULT_BUILD_ROOT="/pool/build/codex"
DEFAULT_CACHE_ROOT="/pool/cache/codex"
DEFAULT_TARGET="x86_64-unknown-linux-gnu"
DEFAULT_RUST_CHANNEL="nightly"
DEFAULT_TARGET_CPU="skylake"
DEFAULT_BAZEL_TARGET="//bazel/release:release-binaries"
DEFAULT_BUILD_JOBS="1"
RELEASE_ARCHIVE_NAME="codex.tar.gz"

usage() {
  cat <<'EOF'
Usage: scripts/release/build-codex.sh [options]

Build the protected release overlay in a disposable checkout rooted in
/pool/cache/codex, then publish the resulting Linux GNU binaries and archive
under /pool/build/codex.

Options:
  --base-ref REF       Git ref to checkout before applying release patches.
                       Defaults to the first available ref in:
                       origin/gitlab/mcr/main, gitlab/mcr/main, mcr/main.
  --build-root DIR     Final artifact root. Default: /pool/build/codex
  --cache-root DIR     Build cache and temporary checkout root.
                       Default: /pool/cache/codex
  --target TRIPLE      Rust target triple. Default: x86_64-unknown-linux-gnu
  --toolchain CHANNEL  Rust toolchain channel to use. Defaults to the active
                       global Mise nightly toolchain.
  --target-cpu CPU     Set -C target-cpu for release builds. Default: skylake
  --bazel-target LABEL Build this Bazel target before packaging. Defaults to
                       //bazel/release:release-binaries, which covers every
                       binary in the release manifest.
  --rustc-threads N    When using nightly, add -Z threads=N to rustc.
  --jobs N             Forward --jobs N to cargo build.
  -h, --help           Show this help text.

This script is intended for manual x86_64 GNU/Linux release builds only.
It does not compile from the active workspace tree. Instead it:
  1) validates the current release patch stack against the chosen base ref
  2) creates a detached temporary checkout
  3) copies the local release overlay into that checkout
  4) applies the patch series there
  5) regenerates and validates config.schema.json with `just`
  6) builds every release binary with Bazel using its persistent disk cache
  7) builds the canonical RELEASE_BINS set with Cargo, sccache, and target-cpu tuning
  8) writes a tarball containing every release binary and config.schema.json
  9) verifies the tarball and immediately deletes only the temporary checkout

The Cargo archive payload is separate from Bazel outputs. Cargo and Bazel caches
remain under the configured cache root for subsequent builds.
EOF
}

require_repo_root() {
  require_release_overlay_root
  [ -f "${REPO_ROOT}/codex-rs/Cargo.toml" ] || die "missing ${REPO_ROOT}/codex-rs/Cargo.toml"
}

require_linux_x86_64() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  [ "${os}" = "Linux" ] || die "unsupported host OS: ${os} (expected Linux)"
  case "${arch}" in
    x86_64|amd64) ;;
    *)
      die "unsupported host architecture: ${arch} (expected x86_64)"
      ;;
  esac
}

require_absolute_path() {
  local value="$1"
  case "${value}" in
    /*) ;;
    *)
      die "expected an absolute path, got: ${value}"
      ;;
  esac
}

default_rustc_threads() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi
  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
    return 0
  fi
  printf '1\n'
}

validate_target_cpu() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "--target-cpu contains unsupported characters: ${value}"
}

append_cargo_encoded_rustflags() {
  local sep=$'\x1f'
  local combined="${CARGO_ENCODED_RUSTFLAGS:-}"
  local flag

  for flag in "$@"; do
    if [ -n "${combined}" ]; then
      combined+="${sep}"
    fi
    combined+="${flag}"
  done

  export CARGO_ENCODED_RUSTFLAGS="${combined}"
}

remove_cargo_target_cpu_rustflags() {
  local sep=$'\x1f'
  local -a inherited=()
  local -a retained=()
  local flag next_flag
  local index=0

  if [ -n "${CARGO_ENCODED_RUSTFLAGS:-}" ]; then
    IFS="${sep}" read -r -a inherited <<< "${CARGO_ENCODED_RUSTFLAGS}"
  fi

  while [ "${index}" -lt "${#inherited[@]}" ]; do
    flag="${inherited[$index]}"
    next_flag="${inherited[$((index + 1))]:-}"
    case "${flag}" in
      -Ctarget-cpu=*|--codegen=target-cpu=*)
        index=$((index + 1))
        continue
        ;;
      -C|--codegen)
        if [[ "${next_flag}" == target-cpu=* ]]; then
          index=$((index + 2))
          continue
        fi
        ;;
    esac
    retained+=("${flag}")
    index=$((index + 1))
  done

  CARGO_ENCODED_RUSTFLAGS=""
  if [ "${#retained[@]}" -gt 0 ]; then
    CARGO_ENCODED_RUSTFLAGS="$(IFS="${sep}"; printf '%s' "${retained[*]}")"
  fi
  export CARGO_ENCODED_RUSTFLAGS
}

verify_cargo_target_cpu() {
  local target_cpu="$1"

  python3 - "${target_cpu}" "${CARGO_ENCODED_RUSTFLAGS:-}" <<'PY'
import sys

target_cpu, encoded = sys.argv[1:]
flags = encoded.split("\x1f") if encoded else []
matches = []
index = 0
while index < len(flags):
    flag = flags[index]
    if flag.startswith("-Ctarget-cpu="):
        matches.append(flag.removeprefix("-Ctarget-cpu="))
    elif flag.startswith("--codegen=target-cpu="):
        matches.append(flag.removeprefix("--codegen=target-cpu="))
    elif flag in {"-C", "--codegen"} and index + 1 < len(flags):
        next_flag = flags[index + 1]
        if next_flag.startswith("target-cpu="):
            matches.append(next_flag.removeprefix("target-cpu="))
            index += 1
    index += 1

if matches != [target_cpu]:
    raise SystemExit(
        "CARGO_ENCODED_RUSTFLAGS must contain exactly one "
        f"target-cpu setting ({target_cpu!r}); found {matches!r}"
    )
PY
}

configure_build_rustflags() {
  local toolchain="$1"
  local target_cpu="$2"
  local rustc_threads="$3"
  local -a rustflags=()

  remove_cargo_target_cpu_rustflags
  if [ -n "${target_cpu}" ]; then
    rustflags+=("-Ctarget-cpu=${target_cpu}")
  fi
  if [[ "${toolchain}" == nightly* ]] && [ -n "${rustc_threads}" ]; then
    rustflags+=("-Zthreads=${rustc_threads}")
  fi
  if [ "${#rustflags[@]}" -eq 0 ]; then
    return 0
  fi

  append_cargo_encoded_rustflags "${rustflags[@]}"
  verify_cargo_target_cpu "${target_cpu}"
  info "Using encoded rustflags: ${rustflags[*]}"
}

detect_host_cpu_model() {
  python3 - <<'PY'
from pathlib import Path

cpuinfo = Path("/proc/cpuinfo")
if not cpuinfo.is_file():
    raise SystemExit(0)

for line in cpuinfo.read_text(encoding="utf-8", errors="ignore").splitlines():
    if line.lower().startswith("model name"):
        _, value = line.split(":", 1)
        print(value.strip())
        raise SystemExit(0)
PY
}

detect_host_cpu_flags() {
  python3 - <<'PY'
from pathlib import Path

cpuinfo = Path("/proc/cpuinfo")
if not cpuinfo.is_file():
    raise SystemExit(0)

for line in cpuinfo.read_text(encoding="utf-8", errors="ignore").splitlines():
    if line.startswith("flags") or line.startswith("Features"):
        _, value = line.split(":", 1)
        print(" ".join(value.split()))
        raise SystemExit(0)
PY
}

run_with_mise_rust() {
  local toolchain="$1"
  shift

  run mise exec "rust@${toolchain}" -- "$@"
}

detect_rust_target_features() {
  local toolchain="$1"
  local target="$2"
  local target_cpu="$3"

  run_with_mise_rust "${toolchain}" rustc \
    -C "target-cpu=${target_cpu}" \
    --target "${target}" \
    --print cfg \
    2>/dev/null \
    | python3 -c '
import sys

features = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('target_feature="'):
        continue
    features.append(line.split('"', 2)[1])

if features:
    print(",".join(sorted(features)))
'
}

ensure_rust_toolchain() {
  local toolchain="$1"
  local target="$2"

  info "Validating global Mise Rust toolchain ${toolchain}"
  run_with_mise_rust "${toolchain}" rustc --version
  run_with_mise_rust "${toolchain}" cargo --version
  run_with_mise_rust "${toolchain}" rustc --target "${target}" --print cfg >/dev/null

  export RUST_TOOLCHAIN="${toolchain}"
  export CARGO_BUILD_TARGET="${target}"

  info "Using Mise Rust toolchain ${toolchain}"
}

ensure_linux_release_build_prerequisites() {
  require_cmd pkg-config
  if ! pkg-config --exists libcap; then
    die "missing libcap development files required by codex-bwrap; install libcap-dev so 'pkg-config --exists libcap' succeeds"
  fi
}

ensure_sccache() {
  local sccache_bin

  require_cmd sccache
  sccache_bin="$(command -v sccache)"
  case "${RUSTC_WRAPPER:-}" in
    ""|sccache|"${sccache_bin}") ;;
    *) die "RUSTC_WRAPPER must use sccache for release builds, found: ${RUSTC_WRAPPER}" ;;
  esac
  case "${CARGO_BUILD_RUSTC_WRAPPER:-}" in
    ""|sccache|"${sccache_bin}") ;;
    *) die "CARGO_BUILD_RUSTC_WRAPPER must use sccache for release builds, found: ${CARGO_BUILD_RUSTC_WRAPPER}" ;;
  esac

  SCCACHE_DIR="${SCCACHE_DIR:-${CACHE_ROOT}/sccache}"
  require_absolute_path "${SCCACHE_DIR}"
  case "${SCCACHE_DIR}" in
    /tmp|/tmp/*)
      die "sccache directory must be disk-backed, not ${SCCACHE_DIR}"
      ;;
  esac

  run mkdir -p -- "${SCCACHE_DIR}"
  export RUSTC_WRAPPER="${sccache_bin}"
  export CARGO_BUILD_RUSTC_WRAPPER="${sccache_bin}"
  export SCCACHE_DIR
  if ! "${sccache_bin}" --start-server >/dev/null 2>&1; then
    "${sccache_bin}" --show-stats >/dev/null 2>&1 \
      || die "failed to start or reach the sccache server"
  fi
  info "Using persistent sccache directory ${SCCACHE_DIR}"
}

read_bazel_version() {
  local version

  [ -f "${REPO_ROOT}/.bazelversion" ] || die "missing ${REPO_ROOT}/.bazelversion"
  version="$(tr -d '\r\n' < "${REPO_ROOT}/.bazelversion")"
  [[ "${version}" =~ ^[0-9]+(\.[0-9]+){2}$ ]] \
    || die "unsupported Bazel version in .bazelversion: ${version}"
  printf '%s\n' "${version}"
}

ensure_bazel() {
  local asset_name download_url checksum_url expected_sha actual_sha
  local download_dir partial_binary partial_checksum

  BAZEL_VERSION="$(read_bazel_version)"
  BAZEL_CACHE_ROOT="${CACHE_ROOT}/bazel"
  BAZEL_BIN="${BAZEL_CACHE_ROOT}/toolchain/${BAZEL_VERSION}/bazel"
  require_absolute_path "${BAZEL_CACHE_ROOT}"

  if [ ! -x "${BAZEL_BIN}" ]; then
    require_cmd curl
    download_dir="$(dirname -- "${BAZEL_BIN}")"
    run mkdir -p -- "${download_dir}"
    partial_binary="$(mktemp "${download_dir}/.bazel-${BAZEL_VERSION}.XXXXXX")"
    partial_checksum="$(mktemp "${download_dir}/.bazel-${BAZEL_VERSION}.sha256.XXXXXX")"
    asset_name="bazel-${BAZEL_VERSION}-linux-x86_64"
    download_url="https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/${asset_name}"
    checksum_url="${download_url}.sha256"

    info "Downloading Bazel ${BAZEL_VERSION} into persistent release cache"
    run curl --fail --location --proto '=https' --tlsv1.2 \
      --retry 2 --retry-delay 1 \
      --output "${partial_binary}" \
      "${download_url}"
    run curl --fail --location --proto '=https' --tlsv1.2 \
      --retry 2 --retry-delay 1 \
      --output "${partial_checksum}" \
      "${checksum_url}"
    expected_sha="$(awk 'NF { print $1; exit }' "${partial_checksum}")"
    [[ "${expected_sha}" =~ ^[0-9a-fA-F]{64}$ ]] \
      || die "invalid Bazel checksum file downloaded from ${checksum_url}"
    actual_sha="$(sha256sum -- "${partial_binary}" | awk '{print $1}')"
    [ "${actual_sha}" = "${expected_sha}" ] \
      || die "Bazel download checksum mismatch for ${download_url}"
    run chmod 0755 -- "${partial_binary}"
    run mv -- "${partial_binary}" "${BAZEL_BIN}"
    rm -f -- "${partial_checksum}"
  fi

  [ -x "${BAZEL_BIN}" ] || die "missing executable Bazel binary: ${BAZEL_BIN}"
  [ "$("${BAZEL_BIN}" --version)" = "bazel ${BAZEL_VERSION}" ] \
    || die "Bazel binary does not match .bazelversion (${BAZEL_VERSION}): ${BAZEL_BIN}"
  export BAZEL_VERSION BAZEL_CACHE_ROOT BAZEL_BIN
  info "Using Bazel ${BAZEL_VERSION} with persistent cache ${BAZEL_CACHE_ROOT}"
}

build_bazel_release_target() {
  local checkout_dir="$1"
  local target_cpu="$2"

  info "Building Bazel release target ${BAZEL_TARGET}"
  (
    cd -- "${checkout_dir}"
    run "${BAZEL_BIN}" \
      "--output_user_root=${BAZEL_CACHE_ROOT}/output-user-root" \
      build \
      "--disk_cache=${BAZEL_CACHE_ROOT}/disk-cache" \
      "--repository_cache=${BAZEL_CACHE_ROOT}/repository-cache" \
      "--repo_contents_cache=${BAZEL_CACHE_ROOT}/repository-contents-cache" \
      "--jobs=${CARGO_JOBS}" \
      "--@rules_rust//rust/settings:extra_rustc_flag=-Ctarget-cpu=${target_cpu}" \
      "${BAZEL_TARGET}"
  )
}

read_release_bins() {
  local repo_root="$1"
  local release_bins_path=""

  if [ -n "${RELEASE_BINS_FILE:-}" ]; then
    release_bins_path="${RELEASE_BINS_FILE}"
  elif [ -n "${GL_RELEASE_BIN_LIST_FILE:-}" ]; then
    release_bins_path="${GL_RELEASE_BIN_LIST_FILE}"
  elif [ -f "${repo_root}/scripts/release/release-bins.txt" ]; then
    release_bins_path="${repo_root}/scripts/release/release-bins.txt"
  fi

  if [ -n "${release_bins_path}" ]; then
    case "${release_bins_path}" in
      /*) ;;
      *) release_bins_path="${repo_root}/${release_bins_path}" ;;
    esac
    [ -f "${release_bins_path}" ] || die "missing release bin manifest: ${release_bins_path}"

    mapfile -t RELEASE_BINS < <(
      python3 - "${release_bins_path}" <<'PY'
from pathlib import Path
import sys

for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.split("#", 1)[0].strip()
    if line:
        print(line)
PY
    )
    [ "${#RELEASE_BINS[@]}" -gt 0 ] || die "release bin manifest is empty: ${release_bins_path}"
    return 0
  fi

  mapfile -t RELEASE_BINS < <(
    python3 - "${repo_root}/.gitlab-ci.yml" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
pattern = re.compile(r'^(?P<indent>[ \t]*)RELEASE_BINS:\s*\|\s*$')

for index, line in enumerate(lines):
    match = pattern.match(line)
    if not match:
        continue
    indent = len(match.group("indent"))
    block = []
    for candidate in lines[index + 1 :]:
        if not candidate.strip():
            continue
        current_indent = len(candidate) - len(candidate.lstrip(" "))
        if current_indent <= indent:
            break
        block.append(candidate.strip())
    for item in block:
        print(item)
    break
else:
    raise SystemExit("missing RELEASE_BINS block in .gitlab-ci.yml")
PY
  )

  [ "${#RELEASE_BINS[@]}" -gt 0 ] || die "RELEASE_BINS is empty"
}

read_workspace_version() {
  local cargo_toml="$1"

  python3 - "${cargo_toml}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
in_workspace_package = False
for line in path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_workspace_package = stripped == "[workspace.package]"
        continue
    if in_workspace_package and stripped.startswith("version"):
        match = re.match(r'version\s*=\s*"([^"]+)"', stripped)
        if not match:
            raise SystemExit(f"unsupported version line: {line!r}")
        print(match.group(1))
        raise SystemExit(0)

raise SystemExit("workspace.package version not found")
PY
}

sync_lockfile_if_needed() {
  local manifest_path="$1"
  local toolchain="$2"
  local lockfile_path
  local before_hash after_hash

  lockfile_path="$(dirname "${manifest_path}")/Cargo.lock"
  before_hash="$(sha256sum "${lockfile_path}" | awk '{print $1}')"

  info "Refreshing Cargo.lock in the disposable checkout if the overlay changed dependency edges"
  run_with_mise_rust "${toolchain}" cargo metadata \
    --manifest-path "${manifest_path}" \
    --format-version 1 \
    >/dev/null

  after_hash="$(sha256sum "${lockfile_path}" | awk '{print $1}')"
  if [ "${before_hash}" != "${after_hash}" ]; then
    warn "Cargo.lock changed in the disposable checkout after overlay application"
  fi
}

write_build_manifest() {
  local output_dir="$1"
  local bins_file="$2"
  local config_schema_path="$3"

  python3 - "${output_dir}/build-manifest.json" "${bins_file}" "${config_schema_path}" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
bins_path = Path(sys.argv[2])
config_schema_path = Path(sys.argv[3])
manifest = {
    "build_root": os.environ["BUILD_ROOT"],
    "cache_root": os.environ["CACHE_ROOT"],
    "version": os.environ["WORKSPACE_VERSION"],
    "target": os.environ["RUST_TARGET"],
    "base_ref": os.environ["BASE_REF"],
    "base_commit": os.environ["BASE_COMMIT"],
    "overlay_commit": os.environ["OVERLAY_COMMIT"],
    "rust_toolchain": os.environ["RUST_TOOLCHAIN"],
    "toolchain_manager": "mise",
    "target_cpu": os.environ.get("RUST_TARGET_CPU"),
    "rustc_threads": os.environ.get("RUSTC_THREADS"),
    "rust_target_features": os.environ.get("RUST_TARGET_FEATURES"),
    "host_cpu_model": os.environ.get("HOST_CPU_MODEL"),
    "host_cpu_flags": os.environ.get("HOST_CPU_FLAGS"),
    "cargo_encoded_rustflags": os.environ.get("CARGO_ENCODED_RUSTFLAGS"),
    "release_bins": bins_path.read_text(encoding="utf-8").splitlines(),
    "config_schema_sha256": hashlib.sha256(config_schema_path.read_bytes()).hexdigest(),
    "archive": os.environ["RELEASE_ARCHIVE_NAME"],
    "bazel_target": os.environ["BAZEL_TARGET"],
    "bazel_version": os.environ["BAZEL_VERSION"],
    "bazel_cache_root": os.environ["BAZEL_CACHE_ROOT"],
    "bazel_rustc_flags": [
        f"-Ctarget-cpu={os.environ['RUST_TARGET_CPU']}",
    ],
    "sccache_dir": os.environ["SCCACHE_DIR"],
}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
}

verify_release_archive() {
  local archive_path="$1"
  shift

  python3 - "${archive_path}" "$@" <<'PY'
import hashlib
import sys
import tarfile
from pathlib import PurePosixPath


archive_path = sys.argv[1]
bins = sys.argv[2:]
expected_files = {
    "config.schema.json",
    "SHA256SUMS",
    "build-manifest.json",
    *(f"bin/{binary}" for binary in bins),
}

with tarfile.open(archive_path, mode="r:gz") as archive:
    members = archive.getmembers()
    member_by_name = {}
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe member path in release archive: {member.name!r}")
        if member.name in member_by_name:
            raise SystemExit(f"duplicate member in release archive: {member.name!r}")
        member_by_name[member.name] = member

    actual_files = {member.name for member in members if member.isfile()}
    if actual_files != expected_files:
        missing = sorted(expected_files - actual_files)
        unexpected = sorted(actual_files - expected_files)
        raise SystemExit(
            "release archive file set mismatch: "
            f"missing={missing!r} unexpected={unexpected!r}"
        )

    allowed_directories = {"bin"}
    actual_directories = {member.name.rstrip("/") for member in members if member.isdir()}
    if actual_directories - allowed_directories:
        raise SystemExit(
            "release archive has unexpected directories: "
            f"{sorted(actual_directories - allowed_directories)!r}"
        )

    checksum_member = archive.extractfile("SHA256SUMS")
    if checksum_member is None:
        raise SystemExit("release archive is missing SHA256SUMS")
    checksum_lines = checksum_member.read().decode("utf-8").splitlines()
    expected_checksums = {"config.schema.json", *(f"bin/{binary}" for binary in bins)}
    checksums = {}
    for line in checksum_lines:
        digest, separator, name = line.partition("  ")
        if not separator or len(digest) != 64 or not name:
            raise SystemExit(f"invalid SHA256SUMS entry: {line!r}")
        if name in checksums:
            raise SystemExit(f"duplicate SHA256SUMS entry: {name!r}")
        checksums[name] = digest
    if set(checksums) != expected_checksums:
        raise SystemExit(
            "SHA256SUMS file set mismatch: "
            f"expected={sorted(expected_checksums)!r} actual={sorted(checksums)!r}"
        )

    for name, expected_digest in checksums.items():
        payload = archive.extractfile(name)
        if payload is None:
            raise SystemExit(f"SHA256SUMS references missing archive member: {name!r}")
        actual_digest = hashlib.sha256(payload.read()).hexdigest()
        if actual_digest != expected_digest:
            raise SystemExit(f"SHA256 mismatch for archive member: {name!r}")

print(f"ok: verified release archive with {len(bins)} binaries")
PY
}

BUILD_ROOT="${DEFAULT_BUILD_ROOT}"
CACHE_ROOT="${DEFAULT_CACHE_ROOT}"
RUST_TARGET="${DEFAULT_TARGET}"
RUST_CHANNEL="${RELEASE_RUST_TOOLCHAIN:-${DEFAULT_RUST_CHANNEL}}"
RUST_TARGET_CPU="${DEFAULT_TARGET_CPU}"
BAZEL_TARGET="${DEFAULT_BAZEL_TARGET}"
RUSTC_THREADS=""
BASE_REF=""
CARGO_JOBS="${DEFAULT_BUILD_JOBS}"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref)
      [ $# -ge 2 ] || die "--base-ref requires a value"
      BASE_REF="$2"
      shift 2
      ;;
    --build-root)
      [ $# -ge 2 ] || die "--build-root requires a value"
      BUILD_ROOT="$2"
      shift 2
      ;;
    --cache-root)
      [ $# -ge 2 ] || die "--cache-root requires a value"
      CACHE_ROOT="$2"
      shift 2
      ;;
    --target)
      [ $# -ge 2 ] || die "--target requires a value"
      RUST_TARGET="$2"
      shift 2
      ;;
    --toolchain)
      [ $# -ge 2 ] || die "--toolchain requires a value"
      RUST_CHANNEL="$2"
      shift 2
      ;;
    --target-cpu)
      [ $# -ge 2 ] || die "--target-cpu requires a value"
      RUST_TARGET_CPU="$2"
      shift 2
      ;;
    --bazel-target)
      [ $# -ge 2 ] || die "--bazel-target requires a value"
      BAZEL_TARGET="$2"
      shift 2
      ;;
    --rustc-threads)
      [ $# -ge 2 ] || die "--rustc-threads requires a value"
      RUSTC_THREADS="$2"
      shift 2
      ;;
    --jobs)
      [ $# -ge 2 ] || die "--jobs requires a value"
      CARGO_JOBS="$2"
      shift 2
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
require_cmd mise
require_cmd python3
require_cmd sha256sum
require_cmd tar
require_repo_root
require_linux_x86_64
require_absolute_path "${BUILD_ROOT}"
require_absolute_path "${CACHE_ROOT}"
case "${BUILD_ROOT}" in
  /tmp|/tmp/*)
    die "release artifact root must be disk-backed, not ${BUILD_ROOT}"
    ;;
esac
case "${CACHE_ROOT}" in
  /tmp|/tmp/*)
    die "release cache root must be disk-backed, not ${CACHE_ROOT}"
    ;;
esac

BUILD_CARGO_HOME="${CARGO_HOME:-${CACHE_ROOT}/cargo-home}"
require_absolute_path "${BUILD_CARGO_HOME}"

if [ -z "${BASE_REF}" ]; then
  BASE_REF="$(resolve_default_base_ref)" || die "failed to resolve a default base ref"
fi
git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null \
  || die "missing git ref: ${BASE_REF}"

case "${RUST_TARGET}" in
  x86_64-unknown-linux-gnu) ;;
  *)
    die "unsupported target '${RUST_TARGET}'; this script only supports x86_64-unknown-linux-gnu"
    ;;
esac

if [ -n "${CARGO_JOBS}" ] && ! [[ "${CARGO_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  die "--jobs must be a positive integer"
fi
validate_target_cpu "${RUST_TARGET_CPU}"
if [ -n "${BAZEL_TARGET}" ]; then
  case "${BAZEL_TARGET}" in
    //*) ;;
    *) die "--bazel-target must be an absolute Bazel label: ${BAZEL_TARGET}" ;;
  esac
fi
if [ -n "${RUSTC_THREADS}" ] && ! [[ "${RUSTC_THREADS}" =~ ^[1-9][0-9]*$ ]]; then
  die "--rustc-threads must be a positive integer"
fi

export BUILD_ROOT CACHE_ROOT BASE_REF RUST_TARGET RELEASE_ARCHIVE_NAME BAZEL_TARGET
export RUST_TARGET_CPU

run mkdir -p -- "${BUILD_ROOT}" "${CACHE_ROOT}" \
  "${BUILD_CARGO_HOME}" "${CACHE_ROOT}/target"

export CARGO_HOME="${BUILD_CARGO_HOME}"
export CARGO_TARGET_DIR="${CACHE_ROOT}/target"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export RELEASE_CACHE_ROOT="${CACHE_ROOT}"
unset RUSTUP_TOOLCHAIN

TOOLCHAIN_FILE="${REPO_ROOT}/codex-rs/rust-toolchain.toml"
[ -f "${TOOLCHAIN_FILE}" ] || die "missing ${TOOLCHAIN_FILE}"
if [ -z "${RUSTC_THREADS}" ]; then
  RUSTC_THREADS="$(default_rustc_threads)"
fi
HOST_CPU_MODEL="$(detect_host_cpu_model 2>/dev/null || true)"
HOST_CPU_FLAGS="$(detect_host_cpu_flags 2>/dev/null || true)"
RUST_TARGET_FEATURES=""
export RUST_CHANNEL RUSTC_THREADS HOST_CPU_MODEL HOST_CPU_FLAGS RUST_TARGET_FEATURES
ensure_rust_toolchain "${RUST_CHANNEL}" "${RUST_TARGET}"
ensure_linux_release_build_prerequisites
ensure_sccache
ensure_bazel
RUST_TARGET_FEATURES="$(
  detect_rust_target_features "${RUST_CHANNEL}" "${RUST_TARGET}" "${RUST_TARGET_CPU}" 2>/dev/null || true
)"
export RUST_TARGET_FEATURES
configure_build_rustflags "${RUST_CHANNEL}" "${RUST_TARGET_CPU}" "${RUSTC_THREADS}"
if [ -n "${HOST_CPU_MODEL}" ]; then
  info "Detected host CPU model: ${HOST_CPU_MODEL}"
fi
if [ -n "${RUST_TARGET_FEATURES}" ]; then
  info "Detected rustc target features: ${RUST_TARGET_FEATURES}"
fi

CHECKOUT_DIR="$(mktemp -d "${CACHE_ROOT}/checkout.XXXXXX")"
cleanup() {
  local rc=$?
  if [ -n "${CHECKOUT_DIR:-}" ] && [ -d "${CHECKOUT_DIR}" ]; then
    git -C "${REPO_ROOT}" -c color.ui=never worktree remove "${CHECKOUT_DIR}" --force >/dev/null 2>&1 || true
    rm -rf -- "${CHECKOUT_DIR}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}
trap cleanup EXIT INT TERM

remove_checkout() {
  [ -n "${CHECKOUT_DIR:-}" ] || return 0
  [ -d "${CHECKOUT_DIR}" ] || {
    CHECKOUT_DIR=""
    return 0
  }

  info "Removing temporary release checkout ${CHECKOUT_DIR}"
  run git -C "${REPO_ROOT}" -c color.ui=never worktree remove "${CHECKOUT_DIR}" --force
  [ ! -e "${CHECKOUT_DIR}" ] || die "temporary release checkout was not removed: ${CHECKOUT_DIR}"
  CHECKOUT_DIR=""
}

verify_release_patch_target_hygiene
verify_release_patch_memory_exclusion

info "Reconciling release overlay into ${CHECKOUT_DIR}"
run_with_mise_rust "${RUST_CHANNEL}" "${REPO_ROOT}/scripts/release/reconcile.sh" \
  --base-ref "${BASE_REF}" \
  --worktree-dir "${CHECKOUT_DIR}" \
  --keep-worktree

CONFIG_SCHEMA_PATH="${CHECKOUT_DIR}/codex-rs/core/config.schema.json"
[ -f "${CONFIG_SCHEMA_PATH}" ] || die "missing generated config schema: ${CONFIG_SCHEMA_PATH}"
info "Validating generated config schema after reconciliation"
run python3 -m json.tool "${CONFIG_SCHEMA_PATH}" >/dev/null

info "Validating migration numeric versions after reconciliation"
run python3 \
  "${CHECKOUT_DIR}/${RELEASE_VERIFY_DIR}/verify_unique_migration_versions.py" \
  --migrations-dir "${CHECKOUT_DIR}/codex-rs/state/migrations"

run_release_verifier_if_present \
  "${CHECKOUT_DIR}" \
  "verify_prompt_inventory_contract.py" \
  "Validating instruction inventory after patch application"

info "Validating release binary contract after reconciliation"
run python3 "${CHECKOUT_DIR}/${RELEASE_VERIFY_DIR}/verify_release_bin_contract.py" --repo-root "${CHECKOUT_DIR}"

WORKSPACE_VERSION="$(read_workspace_version "${CHECKOUT_DIR}/codex-rs/Cargo.toml")"
BASE_COMMIT="$(git -C "${CHECKOUT_DIR}" rev-parse HEAD)"
OVERLAY_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

read_release_bins "${CHECKOUT_DIR}"

BUILD_ID="${WORKSPACE_VERSION}-${RUST_TARGET}-$(printf '%s' "${BASE_COMMIT}" | cut -c1-12)-$(printf '%s' "${OVERLAY_COMMIT}" | cut -c1-12)"
OUTPUT_DIR="${BUILD_ROOT}/${BUILD_ID}"
STAGING_DIR="${BUILD_ROOT}/.staging-${BUILD_ID}-$$"
RELEASE_BIN_LIST_FILE="${CACHE_ROOT}/release-bins.${BUILD_ID}.txt"

printf '%s\n' "${RELEASE_BINS[@]}" > "${RELEASE_BIN_LIST_FILE}"

sync_lockfile_if_needed "${CHECKOUT_DIR}/codex-rs/Cargo.toml" "${RUST_CHANNEL}"

build_bazel_release_target "${CHECKOUT_DIR}" "${RUST_TARGET_CPU}"

# The archive payload is emitted by Cargo below; its compiler flags include
# -C target-cpu=skylake by default.
info "Fetching locked Rust dependencies"
run_with_mise_rust "${RUST_CHANNEL}" cargo fetch \
  --locked \
  --target "${RUST_TARGET}" \
  --manifest-path "${CHECKOUT_DIR}/codex-rs/Cargo.toml"

BUILD_CMD=(
  build
  --manifest-path "${CHECKOUT_DIR}/codex-rs/Cargo.toml"
  --workspace
  --release
  --locked
  --target "${RUST_TARGET}"
)
if [ -n "${CARGO_JOBS}" ]; then
  BUILD_CMD+=(--jobs "${CARGO_JOBS}")
fi
for bin in "${RELEASE_BINS[@]}"; do
  BUILD_CMD+=(--bin "${bin}")
done

info "Building ${#RELEASE_BINS[@]} release binary/binaries for ${RUST_TARGET}"
run_with_mise_rust "${RUST_CHANNEL}" cargo "${BUILD_CMD[@]}"

rm -rf -- "${STAGING_DIR}"
run mkdir -p -- "${STAGING_DIR}/bin"

for bin in "${RELEASE_BINS[@]}"; do
  src="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/${bin}"
  [ -f "${src}" ] || die "missing built binary: ${src}"
  run install -m 0755 -- "${src}" "${STAGING_DIR}/bin/${bin}"
done

run install -m 0644 -- "${CONFIG_SCHEMA_PATH}" "${STAGING_DIR}/config.schema.json"

(
  cd -- "${STAGING_DIR}"
  run sha256sum -- "config.schema.json" "${RELEASE_BINS[@]/#/bin/}"
) > "${STAGING_DIR}/SHA256SUMS"

write_build_manifest \
  "${STAGING_DIR}" \
  "${RELEASE_BIN_LIST_FILE}" \
  "${STAGING_DIR}/config.schema.json"

run tar \
  -C "${STAGING_DIR}" \
  -czf "${STAGING_DIR}/${RELEASE_ARCHIVE_NAME}" \
  bin \
  config.schema.json \
  SHA256SUMS \
  build-manifest.json

info "Verifying release archive before disposing the temporary checkout"
verify_release_archive "${STAGING_DIR}/${RELEASE_ARCHIVE_NAME}" "${RELEASE_BINS[@]}"
remove_checkout

(
  cd -- "${STAGING_DIR}"
  run sha256sum -- "${RELEASE_ARCHIVE_NAME}"
) > "${STAGING_DIR}/${RELEASE_ARCHIVE_NAME}.sha256"

rm -rf -- "${OUTPUT_DIR}"
run mv -- "${STAGING_DIR}" "${OUTPUT_DIR}"
ln -sfn -- "${BUILD_ID}" "${BUILD_ROOT}/latest"

info "Build completed successfully"
info "Published binaries: ${OUTPUT_DIR}/bin"
info "Release archive: ${OUTPUT_DIR}/${RELEASE_ARCHIVE_NAME}"
info "Release manifest: ${OUTPUT_DIR}/build-manifest.json"
