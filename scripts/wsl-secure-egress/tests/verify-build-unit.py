#!/usr/bin/env python3
"""Offline regression tests for verifying a hosted build dependency snapshot."""

import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT.parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

try:
    import workflow_artifacts
except ModuleNotFoundError as error:
    if error.name != "tomllib":
        raise
    import types

    tomllib = types.ModuleType("tomllib")
    tomllib.loads = lambda _text: {"package": []}
    sys.modules["tomllib"] = tomllib
    import workflow_artifacts


def load_verifier():
    spec = importlib.util.spec_from_file_location(
        "cor_verify_build", ROOT / "verify-build.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VerifyBuildInputTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.repository = self.root / "repository"
        self.snapshot = self.root / "snapshot"
        self.repository.mkdir()
        self.snapshot.mkdir()
        (self.repository / ".git").mkdir()
        (self.repository / "scripts").mkdir()
        self.commit = "a" * 40
        self.snapshot_file = self.snapshot / "Cargo.lock"
        self.snapshot_file.write_bytes(b"resolved dependency snapshot\n")
        checksum = load_verifier().sha256(self.snapshot_file)
        self.baseline_file = b"baseline dependency snapshot\n"
        self.inputs = {
            "schema": 1,
            "commit": self.commit,
            "baseline": {
                "Cargo.lock": hashlib.sha256(self.baseline_file).hexdigest()
            },
            "constraints": {},
            "files": {"Cargo.lock": checksum},
        }
        (self.snapshot / "inputs.json").write_text(
            json.dumps(self.inputs), encoding="utf-8"
        )

    def manifest(self):
        return {
            "schema": 2,
            "commit": self.commit,
            "version": "0.6.1",
            "system": "windows",
            "arch": "x64",
            "profile": "release",
            "cargo_lock_sha256": self.inputs["files"]["Cargo.lock"],
            "build_inputs": self.inputs,
            "files": {},
            "tests": {},
        }

    def run_main(self, snapshot_loader=None):
        verifier = load_verifier()
        build = self.root / "build"
        build.mkdir(exist_ok=True)
        (build / "manifest.json").write_text(
            json.dumps(self.manifest()), encoding="utf-8"
        )
        argv = [
            "verify-build.py",
            "--repository",
            str(self.repository),
            "--build",
            str(build),
            "--dependency-snapshot",
            str(self.snapshot),
            "--system",
            "windows",
            "--arch",
            "x64",
        ]
        with patch.object(sys, "argv", argv), patch.object(
            verifier,
            "load_dependency_snapshot",
            wraps=snapshot_loader,
        ), patch.object(
            workflow_artifacts,
            "verify_build",
            return_value=self.manifest(),
        ) as verified, patch.object(sys, "stdout"):
            if snapshot_loader is None:
                with patch.object(
                    subprocess,
                    "check_output",
                    side_effect=[
                        (self.commit + "\n").encode(),
                        self.baseline_file,
                    ],
                ):
                    verifier.main()
            else:
                with patch.object(
                    subprocess,
                    "check_output",
                    return_value=(self.commit + "\n").encode(),
                ):
                    verifier.main()
        return verified

    def test_accepts_the_frozen_snapshot_and_passes_it_to_the_verifier(self):
        verifier = load_verifier()
        with patch.object(
            subprocess, "check_output", return_value=self.baseline_file
        ):
            snapshot = verifier.load_dependency_snapshot(
                self.snapshot, self.repository, self.manifest()
            )
        self.assertEqual(snapshot, self.inputs)
        verified = self.run_main(
            snapshot_loader=lambda directory, repository, manifest: (
                snapshot
                if (directory, repository) == (self.snapshot, self.repository)
                else self.fail("unexpected snapshot path")
            )
        )
        self.assertEqual(
            verified.call_args.kwargs["dependency_snapshot"], self.snapshot
        )

    def test_rejects_snapshot_or_build_hash_drift(self):
        verifier = load_verifier()
        self.snapshot_file.write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verifier.load_dependency_snapshot(
                self.snapshot, self.repository, self.manifest()
            )

        self.snapshot_file.write_bytes(b"resolved dependency snapshot\n")
        manifest = self.manifest()
        manifest["cargo_lock_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "lockfile hash"):
            verifier.load_dependency_snapshot(
                self.snapshot, self.repository, manifest
            )

    def test_rejects_commit_baseline_constraint_and_file_set_drift(self):
        verifier = load_verifier()
        for key in ("commit", "baseline", "constraints", "files"):
            manifest = self.manifest()
            manifest["build_inputs"] = dict(self.inputs)
            manifest["build_inputs"][key] = (
                "d" * 40
                if key == "commit"
                else {"Cargo.lock": "d" * 64}
                if key in ("baseline", "files")
                else {"Cargo.toml": "d" * 64}
            )
            with self.subTest(key=key), self.assertRaisesRegex(
                ValueError, f"snapshot {key}"
            ):
                verifier.load_dependency_snapshot(
                    self.snapshot, self.repository, manifest
                )

    def test_source_checkout_does_not_need_to_equal_the_ci_lockfile(self):
        source = self.repository / "Cargo.lock"
        source.write_text("checked-in baseline\n", encoding="utf-8")
        self.assertNotEqual(
            load_verifier().sha256(source), self.inputs["files"]["Cargo.lock"]
        )
        verifier = load_verifier()
        with patch.object(
            verifier,
            "load_dependency_snapshot",
            return_value=self.inputs,
        ), patch.object(
            workflow_artifacts,
            "verify_build",
            return_value=self.manifest(),
        ), patch.object(
            subprocess,
            "check_output",
            return_value=(self.commit + "\n").encode(),
        ), patch.object(
            sys,
            "argv",
            [
                "verify-build.py",
                "--repository",
                str(self.repository),
                "--build",
                str(self.root / "build"),
                "--dependency-snapshot",
                str(self.snapshot),
                "--system",
                "windows",
                "--arch",
                "x64",
            ],
        ), patch.object(sys, "stdout"):
            (self.root / "build").mkdir(exist_ok=True)
            (self.root / "build" / "manifest.json").write_text(
                json.dumps(self.manifest()), encoding="utf-8"
            )
            verifier.main()


if __name__ == "__main__":
    unittest.main()
