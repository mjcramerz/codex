#!/usr/bin/env python3
"""Detect stale or miswired release patch files."""

import sys
from pathlib import Path


HELPER_DIR = Path(__file__).resolve().parents[2] / "scripts" / "release"
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from release_contract import run_verify_patch_targets_cli


def main() -> int:
    return run_verify_patch_targets_cli()


if __name__ == "__main__":
    raise SystemExit(main())
