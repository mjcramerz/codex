#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import codex_version
import release_contract


ROOT = Path(__file__).resolve().parents[2]


class ReleaseToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.execution_root = self.root / "execroot"
        self.output_base = self.root / "output-base"
        self.execution_root.mkdir()
        self.output_base.mkdir()
        self.bins_file = self.root / "release-bins.txt"
        self.bins_file.write_text("alpha\nbeta\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def output(self, relative_path: str, *, executable: bool = True) -> Path:
        path = self.execution_root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(relative_path.encode())
        path.chmod(0o755 if executable else 0o644)
        return path

    def resolve(self, paths: list[Path]) -> list[tuple[str, Path]]:
        outputs_file = self.root / "outputs.txt"
        outputs_file.write_text(
            "INFO: ignored\n" + "\n".join(map(str, paths)) + "\n",
            encoding="utf-8",
        )
        return release_contract.resolve_bazel_release_outputs(
            self.execution_root,
            self.output_base,
            outputs_file,
            self.bins_file,
        )

    def test_bazel_output_contract(self) -> None:
        alpha = self.output("bazel-out/opt/bin/pkg/alpha")
        alpha_two = self.output("bazel-out/opt/bin/pkg-two/alpha")
        beta = self.output("bazel-out/opt/bin/pkg/beta")
        extra = self.output("bazel-out/opt/bin/pkg/extra")
        metadata = self.output(
            "bazel-out/opt/bin/pkg/alpha.metadata",
            executable=False,
        )
        relative = lambda path: path.relative_to(self.execution_root)

        self.assertEqual(
            self.resolve([relative(alpha), relative(beta), relative(metadata)]),
            [("alpha", alpha), ("beta", beta)],
        )
        cases = (
            ([relative(alpha)], "missing executable"),
            (
                [relative(alpha), relative(alpha_two), relative(beta)],
                "multiple executable",
            ),
            (
                [relative(alpha), relative(beta), relative(extra)],
                "unexpected executable",
            ),
        )
        for paths, error_pattern in cases:
            with self.subTest(error_pattern=error_pattern):
                with self.assertRaisesRegex(ValueError, error_pattern):
                    self.resolve(paths)

    def test_workspace_version_updates_lockfile_without_cargo(self) -> None:
        cargo_toml = self.root / "Cargo.toml"
        cargo_lock = self.root / "Cargo.lock"
        cargo_toml.write_text(
            '[workspace]\nmembers = ["alpha"]\n\n[workspace.package]\n'
            'version = "0.0.0"\n',
            encoding="utf-8",
        )
        (self.root / "alpha").mkdir()
        (self.root / "alpha" / "Cargo.toml").write_text(
            '[package]\nname = "alpha"\nversion.workspace = true\n',
            encoding="utf-8",
        )
        cargo_lock.write_text(
            'version = 4\n\n[[package]]\nname = "alpha"\nversion = "0.0.0"\n\n'
            '[[package]]\nname = "registry-package"\nversion = "9.9.9"\n'
            'source = "registry+https://example.invalid/index"\n',
            encoding="utf-8",
        )

        codex_version.set_workspace_version(cargo_toml, cargo_lock, "1.2.3")

        self.assertEqual(codex_version.read_workspace_version(cargo_toml), "1.2.3")
        packages = {
            package["name"]: package
            for package in tomllib.loads(cargo_lock.read_text())["package"]
        }
        self.assertEqual(packages["alpha"]["version"], "1.2.3")
        self.assertEqual(packages["registry-package"]["version"], "9.9.9")

    def test_make_compilation_backend_routing(self) -> None:
        environment = os.environ.copy()
        environment.pop("COMP", None)
        environment.pop("RELEASE_RUSTC_THREADS", None)
        cases = (
            (None, "both", True, True),
            ("both", "both", True, True),
            ("bazel", "bazel", False, True),
            ("cargo", "cargo", True, False),
        )
        for requested_mode, expected_mode, has_cargo, has_bazel in cases:
            command = [
                "make",
                "--no-print-directory",
                "-n",
                "build",
                "VERSION=1.2.3",
                "RELEASE_TOOLCHAIN=nightly",
                "RELEASE_BAZEL_TARGET=//bazel/release:release-binaries",
            ]
            if requested_mode is not None:
                command.append(f"COMP={requested_mode}")
            with self.subTest(mode=requested_mode or "default"):
                result = subprocess.run(
                    command,
                    cwd=ROOT,
                    env=environment,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                output = result.stdout
                self.assertIn(f'--comp "{expected_mode}"', output)
                self.assertIn('--version "1.2.3"', output)
                self.assertEqual('--toolchain "nightly"' in output, has_cargo)
                self.assertEqual(
                    '--bazel-target "//bazel/release:release-binaries"' in output,
                    has_bazel,
                )
                self.assertEqual(
                    '--rustc-threads "1"' in output,
                    has_cargo,
                )
                self.assertIn("codex.tar.gz", output)
                self.assertIn("config.schema.json", output)

    def test_make_rustc_threads_override(self) -> None:
        result = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "-n",
                "build",
                "COMP=cargo",
                "VERSION=1.2.3",
                "RELEASE_RUSTC_THREADS=2",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn('--rustc-threads "2"', result.stdout)


if __name__ == "__main__":
    unittest.main()
