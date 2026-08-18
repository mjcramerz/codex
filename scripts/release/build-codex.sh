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
DEFAULT_CARGO_LTO="off"
DEFAULT_RUSTC_THREADS="1"
DEFAULT_COMP="both"
BAZEL_COMPILATION_MODE="opt"
RELEASE_ARCHIVE_NAME="codex.tar.gz"

usage() {
  cat <<'EOF'
Usage: scripts/release/build-codex.sh [options]

Build the protected release overlay in a disposable checkout rooted in
/pool/cache/codex, then publish the resulting Linux GNU binaries and archive
under /pool/build/codex.

Options:
  --comp MODE           Compilation backend: both, bazel, or cargo.
                        Default: both
  --base-ref REF       Git ref to checkout before applying release patches.
                       Defaults to the first available ref in:
                       origin/gitlab/mcr/main, gitlab/mcr/main, mcr/main.
  --build-root DIR     Final artifact root. Default: /pool/build/codex
  --cache-root DIR     Build cache and temporary checkout root.
                       Default: /pool/cache/codex
  --target TRIPLE      Rust target triple. Default: x86_64-unknown-linux-gnu
  --toolchain CHANNEL  Cargo-mode Rust toolchain channel. Defaults to the
                       active global Mise nightly toolchain.
  --target-cpu CPU     Set -C target-cpu for release builds. Default: skylake
  --version VERSION    Set codex-rs workspace.package.version in the disposable
                       checkout before schema generation or compilation.
  --bazel-target LABEL Bazel-mode release target. Defaults to
                       //bazel/release:release-binaries, which covers every
                       binary in the release manifest.
  --rustc-threads N    In Cargo modes, add -Z threads=N to nightly rustc.
                       Default: 1 to bound peak release-build memory.
  --jobs N             Limit jobs for each selected compilation backend.
                       Default: 1
  --cargo-jobs N       Limit Cargo jobs independently from Bazel jobs.
                       Defaults to --jobs when omitted.
  --cargo-lto MODE     Cargo release-profile LTO mode: off, false, thin,
                       fat, or true. Default: off to bound peak memory.
  -h, --help           Show this help text.

This script is intended for manual x86_64 GNU/Linux release builds only.
It does not compile from the active workspace tree. Instead it:
  1) validates the current release patch stack against the chosen base ref
  2) creates a detached temporary checkout
  3) copies the local release overlay into that checkout
  4) applies the patch series there
  5) applies an optional workspace package version override
  6) regenerates config.schema.json with the selected artifact backend
  7) builds every release binary with the selected backend(s)
  8) stages the Cargo outputs for `both`/`cargo`, or Bazel outputs for `bazel`
  9) writes a tarball containing every release binary and config.schema.json
 10) verifies the tarball and immediately deletes only the temporary checkout

`both` preserves the historical flow: Bazel validates the full optimized release
target and Cargo produces the archive payload. `bazel` and `cargo` initialize and
run only their selected compilation backend. Persistent backend caches remain
under the configured cache root for subsequent builds.
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

