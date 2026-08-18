#!/usr/bin/env python3
"""Verify that the tracked .mcr instruction artifacts match the generators."""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when the tracked instruction override inventory is incomplete.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        required=True,
        help="Reconciled repository root to generate expected artifacts from.",
    )
    parser.add_argument(
        "--artifacts-root",
        type=Path,
        default=None,
        help="Repository root whose .mcr artifacts should be checked. Defaults to --repo-root.",
    )
    return parser.parse_args()


def list_relative_files(root: Path) -> list[str]:
    if not root.is_dir():
        return []
    return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())


def compare_tree(expected_root: Path, actual_root: Path) -> tuple[list[str], list[str], list[str]]:
    expected_files = list_relative_files(expected_root)
    actual_files = list_relative_files(actual_root)
    expected_set = set(expected_files)
    actual_set = set(actual_files)
    missing = sorted(expected_set - actual_set)
    unexpected = sorted(actual_set - expected_set)
    mismatched = sorted(
        relative_path
        for relative_path in expected_files
        if relative_path in actual_set
        and (expected_root / relative_path).read_text(encoding="utf-8")
        != (actual_root / relative_path).read_text(encoding="utf-8")
    )
    return missing, unexpected, mismatched


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    artifacts_root = args.artifacts_root.resolve() if args.artifacts_root is not None else repo_root
    actual_root = artifacts_root / ".mcr"
    actual_override = actual_root / "override-instructions"
    actual_static = actual_root / "static-instructions"
    actual_config = actual_root / "config.toml"

    if not actual_override.is_dir() or not actual_static.is_dir() or not actual_config.is_file():
        print("error: instruction artifact verification failed", file=sys.stderr)
        if not actual_override.is_dir():
            print("  - missing directory: .mcr/override-instructions", file=sys.stderr)
        if not actual_static.is_dir():
            print("  - missing directory: .mcr/static-instructions", file=sys.stderr)
        if not actual_config.is_file():
            print("  - missing file: .mcr/config.toml", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="instruction-inventory-") as tempdir:
        generated_root = Path(tempdir) / ".mcr"
        instruct_script = repo_root / "scripts" / "release" / "instruct.pl"
        config_script = repo_root / "scripts" / "release" / "config.py"
        subprocess.run(
            ["perl", str(instruct_script), "--repo-root", str(repo_root), "--output-root", str(generated_root)],
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            [
                sys.executable,
                str(config_script),
                "--repo-root",
                str(repo_root),
                "--output-file",
                str(generated_root / "config.toml"),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        override_missing, override_unexpected, override_mismatched = compare_tree(
            generated_root / "override-instructions",
            actual_override,
        )
        static_missing, static_unexpected, static_mismatched = compare_tree(
            generated_root / "static-instructions",
            actual_static,
        )
        total_files = len(list_relative_files(generated_root / "override-instructions")) + len(
            list_relative_files(generated_root / "static-instructions")
        )
        config_mismatched = generated_root.joinpath("config.toml").read_text(encoding="utf-8") != actual_config.read_text(encoding="utf-8")

    if (
        override_missing
        or override_unexpected
        or override_mismatched
        or static_missing
        or static_unexpected
        or static_mismatched
        or config_mismatched
    ):
        print("error: instruction artifact verification failed", file=sys.stderr)
        for relative_path in override_missing:
            print(f"  - missing file: .mcr/override-instructions/{relative_path}", file=sys.stderr)
        for relative_path in override_unexpected:
            print(f"  - unexpected file: .mcr/override-instructions/{relative_path}", file=sys.stderr)
        for relative_path in override_mismatched:
            print(f"  - stale file: .mcr/override-instructions/{relative_path}", file=sys.stderr)
        for relative_path in static_missing:
            print(f"  - missing file: .mcr/static-instructions/{relative_path}", file=sys.stderr)
        for relative_path in static_unexpected:
            print(f"  - unexpected file: .mcr/static-instructions/{relative_path}", file=sys.stderr)
        for relative_path in static_mismatched:
            print(f"  - stale file: .mcr/static-instructions/{relative_path}", file=sys.stderr)
        if config_mismatched:
            print("  - stale file: .mcr/config.toml", file=sys.stderr)
        return 1

    print(f"ok: instruction artifacts verified ({total_files} files + config.toml)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
