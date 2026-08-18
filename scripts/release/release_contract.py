#!/usr/bin/env python3
"""Shared release overlay contract helpers."""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PATCHES_DIR = Path("debian/patches")
DEFAULT_SERIES_FILE = DEFAULT_PATCHES_DIR / "series"
DEFAULT_INVENTORY_FILE = Path("scripts/release/instruction_inventory.json")
EXCLUDED_PREFIXES = (
    "debian/patches/ROLLOUT",
    "debian/patches/rollouts/",
)
MEMORY_MARKER = "memor"
RELEASE_BIN_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


def inventory_path_for_repo(repo_root: Path) -> Path:
    return repo_root / DEFAULT_INVENTORY_FILE


def load_inventory(repo_root: Path) -> tuple[Path, dict[str, Any]]:
    inventory_path = inventory_path_for_repo(repo_root)
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    validate_instruction_inventory(inventory, inventory_path)
    return inventory_path, inventory


def validate_instruction_inventory(
    inventory: dict[str, Any], inventory_path: Path
) -> None:
    if not isinstance(inventory, dict):
        raise ValueError(f"{inventory_path} must contain a JSON object")

    override_assets = inventory.get("override_assets", [])
    static_generated_assets = inventory.get("static_generated_assets", [])
    if not isinstance(override_assets, list):
        raise ValueError(f"{inventory_path} override_assets must be a JSON array")
    if not isinstance(static_generated_assets, list):
        raise ValueError(
            f"{inventory_path} static_generated_assets must be a JSON array"
        )

    validate_assets(override_assets, inventory_path, "override_assets")
    validate_assets(static_generated_assets, inventory_path, "static_generated_assets")

    seen_binding_paths: dict[tuple[str, ...], str] = {}
    for asset in override_assets:
        target = asset["target"]
        for binding in asset.get("config_bindings", []):
            binding_path = tuple(binding["path"])
            previous_target = seen_binding_paths.get(binding_path)
            if previous_target is not None:
                joined_path = ".".join(binding_path)
                raise ValueError(
                    "duplicate config binding path "
                    f"{joined_path} in {inventory_path}: "
                    f"{previous_target} and {target}"
                )
            seen_binding_paths[binding_path] = target


def validate_assets(assets: list[Any], inventory_path: Path, section_name: str) -> None:
    seen_targets: set[str] = set()
    for index, asset in enumerate(assets):
        if not isinstance(asset, dict):
            raise ValueError(
                f"{inventory_path} {section_name}[{index}] must be a JSON object"
            )

        target = require_relative_fragment(
            asset.get("target"), inventory_path, f"{section_name}[{index}].target"
        )
        if target in seen_targets:
            raise ValueError(
                f"{inventory_path} {section_name} reuses target {target!r}"
            )
        seen_targets.add(target)

        kind = asset.get("kind")
        if kind not in {"file", "const", "function", "generated"}:
            raise ValueError(
                f"{inventory_path} {section_name}[{index}].kind is unsupported: {kind!r}"
            )

        if kind == "generated":
            require_non_empty_string(
                asset.get("generated_key"),
                inventory_path,
                f"{section_name}[{index}].generated_key",
            )
        else:
            require_relative_fragment(
                asset.get("source"),
                inventory_path,
                f"{section_name}[{index}].source",
            )
            if kind in {"const", "function"}:
                require_non_empty_string(
                    asset.get("symbol"),
                    inventory_path,
                    f"{section_name}[{index}].symbol",
                )

        replacements = asset.get("replacements", [])
        if not isinstance(replacements, list):
            raise ValueError(
                f"{inventory_path} {section_name}[{index}].replacements must be a JSON array"
            )
        for replacement_index, replacement in enumerate(replacements):
            if (
                not isinstance(replacement, list)
                or len(replacement) != 2
                or not all(isinstance(item, str) for item in replacement)
            ):
                raise ValueError(
                    f"{inventory_path} {section_name}[{index}].replacements[{replacement_index}] "
                    "must contain exactly two strings"
                )

        config_bindings = asset.get("config_bindings", [])
        if not isinstance(config_bindings, list):
            raise ValueError(
                f"{inventory_path} {section_name}[{index}].config_bindings must be a JSON array"
            )
        for binding_index, binding in enumerate(config_bindings):
            if not isinstance(binding, dict):
                raise ValueError(
                    f"{inventory_path} {section_name}[{index}].config_bindings[{binding_index}] "
                    "must be a JSON object"
                )
            binding_kind = binding.get("kind")
            if binding_kind not in {"file_path", "inline_string"}:
                raise ValueError(
                    f"{inventory_path} {section_name}[{index}].config_bindings[{binding_index}].kind "
                    f"is unsupported: {binding_kind!r}"
                )
            binding_path = binding.get("path")
            if (
                not isinstance(binding_path, list)
                or not binding_path
                or not all(
                    isinstance(segment, str) and segment for segment in binding_path
                )
            ):
                raise ValueError(
                    f"{inventory_path} {section_name}[{index}].config_bindings[{binding_index}].path "
                    "must be a non-empty array of strings"
                )