configure_cargo_rusty_v8_artifacts() {
  local checkout_dir="$1"
  local env_output
  local -a artifact_paths=()

  env_output="$(mktemp "${checkout_dir}/.rusty-v8-env.XXXXXX")"
  if ! PYTHONPATH="${checkout_dir}/scripts" python3 - \
    "${RUST_TARGET}" \
    "${CACHE_ROOT}/rusty-v8" \
    >"${env_output}" <<'PY'
import os
import sys
from pathlib import Path

from codex_package.targets import TARGET_SPECS
from codex_package.v8 import resolve_codex_v8_cargo_env

target, cache_root = sys.argv[1:]
try:
    spec = TARGET_SPECS[target]
except KeyError:
    raise SystemExit(f"unsupported rusty_v8 target: {target}")

try:
    cargo_env = resolve_codex_v8_cargo_env(
        spec,
        environ=os.environ,
        cache_root=Path(cache_root),
    )
except Exception as exc:
    raise SystemExit(f"failed to configure Codex-built rusty_v8 artifacts: {exc}")

for key in ("RUSTY_V8_ARCHIVE", "RUSTY_V8_SRC_BINDING_PATH"):
    if value := cargo_env.get(key):
        sys.stdout.buffer.write(os.fsencode(value))
        sys.stdout.buffer.write(b"\0")
PY
  then
    die "failed to resolve Codex-built rusty_v8 artifacts"
  fi

  mapfile -d '' -t artifact_paths < "${env_output}"
  rm -f -- "${env_output}"

  case "${#artifact_paths[@]}" in
    0)
      case "${V8_FROM_SOURCE:-}" in
        1|true|yes)
          info "Using the caller-requested rusty_v8 source build"
          ;;
        *)
          if [ -n "${RUSTY_V8_ARCHIVE:-}" ] \
            && [ -n "${RUSTY_V8_SRC_BINDING_PATH:-}" ]; then
            info "Using caller-provided rusty_v8 artifact overrides"
          else
            die "rusty_v8 artifact setup returned no archive or binding"
          fi
          ;;
      esac
      ;;
    2)
      RUSTY_V8_ARCHIVE="${artifact_paths[0]}"
      RUSTY_V8_SRC_BINDING_PATH="${artifact_paths[1]}"
      require_absolute_path "${RUSTY_V8_ARCHIVE}"
      require_absolute_path "${RUSTY_V8_SRC_BINDING_PATH}"
      [ -f "${RUSTY_V8_ARCHIVE}" ] \
        || die "missing checksum-verified rusty_v8 archive: ${RUSTY_V8_ARCHIVE}"
      [ -f "${RUSTY_V8_SRC_BINDING_PATH}" ] \
        || die "missing checksum-verified rusty_v8 binding: ${RUSTY_V8_SRC_BINDING_PATH}"
      export RUSTY_V8_ARCHIVE RUSTY_V8_SRC_BINDING_PATH
      info "Using checksum-verified Codex-built rusty_v8 artifacts for ${RUST_TARGET}"
      ;;
    *)
      die "rusty_v8 artifact setup returned ${#artifact_paths[@]} paths; expected zero or two"
      ;;
  esac
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
      "--compilation_mode=${BAZEL_COMPILATION_MODE}" \
      "--jobs=${BUILD_JOBS}" \
      "--@rules_rust//rust/settings:extra_rustc_flag=-Ctarget-cpu=${target_cpu}" \
      "${BAZEL_TARGET}"
  )
}

query_bazel_release_outputs() {
  local checkout_dir="$1"
  local target_cpu="$2"
  local outputs_file="$3"

  info "Resolving Bazel release outputs for ${BAZEL_TARGET}"
  (
    cd -- "${checkout_dir}"
    run "${BAZEL_BIN}" \
      "--output_user_root=${BAZEL_CACHE_ROOT}/output-user-root" \
      cquery \
      "--disk_cache=${BAZEL_CACHE_ROOT}/disk-cache" \
      "--repository_cache=${BAZEL_CACHE_ROOT}/repository-cache" \
      "--repo_contents_cache=${BAZEL_CACHE_ROOT}/repository-contents-cache" \
      "--compilation_mode=${BAZEL_COMPILATION_MODE}" \
      "--@rules_rust//rust/settings:extra_rustc_flag=-Ctarget-cpu=${target_cpu}" \
      "--output=files" \
      "${BAZEL_TARGET}"
  ) > "${outputs_file}"
}

bazel_info_value() {
  local checkout_dir="$1"
  local key="$2"

  (
    cd -- "${checkout_dir}"
    "${BAZEL_BIN}" \
      "--output_user_root=${BAZEL_CACHE_ROOT}/output-user-root" \
      info \
      "${key}"
  )
}

