#!/usr/bin/env python3
"""Verify migration numeric versions are unique.

This script checks `codex-rs/state/migrations` (or a user-provided directory) and
fails if multiple `*.sql` files share the same numeric prefix.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

MIGRATION_RE = re.compile(r"^(?P<version>\d+)_.*\.sql$")


def parse_args() -> argparse.Namespace:
    default_root = Path(__file__).resolve().parents[2]
    default_dir = default_root / "codex-rs" / "state" / "migrations"
    parser = argparse.ArgumentParser(
        description="Fail if duplicate migration numeric versions are present.",
    )
    parser.add_argument(
        "--migrations-dir",
        type=Path,
        default=default_dir,
        help="Directory containing SQL migration files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    migrations_dir = args.migrations_dir.resolve()

    if not migrations_dir.is_dir():
        print(f"error: migrations directory not found: {migrations_dir}", file=sys.stderr)
        return 2

    version_to_files: dict[int, list[str]] = defaultdict(list)
    invalid_names: list[str] = []

    for path in sorted(migrations_dir.glob("*.sql")):
        match = MIGRATION_RE.match(path.name)
        if match is None:
            invalid_names.append(path.name)
            continue
        version = int(match.group("version"))
        version_to_files[version].append(path.name)

    if invalid_names:
        print("error: invalid migration filename(s):", file=sys.stderr)
        for name in invalid_names:
            print(f"  - {name}", file=sys.stderr)
        return 2

    duplicates = {v: names for v, names in version_to_files.items() if len(names) > 1}
    if duplicates:
        print(
            f"error: duplicate migration numeric versions found in {migrations_dir}",
            file=sys.stderr,
        )
        for version in sorted(duplicates):
            names = ", ".join(sorted(duplicates[version]))
            print(f"  - {version}: {names}", file=sys.stderr)
        return 1

    print(
        f"ok: {len(version_to_files)} unique migration versions in {migrations_dir}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
