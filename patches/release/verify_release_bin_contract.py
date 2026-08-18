#!/usr/bin/env python3
"""Validate the Debian GNU release binary contract for codex-rs."""

import argparse
import re
import sys
import tomllib
from pathlib import Path


WINDOWS_ONLY_PACKAGES = {"codex-windows-sandbox"}
EXCLUDED_LINUX_BINS = {
    "codex-app-server-test-client",
    "codex-app-server-test-notify-capture",
    "codex-execpolicy",
    "codex-execpolicy-legacy",
    "codex-execve-wrapper",
    "codex-thread-manager-sample",
    "export",
    "logs_client",
    "md-events",
    "rmcp_test_server",
    "test_mcp_2026_discovery_stdio_server",
    "test_mcp_2026_stdio_server",
    "test_notify_capture",
    "test_stdio_server",
    "test_streamable_http_server",
}
DEFAULT_RELEASE_BIN_LIST = Path("scripts/release/release-bins.txt")
DEFAULT_BAZEL_RELEASE_BUILD = Path("bazel/release/BUILD.bazel")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate that the Linux release bin contract exactly enumerates the "
            "workspace binaries defined under codex-rs/."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path('.'),
        help=(
            "Repository root containing codex-rs/ and either "
            "scripts/release/release-bins.txt or .gitlab-ci.yml."
        ),
    )
    return parser.parse_args()


def extract_multiline_block(text: str, key: str) -> list[str]:
    lines = text.splitlines()
    pattern = re.compile(rf'^(?P<indent>[ \t]*){re.escape(key)}:\s*\|\s*$')
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if not match:
            continue
        indent = len(match.group('indent'))
        block: list[str] = []
        for candidate in lines[index + 1 :]:
            if not candidate.strip():
                block.append("")
                continue
            current_indent = len(candidate) - len(candidate.lstrip(' '))
            if current_indent <= indent:
                break
            block.append(candidate.strip())
        return [line for line in block if line]
    raise ValueError(f"missing multiline block for {key}")


def read_release_bins(repo_root: Path) -> list[str]:
    release_bin_list = repo_root / DEFAULT_RELEASE_BIN_LIST
    if release_bin_list.is_file():
        bins = [
            line.split("#", 1)[0].strip()
            for line in release_bin_list.read_text(encoding="utf-8").splitlines()
        ]
        filtered = [line for line in bins if line]
        if not filtered:
            raise ValueError(f"release bin manifest is empty: {release_bin_list}")
        return filtered

    gitlab_ci = repo_root / '.gitlab-ci.yml'
    if not gitlab_ci.is_file():
        raise ValueError(f"missing {gitlab_ci}")
    return extract_multiline_block(gitlab_ci.read_text(encoding='utf-8'), 'RELEASE_BINS')


def auto_discovered_bin_names(
    manifest_dir: Path,
    package_name: str,
    explicit_bin_names: set[str],
    explicit_bin_paths: set[Path],
    autobins: bool,
) -> list[str]:
    if not autobins:
        return []

    bins: list[str] = []
    main_rs = (manifest_dir / 'src' / 'main.rs').resolve()
    if (
        main_rs.is_file()
        and package_name not in explicit_bin_names
        and main_rs not in explicit_bin_paths
    ):
        bins.append(package_name)

    src_bin_dir = manifest_dir / 'src' / 'bin'
    if not src_bin_dir.is_dir():
        return bins

    for path in sorted(src_bin_dir.glob('*.rs')):
        resolved = path.resolve()
        if path.stem not in explicit_bin_names and resolved not in explicit_bin_paths:
            bins.append(path.stem)
    for path in sorted(src_bin_dir.glob('*/main.rs')):
        resolved = path.resolve()
        if path.parent.name not in explicit_bin_names and resolved not in explicit_bin_paths:
            bins.append(path.parent.name)
    return bins