collect_bazel_release_outputs() {
  local checkout_dir="$1"
  local bins_file="$2"
  local target_cpu="$3"
  local raw_outputs_file="${CACHE_ROOT}/bazel-release-outputs.${BUILD_ID}.txt"
  local output_map_file="${CACHE_ROOT}/bazel-release-output-map.${BUILD_ID}.bin"
  local -a output_map=()
  local index bin_name output_path

  query_bazel_release_outputs "${checkout_dir}" "${target_cpu}" "${raw_outputs_file}"
  BAZEL_EXECUTION_ROOT="$(bazel_info_value "${checkout_dir}" execution_root)"
  BAZEL_OUTPUT_BASE="$(bazel_info_value "${checkout_dir}" output_base)"
  require_absolute_path "${BAZEL_EXECUTION_ROOT}"
  require_absolute_path "${BAZEL_OUTPUT_BASE}"

  run python3 \
    "${checkout_dir}/scripts/release/release_contract.py" \
    resolve-bazel-outputs \
    --execution-root "${BAZEL_EXECUTION_ROOT}" \
    --output-base "${BAZEL_OUTPUT_BASE}" \
    --outputs-file "${raw_outputs_file}" \
    --bins-file "${bins_file}" \
    --format nul > "${output_map_file}"

  mapfile -d '' -t output_map < "${output_map_file}"
  [ $(( ${#output_map[@]} % 2 )) -eq 0 ] \
    || die "invalid Bazel release output map"

  BAZEL_RELEASE_BIN_PATHS=()
  for ((index = 0; index < ${#output_map[@]}; index += 2)); do
    bin_name="${output_map[$index]}"
    output_path="${output_map[$((index + 1))]}"
    BAZEL_RELEASE_BIN_PATHS["${bin_name}"]="${output_path}"
  done

  rm -f -- "${raw_outputs_file}" "${output_map_file}"
  info "Resolved ${#BAZEL_RELEASE_BIN_PATHS[@]} Bazel release binary output(s)"
}

generate_config_schema_with_bazel() {
  local config_schema_path="$1"
  local schema_generator="${BAZEL_RELEASE_BIN_PATHS[codex-write-config-schema]:-}"

  [ -n "${schema_generator}" ] \
    || die "Bazel release outputs did not include codex-write-config-schema"
  [ -x "${schema_generator}" ] \
    || die "Bazel config schema generator is not executable: ${schema_generator}"

  rm -f -- "${config_schema_path}"
  info "Generating config schema with the Bazel-built schema generator"
  run "${schema_generator}" --out "${config_schema_path}"
}

generate_non_rust_overlay_artifacts() {
  local checkout_dir="$1"

  info "Generating instruction artifacts inside ${checkout_dir}/.mcr"
  run perl "${checkout_dir}/scripts/release/instruct.pl" \
    --repo-root "${checkout_dir}" \
    --output-root "${checkout_dir}/.mcr"

  info "Generating config placeholder inside ${checkout_dir}/.mcr/config.toml"
  run python3 "${checkout_dir}/scripts/release/config.py" \
    --repo-root "${checkout_dir}" \
    --output-file "${checkout_dir}/.mcr/config.toml"
}

read_release_bins() {
  local repo_root="$1"
  local release_bins_path=""
  local release_bins_output
  local bin
  local -A seen_bins=()

  release_bins_output="$(create_release_scratch_file "read-release-bins")"

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

    if ! python3 - "${release_bins_path}" > "${release_bins_output}" <<'PY'
from pathlib import Path
import sys

for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.split("#", 1)[0].strip()
    if line:
        print(line)
PY
    then
      rm -f -- "${release_bins_output}"
      die "failed to read release bin manifest: ${release_bins_path}"
    fi
  elif ! python3 - "${repo_root}/.gitlab-ci.yml" > "${release_bins_output}" <<'PY'
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
  then
    rm -f -- "${release_bins_output}"
    die "failed to read RELEASE_BINS from ${repo_root}/.gitlab-ci.yml"
  fi

  mapfile -t RELEASE_BINS < "${release_bins_output}"
  rm -f -- "${release_bins_output}"
  [ "${#RELEASE_BINS[@]}" -gt 0 ] || die "release binary contract is empty"
  for bin in "${RELEASE_BINS[@]}"; do
    [[ "${bin}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
      || die "invalid release binary name: ${bin}"
    [ -z "${seen_bins[$bin]:-}" ] || die "duplicate release binary name: ${bin}"
    seen_bins["${bin}"]=1
  done
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
run_bazel = os.environ["RUN_BAZEL"] == "true"
run_cargo = os.environ["RUN_CARGO"] == "true"


def optional_env(name: str) -> str | None:
    return os.environ.get(name) or None


manifest = {
    "build_root": os.environ["BUILD_ROOT"],
    "cache_root": os.environ["CACHE_ROOT"],
    "comp": os.environ["COMP"],
    "backends": [
        backend
        for backend, enabled in (("bazel", run_bazel), ("cargo", run_cargo))
        if enabled
    ],
    "artifact_backend": os.environ["ARTIFACT_BACKEND"],
    "build_jobs": int(os.environ["BUILD_JOBS"]),
    "cargo_build_jobs": (
        int(os.environ["CARGO_JOBS"]) if run_cargo else None
    ),
    "version": os.environ["WORKSPACE_VERSION"],
    "target": os.environ["RUST_TARGET"],
    "base_ref": os.environ["BASE_REF"],
    "base_commit": os.environ["BASE_COMMIT"],
    "overlay_commit": os.environ["OVERLAY_COMMIT"],
    "rust_toolchain": optional_env("RUST_TOOLCHAIN") if run_cargo else None,
    "toolchain_manager": "mise" if run_cargo else None,
    "cargo_profile": "release" if run_cargo else None,
    "cargo_profile_lto": (
        optional_env("CARGO_PROFILE_RELEASE_LTO") if run_cargo else None
    ),
    "cargo_target_dir": optional_env("CARGO_TARGET_DIR") if run_cargo else None,
    "target_cpu": os.environ.get("RUST_TARGET_CPU"),
    "rustc_threads": optional_env("RUSTC_THREADS") if run_cargo else None,
    "rust_target_features": (
        optional_env("RUST_TARGET_FEATURES") if run_cargo else None
    ),
    "host_cpu_model": os.environ.get("HOST_CPU_MODEL"),
    "host_cpu_flags": os.environ.get("HOST_CPU_FLAGS"),
    "cargo_encoded_rustflags": (
        optional_env("CARGO_ENCODED_RUSTFLAGS") if run_cargo else None
    ),
    "release_bins": bins_path.read_text(encoding="utf-8").splitlines(),
    "config_schema_sha256": hashlib.sha256(config_schema_path.read_bytes()).hexdigest(),
    "archive": os.environ["RELEASE_ARCHIVE_NAME"],
    "bazel_target": optional_env("BAZEL_TARGET") if run_bazel else None,
    "bazel_version": optional_env("BAZEL_VERSION") if run_bazel else None,
    "bazel_cache_root": optional_env("BAZEL_CACHE_ROOT") if run_bazel else None,
    "bazel_compilation_mode": (
        optional_env("BAZEL_COMPILATION_MODE") if run_bazel else None
    ),
    "bazel_rustc_flags": (
        [f"-Ctarget-cpu={os.environ['RUST_TARGET_CPU']}"] if run_bazel else []
    ),
    "sccache_dir": optional_env("SCCACHE_DIR") if run_cargo else None,
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
RUSTC_THREADS="${RELEASE_RUSTC_THREADS:-${DEFAULT_RUSTC_THREADS}}"
BASE_REF=""
BUILD_JOBS="${DEFAULT_BUILD_JOBS}"
CARGO_JOBS=""
CARGO_LTO="${RELEASE_CARGO_LTO:-${DEFAULT_CARGO_LTO}}"
WORKSPACE_VERSION_OVERRIDE=""
COMP="${DEFAULT_COMP}"
RUN_BAZEL="false"
RUN_CARGO="false"
ARTIFACT_BACKEND=""
BUILD_CARGO_HOME=""
BAZEL_EXECUTION_ROOT=""
BAZEL_OUTPUT_BASE=""
declare -A BAZEL_RELEASE_BIN_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --comp)
      [ $# -ge 2 ] || die "--comp requires a value"
      COMP="$2"
      shift 2
      ;;
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
    --version)
      [ $# -ge 2 ] || die "--version requires a value"
      WORKSPACE_VERSION_OVERRIDE="$2"
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
      BUILD_JOBS="$2"
      shift 2
      ;;
    --cargo-jobs)
      [ $# -ge 2 ] || die "--cargo-jobs requires a value"
      CARGO_JOBS="$2"
      shift 2
      ;;
    --cargo-lto)
      [ $# -ge 2 ] || die "--cargo-lto requires a value"
      CARGO_LTO="$2"
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

case "${COMP}" in
  both)
    RUN_BAZEL="true"
    RUN_CARGO="true"
    ARTIFACT_BACKEND="cargo"
    ;;
  bazel)
    RUN_BAZEL="true"
    ARTIFACT_BACKEND="bazel"
    ;;
  cargo)
    RUN_CARGO="true"
    ARTIFACT_BACKEND="cargo"
    ;;
  *)
    die "--comp must be one of: both, bazel, cargo (got: ${COMP})"
    ;;
esac

require_cmd git
require_cmd python3
require_cmd sha256sum
require_cmd tar
if [ "${RUN_CARGO}" = "true" ]; then
  require_cmd mise
fi
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

if [ "${RUN_CARGO}" = "true" ]; then
  BUILD_CARGO_HOME="${CARGO_HOME:-${CACHE_ROOT}/cargo-home}"
  require_absolute_path "${BUILD_CARGO_HOME}"
fi

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

if ! [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  die "--jobs must be a positive integer"
fi
if [ -z "${CARGO_JOBS}" ]; then
  CARGO_JOBS="${BUILD_JOBS}"
fi
if ! [[ "${CARGO_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  die "--cargo-jobs must be a positive integer"
fi
case "${CARGO_LTO}" in
  off|false|thin|fat|true) ;;
  *)
    die "--cargo-lto must be one of: off, false, thin, fat, true (got: ${CARGO_LTO})"
    ;;
esac
validate_target_cpu "${RUST_TARGET_CPU}"
if [ "${RUN_BAZEL}" = "true" ]; then
  case "${BAZEL_TARGET}" in
    //*) ;;
    *) die "--bazel-target must be an absolute Bazel label: ${BAZEL_TARGET}" ;;
  esac
fi
if [ -n "${RUSTC_THREADS}" ] && ! [[ "${RUSTC_THREADS}" =~ ^[1-9][0-9]*$ ]]; then
  die "--rustc-threads must be a positive integer"
fi
if [ -n "${WORKSPACE_VERSION_OVERRIDE}" ]; then
  run python3 "${REPO_ROOT}/scripts/release/codex_version.py" \
    validate "${WORKSPACE_VERSION_OVERRIDE}"
fi

export BUILD_ROOT CACHE_ROOT BASE_REF RUST_TARGET RELEASE_ARCHIVE_NAME BAZEL_TARGET
export RUST_TARGET_CPU COMP RUN_BAZEL RUN_CARGO ARTIFACT_BACKEND BUILD_JOBS
export CARGO_JOBS
export BAZEL_COMPILATION_MODE

run mkdir -p -- "${BUILD_ROOT}" "${CACHE_ROOT}"
export RELEASE_CACHE_ROOT="${CACHE_ROOT}"

HOST_CPU_MODEL="$(detect_host_cpu_model 2>/dev/null || true)"
HOST_CPU_FLAGS="$(detect_host_cpu_flags 2>/dev/null || true)"
RUST_TARGET_FEATURES=""
export RUST_CHANNEL RUSTC_THREADS HOST_CPU_MODEL HOST_CPU_FLAGS RUST_TARGET_FEATURES

if [ "${RUN_CARGO}" = "true" ]; then
  ensure_linux_release_build_prerequisites
  run mkdir -p -- "${BUILD_CARGO_HOME}" "${CACHE_ROOT}/target"
  export CARGO_HOME="${BUILD_CARGO_HOME}"
  export CARGO_TARGET_DIR="${CACHE_ROOT}/target"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  export CARGO_PROFILE_RELEASE_LTO="${CARGO_LTO}"
  unset RUSTUP_TOOLCHAIN

  TOOLCHAIN_FILE="${REPO_ROOT}/codex-rs/rust-toolchain.toml"
  [ -f "${TOOLCHAIN_FILE}" ] || die "missing ${TOOLCHAIN_FILE}"
  export RUSTC_THREADS
  ensure_rust_toolchain "${RUST_CHANNEL}" "${RUST_TARGET}"
  ensure_sccache
  RUST_TARGET_FEATURES="$(
    detect_rust_target_features "${RUST_CHANNEL}" "${RUST_TARGET}" "${RUST_TARGET_CPU}" 2>/dev/null || true
  )"
  export RUST_TARGET_FEATURES
  configure_build_rustflags "${RUST_CHANNEL}" "${RUST_TARGET_CPU}" "${RUSTC_THREADS}"
  info "Using Cargo release profile override: lto=${CARGO_PROFILE_RELEASE_LTO}"
fi

if [ "${RUN_BAZEL}" = "true" ]; then
  ensure_bazel
fi

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
RECONCILE_ARGS=(
  --base-ref "${BASE_REF}"
  --worktree-dir "${CHECKOUT_DIR}"
  --keep-worktree
)
if [ -n "${WORKSPACE_VERSION_OVERRIDE}" ]; then
  RECONCILE_ARGS+=(--workspace-version "${WORKSPACE_VERSION_OVERRIDE}")
fi
if [ "${RUN_CARGO}" = "true" ]; then
  run_with_mise_rust "${RUST_CHANNEL}" "${REPO_ROOT}/scripts/release/reconcile.sh" \
    "${RECONCILE_ARGS[@]}"
else
  RECONCILE_ARGS+=(--skip-generated-artifacts)
  run "${REPO_ROOT}/scripts/release/reconcile.sh" "${RECONCILE_ARGS[@]}"
fi

CONFIG_SCHEMA_PATH="${CHECKOUT_DIR}/codex-rs/core/config.schema.json"

info "Validating migration numeric versions after reconciliation"
run python3 \
  "${CHECKOUT_DIR}/${RELEASE_VERIFY_DIR}/verify_unique_migration_versions.py" \
  --migrations-dir "${CHECKOUT_DIR}/codex-rs/state/migrations"

info "Validating release binary contract after reconciliation"
run python3 "${CHECKOUT_DIR}/${RELEASE_VERIFY_DIR}/verify_release_bin_contract.py" --repo-root "${CHECKOUT_DIR}"

info "Validating Rust release source contracts after reconciliation"
run python3 \
  "${CHECKOUT_DIR}/${RELEASE_VERIFY_DIR}/verify_rust_release_source_contract.py" \
  --repo-root "${CHECKOUT_DIR}"

WORKSPACE_VERSION="$(read_workspace_version "${CHECKOUT_DIR}/codex-rs/Cargo.toml")"
if [ -n "${WORKSPACE_VERSION_OVERRIDE}" ] \
  && [ "${WORKSPACE_VERSION}" != "${WORKSPACE_VERSION_OVERRIDE}" ]; then
  die "workspace version override was not applied: expected ${WORKSPACE_VERSION_OVERRIDE}, got ${WORKSPACE_VERSION}"
fi
BASE_COMMIT="$(git -C "${CHECKOUT_DIR}" rev-parse HEAD)"
OVERLAY_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
export WORKSPACE_VERSION BASE_COMMIT OVERLAY_COMMIT

read_release_bins "${CHECKOUT_DIR}"

BUILD_ID="${WORKSPACE_VERSION}-${RUST_TARGET}-$(printf '%s' "${BASE_COMMIT}" | cut -c1-12)-$(printf '%s' "${OVERLAY_COMMIT}" | cut -c1-12)"
if [ "${COMP}" != "both" ]; then
  BUILD_ID+="-${COMP}"
fi
OUTPUT_DIR="${BUILD_ROOT}/${BUILD_ID}"
STAGING_DIR="${BUILD_ROOT}/.staging-${BUILD_ID}-$$"
RELEASE_BIN_LIST_FILE="${CACHE_ROOT}/release-bins.${BUILD_ID}.txt"

printf '%s\n' "${RELEASE_BINS[@]}" > "${RELEASE_BIN_LIST_FILE}"

if [ "${RUN_CARGO}" = "true" ]; then
  sync_lockfile_if_needed "${CHECKOUT_DIR}/codex-rs/Cargo.toml" "${RUST_CHANNEL}"
  configure_cargo_rusty_v8_artifacts "${CHECKOUT_DIR}"
fi

if [ "${RUN_BAZEL}" = "true" ]; then
  build_bazel_release_target "${CHECKOUT_DIR}" "${RUST_TARGET_CPU}"
  collect_bazel_release_outputs \
    "${CHECKOUT_DIR}" \
    "${RELEASE_BIN_LIST_FILE}" \
    "${RUST_TARGET_CPU}"
fi

if [ "${ARTIFACT_BACKEND}" = "bazel" ]; then
  generate_config_schema_with_bazel "${CONFIG_SCHEMA_PATH}"
fi

[ -f "${CONFIG_SCHEMA_PATH}" ] || die "missing generated config schema: ${CONFIG_SCHEMA_PATH}"
info "Validating generated config schema"
run python3 -m json.tool "${CONFIG_SCHEMA_PATH}" >/dev/null

if [ "${ARTIFACT_BACKEND}" = "bazel" ]; then
  generate_non_rust_overlay_artifacts "${CHECKOUT_DIR}"
fi

run_release_verifier_if_present \
  "${CHECKOUT_DIR}" \
  "verify_prompt_inventory_contract.py" \
  "Validating instruction inventory after patch application"

if [ "${RUN_CARGO}" = "true" ]; then
  # Cargo produces the archive payload in both/cargo modes. Its compiler flags
  # include -C target-cpu=skylake by default.
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
  BUILD_CMD+=(--jobs "${CARGO_JOBS}")
  for bin in "${RELEASE_BINS[@]}"; do
    BUILD_CMD+=(--bin "${bin}")
  done

  info "Building ${#RELEASE_BINS[@]} release binary/binaries for ${RUST_TARGET} with Cargo (${CARGO_JOBS} job(s))"
  run_with_mise_rust "${RUST_CHANNEL}" cargo "${BUILD_CMD[@]}"
fi

rm -rf -- "${STAGING_DIR}"
run mkdir -p -- "${STAGING_DIR}/bin"

for bin in "${RELEASE_BINS[@]}"; do
  case "${ARTIFACT_BACKEND}" in
    bazel)
      src="${BAZEL_RELEASE_BIN_PATHS[$bin]:-}"
      ;;
    cargo)
      src="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/${bin}"
      ;;
    *)
      die "unsupported artifact backend: ${ARTIFACT_BACKEND}"
      ;;
  esac
  [ -n "${src}" ] || die "missing ${ARTIFACT_BACKEND} output path for binary: ${bin}"
  [ -f "${src}" ] || die "missing built binary: ${src}"
  [ -x "${src}" ] || die "built binary is not executable: ${src}"
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
