#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CARGO_TOML = ROOT / "codex-rs" / "Cargo.toml"


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


def set_workspace_version(path: Path, new_version: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    in_workspace_package = False
    updated = False
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_workspace_package = stripped == "[workspace.package]"
            continue
        if in_workspace_package and stripped.startswith("version"):
            match = re.match(r'(\s*version\s*=\s*")([^"]+)(".*)', line)
            if not match:
                raise ValueError(f"Unsupported version line: {line!r}")
            lines[idx] = f"{match.group(1)}{new_version}{match.group(3)}"
            updated = True
            break
    if not updated:
        raise ValueError("workspace.package version line not found to update")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: codex_version.py get | set <version>", file=sys.stderr)
        return 2
    command = argv[1]
    if command == "get":
        print(read_workspace_version(CARGO_TOML))
        return 0
    if command == "set" and len(argv) == 3:
        set_workspace_version(CARGO_TOML, argv[2])
        return 0
    print("Usage: codex_version.py get | set <version>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