def cargo_manifest_bins(cargo_toml: Path) -> tuple[str | None, list[str]]:
    data = tomllib.loads(cargo_toml.read_text(encoding='utf-8'))
    package = data.get('package')
    if package is None:
        return None, []

    package_name = package['name']
    bins: list[str] = []
    explicit_bin_names: set[str] = set()
    explicit_bin_paths: set[Path] = set()
    for entry in data.get('bin', []):
        name = entry['name']
        if name not in explicit_bin_names:
            bins.append(name)
            explicit_bin_names.add(name)
        raw_path = entry.get('path')
        if raw_path:
            explicit_bin_paths.add((cargo_toml.parent / raw_path).resolve())

    bins.extend(
        auto_discovered_bin_names(
            cargo_toml.parent,
            package_name,
            explicit_bin_names,
            explicit_bin_paths,
            package.get('autobins', True),
        )
    )
    return package_name, bins


def discover_linux_bins(repo_root: Path) -> dict[str, tuple[str, str]]:
    mapping: dict[str, tuple[str, str]] = {}
    for cargo_toml in sorted((repo_root / 'codex-rs').rglob('Cargo.toml')):
        package_name, bins = cargo_manifest_bins(cargo_toml)
        if package_name is None or package_name in WINDOWS_ONLY_PACKAGES:
            continue
        package_path = cargo_toml.parent.relative_to(repo_root).as_posix()
        for bin_name in bins:
            if bin_name in mapping:
                raise ValueError(
                    f"duplicate bin name detected across packages: {bin_name} "
                    f"({mapping[bin_name][0]} and {package_name})"
                )
            mapping[bin_name] = (
                package_name,
                f"//{package_path}:{bin_name}",
            )
    return mapping


def read_bazel_release_labels(repo_root: Path) -> list[str]:
    build_path = repo_root / DEFAULT_BAZEL_RELEASE_BUILD
    if not build_path.is_file():
        raise ValueError(f"missing Bazel release target file: {build_path}")
    match = re.search(
        r'filegroup\(\s*name\s*=\s*"release-binaries",\s*'
        r'srcs\s*=\s*\[(?P<srcs>.*?)\],',
        build_path.read_text(encoding="utf-8"),
        flags=re.DOTALL,
    )
    if match is None:
        raise ValueError(f"missing release-binaries filegroup in {build_path}")
    labels = re.findall(r'"(//[^"\s]+:[^"\s]+)"', match.group("srcs"))
    if not labels:
        raise ValueError(f"Bazel release-binaries filegroup is empty: {build_path}")
    if len(labels) != len(set(labels)):
        raise ValueError(f"Bazel release-binaries filegroup contains duplicates: {build_path}")
    return labels


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    try:
        release_bins = read_release_bins(repo_root)
        available_bins = discover_linux_bins(repo_root)
        bazel_release_labels = read_bazel_release_labels(repo_root)
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    if len(release_bins) != len(set(release_bins)):
        print("error: release bin contract contains duplicates", file=sys.stderr)
        return 1

    release_bin_set = set(release_bins)
    available_bin_set = set(available_bins) - EXCLUDED_LINUX_BINS
    missing_bins = sorted(available_bin_set - release_bin_set)
    unexpected_bins = sorted(release_bin_set - available_bin_set)
    if missing_bins or unexpected_bins:
        print("error: release bin contract does not match discovered Linux binaries:", file=sys.stderr)
        for bin_name in missing_bins:
            print(f"  - missing from release bin contract: {bin_name}", file=sys.stderr)
        for bin_name in unexpected_bins:
            print(
                f"  - unknown or unsupported bin in release bin contract: {bin_name}",
                file=sys.stderr,
            )
        return 1

    expected_bazel_labels = {
        available_bins[bin_name][1]
        for bin_name in release_bins
    }
    actual_bazel_labels = set(bazel_release_labels)
    missing_bazel_labels = sorted(expected_bazel_labels - actual_bazel_labels)
    unexpected_bazel_labels = sorted(actual_bazel_labels - expected_bazel_labels)
    if missing_bazel_labels or unexpected_bazel_labels:
        print("error: Bazel release target does not match release bin contract:", file=sys.stderr)
        for label in missing_bazel_labels:
            print(f"  - missing Bazel release label: {label}", file=sys.stderr)
        for label in unexpected_bazel_labels:
            print(f"  - unexpected Bazel release label: {label}", file=sys.stderr)
        return 1

    release_packages = {available_bins[bin_name][0] for bin_name in release_bins}
    print(
        "ok: release bin contract verified "
        f"({len(release_bins)} bins across {len(release_packages)} packages)"
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