def require_relative_fragment(value: Any, inventory_path: Path, field_name: str) -> str:
    text = require_non_empty_string(value, inventory_path, field_name)
    if text.startswith("/") or ".." in Path(text).parts:
        raise ValueError(
            f"{inventory_path} {field_name} must stay repo-relative: {text!r}"
        )
    return text


def require_non_empty_string(value: Any, inventory_path: Path, field_name: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{inventory_path} {field_name} must be a non-empty string")
    return value


def read_release_bin_names(bins_file: Path) -> list[str]:
    bins: list[str] = []
    seen: set[str] = set()
    for lineno, raw_line in enumerate(
        bins_file.read_text(encoding="utf-8").splitlines(), start=1
    ):
        bin_name = raw_line.split("#", 1)[0].strip()
        if not bin_name:
            continue
        if RELEASE_BIN_NAME_PATTERN.fullmatch(bin_name) is None:
            raise ValueError(
                f"invalid release binary name at {bins_file}:{lineno}: {bin_name!r}"
            )
        if bin_name in seen:
            raise ValueError(
                f"duplicate release binary name at {bins_file}:{lineno}: {bin_name!r}"
            )
        seen.add(bin_name)
        bins.append(bin_name)

    if not bins:
        raise ValueError(f"release binary manifest is empty: {bins_file}")
    return bins


def path_is_within(path: Path, roots: tuple[Path, ...]) -> bool:
    return any(path == root or root in path.parents for root in roots)


def resolve_bazel_release_outputs(
    execution_root: Path,
    output_base: Path,
    outputs_file: Path,
    bins_file: Path,
) -> list[tuple[str, Path]]:
    execution_root = Path(os.path.abspath(execution_root))
    output_base = Path(os.path.abspath(output_base))
    allowed_roots = (execution_root, output_base)
    release_bins = read_release_bin_names(bins_file)
    release_bin_set = set(release_bins)
    output_paths: set[Path] = set()

    for raw_line in outputs_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        raw_path = Path(line)
        if raw_path.is_absolute():
            candidate = Path(os.path.abspath(raw_path))
        elif line.startswith("bazel-out/"):
            candidate = Path(os.path.abspath(execution_root / raw_path))
        else:
            continue

        if not path_is_within(candidate, allowed_roots):
            raise ValueError(
                f"Bazel output path escaped the execution/output roots: {candidate}"
            )
        if not candidate.is_file():
            raise ValueError(f"Bazel reported a missing output file: {candidate}")
        output_paths.add(candidate)

    executable_outputs: dict[str, list[Path]] = {}
    unexpected_executables: list[Path] = []
    for output_path in sorted(output_paths):
        if not os.access(output_path, os.X_OK):
            continue
        bin_name = output_path.name
        if bin_name not in release_bin_set:
            unexpected_executables.append(output_path)
            continue
        executable_outputs.setdefault(bin_name, []).append(output_path)

    if unexpected_executables:
        joined = ", ".join(str(path) for path in unexpected_executables)
        raise ValueError(f"unexpected executable Bazel release outputs: {joined}")

    resolved: list[tuple[str, Path]] = []
    for bin_name in release_bins:
        candidates = executable_outputs.get(bin_name, [])
        if not candidates:
            raise ValueError(f"missing executable Bazel release output: {bin_name}")
        if len(candidates) != 1:
            joined = ", ".join(str(path) for path in candidates)
            raise ValueError(
                f"multiple executable Bazel release outputs for {bin_name}: {joined}"
            )
        resolved.append((bin_name, candidates[0]))
    return resolved


def list_patch_files(patches_dir: Path) -> list[Path]:
    return sorted(patches_dir.glob("*.patch"))


def extract_patch_targets(patch_path: Path) -> set[str]:
    targets: set[str] = set()
    for raw_line in patch_path.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith("+++ "):
            continue
        target = raw_line[4:].strip()
        if target.startswith("b/"):
            target = target[2:]
        if target == "/dev/null":
            continue
        targets.add(target)
    return targets


def is_excluded_target(target: str) -> bool:
    return target.startswith(EXCLUDED_PREFIXES)


def load_series_entries(series_file: Path) -> list[str]:
    entries: list[str] = []
    seen: set[str] = set()
    for lineno, raw_line in enumerate(
        series_file.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("/") or ".." in Path(line).parts:
            raise ValueError(f"unsafe series entry at {series_file}:{lineno}: {line!r}")
        if not line.endswith(".patch"):
            raise ValueError(
                f"unsupported series entry at {series_file}:{lineno}: {line!r}"
            )
        if line in seen:
            raise ValueError(
                f"duplicate series entry at {series_file}:{lineno}: {line!r}"
            )
        seen.add(line)
        entries.append(line)
    return entries


def resolve_patch_series(
    patches_dir: Path, series_file: Path | None, *, strict: bool = False
) -> tuple[list[Path], list[str], list[str]]:
    patch_files = list_patch_files(patches_dir)
    if series_file is None:
        return patch_files, [], []
    if not series_file.is_file():
        raise FileNotFoundError(f"series file not found: {series_file}")

    series_entries = load_series_entries(series_file)
    if patch_files and not series_entries:
        raise ValueError(f"{series_file} exists but contains no patch entries")

    patch_names = {patch.name for patch in patch_files}
    series_set = set(series_entries)
    missing_from_series = sorted(patch_names - series_set)
    missing_from_patches = sorted(series_set - patch_names)
    if strict and (missing_from_series or missing_from_patches):
        details = [
            *(
                f"patch exists but is not listed in series: {name}"
                for name in missing_from_series
            ),
            *(
                f"series entry does not match any patch file: {name}"
                for name in missing_from_patches
            ),
        ]
        raise ValueError("; ".join(details))
    ordered_patch_files = [patches_dir / entry for entry in series_entries]
    return ordered_patch_files, missing_from_series, missing_from_patches


def verify_patch_target_hygiene(
    patches_dir: Path, series_file: Path | None = None
) -> tuple[list[Path], list[Path], list[tuple[Path, set[str]]], list[str], list[str]]:
    if not patches_dir.is_dir():
        raise FileNotFoundError(f"patches directory not found: {patches_dir}")

    malformed: list[Path] = []
    stale: list[tuple[Path, set[str]]] = []
    patch_files = list_patch_files(patches_dir)
    for patch in patch_files:
        targets = extract_patch_targets(patch)
        if not targets:
            malformed.append(patch)
            continue
        if all(is_excluded_target(target) for target in targets):
            stale.append((patch, targets))

    _, missing_from_series, missing_from_patches = resolve_patch_series(
        patches_dir, series_file
    )
    return patch_files, malformed, stale, missing_from_series, missing_from_patches


def run_verify_patch_targets(patches_dir: Path, series_file: Path | None = None) -> int:
    try:
        (
            patch_files,
            malformed,
            stale,
            missing_from_series,
            missing_from_patches,
        ) = verify_patch_target_hygiene(patches_dir.resolve(), series_file)
    except FileNotFoundError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    if malformed or stale or missing_from_series or missing_from_patches:
        print(
            f"error: release patch hygiene check failed in {patches_dir.resolve()}",
            file=sys.stderr,
        )
        for patch in malformed:
            print(
                f"  - malformed patch (no target paths): {patch.name}",
                file=sys.stderr,
            )
        for patch, targets in stale:
            joined_targets = ", ".join(sorted(targets))
            print(
                "  - stale patch only touches excluded rollout docs: "
                f"{patch.name} ({joined_targets})",
                file=sys.stderr,
            )
        for name in missing_from_series:
            print(
                f"  - patch exists but is not listed in series: {name}",
                file=sys.stderr,
            )
        for name in missing_from_patches:
            print(
                f"  - series entry does not match any patch file: {name}",
                file=sys.stderr,
            )
        return 1

    print(
        f"ok: release patch target hygiene verified ({len(patch_files)} patch file(s))",
    )
    return 0


def run_verify_memory_exclusion(
    patches_dir: Path, series_file: Path | None = None
) -> int:
    try:
        patch_files, _, _ = resolve_patch_series(
            patches_dir.resolve(), series_file.resolve() if series_file else None, strict=True
        )
    except FileNotFoundError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    violations: list[str] = []
    for patch in patch_files:
        for target in sorted(extract_patch_targets(patch)):
            if MEMORY_MARKER in target.casefold():
                violations.append(f"{patch.name}: changes memory path {target!r}")

        for lineno, raw_line in enumerate(
            patch.read_text(encoding="utf-8").splitlines(), start=1
        ):
            if raw_line.startswith(("---", "+++")) or not raw_line.startswith(
                ("+", "-")
            ):
                continue
            if MEMORY_MARKER in raw_line.casefold():
                violations.append(f"{patch.name}:{lineno}: {raw_line}")

    if violations:
        print(
            "error: release patches must not add, remove, or target memory logic",
            file=sys.stderr,
        )
        for violation in violations:
            print(f"  - {violation}", file=sys.stderr)
        return 1

    print(
        f"ok: release patch memory exclusion verified ({len(patch_files)} patch file(s))"
    )
    return 0


def run_verify_patch_targets_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when release patches are stale, malformed, or out of sync "
            "with the declared patch series."
        ),
    )
    parser.add_argument(
        "--patches-dir",
        type=Path,
        default=Path("debian/patches"),
        help="Directory containing release patch files.",
    )
    parser.add_argument(
        "--series-file",
        type=Path,
        default=None,
        help=(
            "Optional patch series file. When provided, every patch under "
            "--patches-dir must be listed exactly once."
        ),
    )
    args = parser.parse_args(argv)
    return run_verify_patch_targets(args.patches_dir, args.series_file)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Shared release overlay contract helpers.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser(
        "print-inventory",
        help="Validate the instruction inventory and print it as JSON.",
    )
    inventory_parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help="Repository root containing scripts/release/instruction_inventory.json.",
    )

    patch_series_parser = subparsers.add_parser(
        "print-patch-series",
        help="Print the ordered release patch series.",
    )
    patch_series_parser.add_argument(
        "--patches-dir",
        type=Path,
        default=DEFAULT_PATCHES_DIR,
        help="Directory containing release patch files.",
    )
    patch_series_parser.add_argument(
        "--series-file",
        type=Path,
        default=DEFAULT_SERIES_FILE,
        help="Patch series file that declares the ordered release patch stack.",
    )
    patch_series_parser.add_argument(
        "--format",
        choices=("lines", "nul"),
        default="lines",
        help="Output format for patch paths.",
    )

    verify_parser = subparsers.add_parser(
        "verify-patch-targets",
        help="Run the release patch hygiene check.",
    )
    verify_parser.add_argument(
        "--patches-dir",
        type=Path,
        default=DEFAULT_PATCHES_DIR,
        help="Directory containing release patch files.",
    )
    verify_parser.add_argument(
        "--series-file",
        type=Path,
        default=DEFAULT_SERIES_FILE,
        help="Patch series file that declares the ordered release patch stack.",
    )

    memory_parser = subparsers.add_parser(
        "verify-memory-exclusion",
        help="Fail when release patches add, remove, or target memory logic.",
    )
    memory_parser.add_argument(
        "--patches-dir",
        type=Path,
        default=DEFAULT_PATCHES_DIR,
        help="Directory containing release patch files.",
    )
    memory_parser.add_argument(
        "--series-file",
        type=Path,
        default=DEFAULT_SERIES_FILE,
        help="Patch series file that declares the ordered release patch stack.",
    )

    bazel_outputs_parser = subparsers.add_parser(
        "resolve-bazel-outputs",
        help="Resolve and validate the executable outputs of the Bazel release target.",
    )
    bazel_outputs_parser.add_argument(
        "--execution-root",
        type=Path,
        required=True,
        help="Bazel execution root used to resolve bazel-out paths.",
    )
    bazel_outputs_parser.add_argument(
        "--output-base",
        type=Path,
        required=True,
        help="Bazel output base allowed for absolute cquery output paths.",
    )
    bazel_outputs_parser.add_argument(
        "--outputs-file",
        type=Path,
        required=True,
        help="File containing `bazel cquery --output=files` output.",
    )
    bazel_outputs_parser.add_argument(
        "--bins-file",
        type=Path,
        required=True,
        help="Release binary manifest to match against executable outputs.",
    )
    bazel_outputs_parser.add_argument(
        "--format",
        choices=("lines", "nul"),
        default="lines",
        help="Output format for binary-name/path pairs.",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "print-inventory":
        _, inventory = load_inventory(args.repo_root.resolve())
        json.dump(inventory, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    if args.command == "print-patch-series":
        try:
            patch_files, _, _ = resolve_patch_series(
                args.patches_dir.resolve(), args.series_file.resolve(), strict=True
            )
        except FileNotFoundError as err:
            print(f"error: {err}", file=sys.stderr)
            return 2
        except ValueError as err:
            print(f"error: {err}", file=sys.stderr)
            return 1

        separator = "\0" if args.format == "nul" else "\n"
        payload = separator.join(str(path) for path in patch_files)
        if payload:
            sys.stdout.write(payload)
            sys.stdout.write(separator)
        return 0

    if args.command == "verify-patch-targets":
        return run_verify_patch_targets(
            args.patches_dir.resolve(), args.series_file.resolve()
        )

    if args.command == "verify-memory-exclusion":
        return run_verify_memory_exclusion(
            args.patches_dir.resolve(), args.series_file.resolve()
        )

    if args.command == "resolve-bazel-outputs":
        try:
            resolved_outputs = resolve_bazel_release_outputs(
                args.execution_root,
                args.output_base,
                args.outputs_file,
                args.bins_file,
            )
        except (OSError, ValueError) as err:
            print(f"error: {err}", file=sys.stderr)
            return 1

        separator = "\0" if args.format == "nul" else "\n"
        records = [
            field
            for bin_name, output_path in resolved_outputs
            for field in (bin_name, str(output_path))
        ]
        payload = separator.join(records)
        if payload:
            sys.stdout.write(payload)
            sys.stdout.write(separator)
        return 0

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
