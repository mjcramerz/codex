#!/usr/bin/env python3
"""Validate source-level Rust release guards after applying the patch queue."""

import argparse
import json
import re
import sys
from pathlib import Path


CLI_RECURSION_LIMIT = '#![recursion_limit = "256"]'
DEBUG_ONLY_HTTP_IMPORTS = (
    "HttpClientFactory",
    "OutboundProxyPolicy",
)
INSTRUCTION_OVERRIDE_RUNTIME_ROOTS = (
    Path("codex-rs/app-server/src"),
    Path("codex-rs/core/src"),
    Path("codex-rs/models-manager/src"),
    Path("codex-rs/tui/src"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate Rust source contracts that must hold in the reconciled "
            "release worktree before compilation."
        ),
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        required=True,
        help="Reconciled repository root containing the applied patch queue.",
    )
    return parser.parse_args()


def read_text(path: Path, errors: list[str]) -> str:
    if not path.is_file():
        errors.append(f"missing source file: {path}")
        return ""
    return path.read_text(encoding="utf-8")


def verify_cli_recursion_limit(repo_root: Path, errors: list[str]) -> None:
    path = repo_root / "codex-rs" / "cli" / "src" / "main.rs"
    text = read_text(path, errors)
    if text and not text.startswith(f"{CLI_RECURSION_LIMIT}\n"):
        errors.append(
            "codex CLI crate root must start with "
            f"{CLI_RECURSION_LIMIT}: {path}"
        )


def verify_atomic_update_api(repo_root: Path, errors: list[str]) -> None:
    path = (
        repo_root
        / "codex-rs"
        / "code-mode-runtime"
        / "src"
        / "session_runtime"
        / "mod.rs"
    )
    text = read_text(path, errors)
    if not text:
        return
    match = re.search(
        r"fn allocate_cell_id\(&self\).*?(?=\n    async fn start_cell)",
        text,
        flags=re.DOTALL,
    )
    if match is None:
        errors.append(f"missing SessionRuntime::allocate_cell_id implementation: {path}")
        return
    body = match.group(0)
    if ".fetch_update(" in body:
        errors.append(f"deprecated AtomicU64::fetch_update remains in {path}")
    if ".try_update(" not in body:
        errors.append(f"AtomicU64::try_update is missing from {path}")


def verify_debug_only_http_imports(repo_root: Path, errors: list[str]) -> None:
    path = repo_root / "codex-rs" / "cloud-tasks" / "src" / "lib.rs"
    text = read_text(path, errors)
    if not text:
        return
    for import_name in DEBUG_ONLY_HTTP_IMPORTS:
        pattern = re.compile(
            rf"(?m)^#\[cfg\(debug_assertions\)\]\n"
            rf"use codex_http_client::{import_name};$"
        )
        if pattern.search(text) is None:
            errors.append(
                "release-only unused import guard is missing for "
                f"codex_http_client::{import_name}: {path}"
            )


def verify_instruction_override_wiring(
    repo_root: Path,
    errors: list[str],
) -> tuple[int, int]:
    inventory_path = (
        repo_root / "scripts" / "release" / "instruction_inventory.json"
    )
    loader_path = (
        repo_root
        / "codex-rs"
        / "core"
        / "src"
        / "config"
        / "instruction_overrides.rs"
    )
    inventory_text = read_text(inventory_path, errors)
    loader_text = read_text(loader_path, errors)
    if not inventory_text or not loader_text:
        return 0, 0

    try:
        inventory = json.loads(inventory_text)
    except json.JSONDecodeError as error:
        errors.append(f"invalid instruction inventory JSON at {inventory_path}: {error}")
        return 0, 0
    if not isinstance(inventory, dict):
        errors.append(f"instruction inventory must contain a JSON object: {inventory_path}")
        return 0, 0

    override_bindings: list[str] = []
    for asset in inventory.get("override_assets", []):
        for binding in asset.get("config_bindings", []):
            path = binding.get("path")
            if (
                binding.get("kind") == "file_path"
                and isinstance(path, list)
                and path
                and path[0] == "instruction_overrides"
                and all(isinstance(part, str) for part in path)
            ):
                override_bindings.append(".".join(path))
    override_bindings.sort()
    for binding in override_bindings:
        if f'"{binding}"' not in loader_text:
            errors.append(
                f"instruction override binding is not loaded: {binding} ({loader_path})"
            )

    struct_match = re.search(
        r"pub struct InstructionOverrides \{(?P<body>.*?)\n\}",
        loader_text,
        flags=re.DOTALL,
    )
    if struct_match is None:
        errors.append(f"missing InstructionOverrides struct: {loader_path}")
        return len(override_bindings), 0

    runtime_fields = re.findall(
        r"^\s*pub ([a-z0-9_]+):",
        struct_match.group("body"),
        flags=re.MULTILINE,
    )
    runtime_sources: list[str] = []
    for relative_root in INSTRUCTION_OVERRIDE_RUNTIME_ROOTS:
        source_root = repo_root / relative_root
        for path in source_root.rglob("*.rs"):
            relative = path.relative_to(source_root)
            if path == loader_path:
                continue
            if "tests" in relative.parts or path.name.endswith("_tests.rs"):
                continue
            runtime_sources.append(path.read_text(encoding="utf-8"))

    for field in runtime_fields:
        pattern = re.compile(
            rf"\binstruction_overrides\b.{{0,240}}\b{re.escape(field)}\b",
            flags=re.DOTALL,
        )
        if not any(pattern.search(source) for source in runtime_sources):
            errors.append(
                f"loaded instruction override field has no runtime use: {field}"
            )

    return len(override_bindings), len(runtime_fields)


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    errors: list[str] = []

    verify_cli_recursion_limit(repo_root, errors)
    verify_atomic_update_api(repo_root, errors)
    verify_debug_only_http_imports(repo_root, errors)
    override_binding_count, override_field_count = verify_instruction_override_wiring(
        repo_root,
        errors,
    )

    if errors:
        print("error: Rust release source contract validation failed", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        "ok: Rust release source contracts verified "
        f"({override_binding_count} instruction bindings, "
        f"{override_field_count} runtime fields)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
