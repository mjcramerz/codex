#!/usr/bin/env python3

import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CARGO_TOML = ROOT / "codex-rs" / "Cargo.toml"
CARGO_LOCK = ROOT / "codex-rs" / "Cargo.lock"
SEMVER_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def validate_workspace_version(version: str) -> str:
    if SEMVER_PATTERN.fullmatch(version) is None:
        raise ValueError(f"invalid semantic version: {version!r}")
    return version


def read_workspace_version(path: Path) -> str:
    in_workspace_package = False
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_workspace_package = stripped == "[workspace.package]"
            continue
        if in_workspace_package and stripped.startswith("version"):
            match = re.match(r'version\s*=\s*"([^"]+)"', stripped)
            if not match:
                raise ValueError(f"Unsupported version line: {line!r}")
            return match.group(1)
    raise ValueError("workspace.package version not found in codex-rs/Cargo.toml")


def render_workspace_version_update(path: Path, new_version: str) -> tuple[str, str]:
    validate_workspace_version(new_version)
    lines = path.read_text(encoding="utf-8").splitlines()
    in_workspace_package = False
    updated = False
    old_version = ""
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_workspace_package = stripped == "[workspace.package]"
            continue
        if in_workspace_package and stripped.startswith("version"):
            match = re.match(r'(\s*version\s*=\s*")([^"]+)(".*)', line)
            if not match:
                raise ValueError(f"Unsupported version line: {line!r}")
            old_version = match.group(2)
            lines[idx] = f"{match.group(1)}{new_version}{match.group(3)}"
            updated = True
            break
    if not updated:
        raise ValueError("workspace.package version line not found to update")
    return old_version, "\n".join(lines) + "\n"


def inherited_workspace_package_names(workspace_root: Path) -> set[str]:
    package_names: set[str] = set()
    for manifest_path in sorted(workspace_root.rglob("Cargo.toml")):
        relative_parts = manifest_path.relative_to(workspace_root).parts
        if "target" in relative_parts:
            continue
        data = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
        package = data.get("package")
        if package is None or package.get("version") != {"workspace": True}:
            continue
        package_name = package["name"]
        if package_name in package_names:
            raise ValueError(
                f"duplicate workspace package name while updating versions: {package_name}"
            )
        package_names.add(package_name)

    if not package_names:
        raise ValueError(f"no workspace-version packages found under {workspace_root}")
    return package_names


def render_lockfile_version_update(
    lock_path: Path,
    package_names: set[str],
    old_version: str,
    new_version: str,
) -> str:
    lock_text = lock_path.read_text(encoding="utf-8")
    updated_packages: set[str] = set()
    package_block_pattern = re.compile(
        r"(?ms)^\[\[package\]\]\n.*?(?=^\[\[package\]\]\n|\Z)"
    )

    def replace_package_block(match: re.Match[str]) -> str:
        block = match.group(0)
        package = tomllib.loads(block)["package"][0]
        package_name = package["name"]
        if package_name not in package_names:
            return block
        if "source" in package:
            raise ValueError(
                f"workspace package unexpectedly has a registry source in Cargo.lock: {package_name}"
            )
        if package["version"] != old_version:
            raise ValueError(
                "workspace package version mismatch in Cargo.lock: "
                f"{package_name} has {package['version']}, expected {old_version}"
            )

        version_pattern = re.compile(
            rf'(?m)^version = "{re.escape(old_version)}"$'
        )
        updated_block, replacement_count = version_pattern.subn(
            f'version = "{new_version}"',
            block,
            count=1,
        )
        if replacement_count != 1:
            raise ValueError(
                f"failed to update Cargo.lock version for workspace package: {package_name}"
            )
        updated_packages.add(package_name)
        return updated_block

    updated_lock_text = package_block_pattern.sub(replace_package_block, lock_text)
    missing_packages = sorted(package_names - updated_packages)
    if missing_packages:
        raise ValueError(
            "workspace packages missing from Cargo.lock: " + ", ".join(missing_packages)
        )

    parsed_lock = tomllib.loads(updated_lock_text)
    verified_packages = {
        package["name"]
        for package in parsed_lock["package"]
        if package["name"] in package_names
        and "source" not in package
        and package["version"] == new_version
    }
    if verified_packages != package_names:
        raise ValueError("Cargo.lock workspace package versions were not updated completely")
    return updated_lock_text


def set_workspace_version(
    path: Path,
    lock_path: Path,
    new_version: str,
) -> None:
    old_version, updated_manifest = render_workspace_version_update(path, new_version)
    package_names = inherited_workspace_package_names(path.parent)
    updated_lock = render_lockfile_version_update(
        lock_path,
        package_names,
        old_version,
        new_version,
    )
    lock_path.write_text(updated_lock, encoding="utf-8")
    path.write_text(updated_manifest, encoding="utf-8")


def main(argv: list[str]) -> int:
    usage = "Usage: codex_version.py get | validate <version> | set <version>"
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 2
    command = argv[1]
    try:
        if command == "get" and len(argv) == 2:
            print(read_workspace_version(CARGO_TOML))
            return 0
        if command == "validate" and len(argv) == 3:
            validate_workspace_version(argv[2])
            return 0
        if command == "set" and len(argv) == 3:
            set_workspace_version(CARGO_TOML, CARGO_LOCK, argv[2])
            return 0
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
