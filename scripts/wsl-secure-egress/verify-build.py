#!/usr/bin/env python3
"""Verify a native build manifest before it can enter the admin package stage."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_dependency_snapshot(directory, repository, manifest):
    """Validate the dependency snapshot that the hosted build froze."""
    directory = directory.resolve(strict=True)
    value = json.loads((directory / "inputs.json").read_text(encoding="utf-8"))
    frozen = manifest.get("build_inputs")
    if not isinstance(frozen, dict):
        raise ValueError("Build manifest omits the frozen dependency snapshot")
    for key in ("commit", "baseline", "constraints", "files"):
        if frozen.get(key) != value.get(key):
            raise ValueError(f"Dependency snapshot {key} differs from the build manifest")
    if value.get("schema") != 1:
        raise ValueError("Unsupported dependency snapshot schema")
    if value.get("commit") != manifest.get("commit"):
        raise ValueError("Dependency snapshot commit differs from the build commit")

    files = value.get("files")
    baseline = value.get("baseline")
    if not isinstance(files, dict) or not files:
        raise ValueError("Dependency snapshot contains no resolved files")
    if not isinstance(baseline, dict) or set(baseline) != set(files):
        raise ValueError("Dependency snapshot baseline is incomplete")
    if manifest.get("cargo_lock_sha256") != files.get("Cargo.lock"):
        raise ValueError("Build lockfile hash differs from the dependency snapshot")

    for relative, checksum in files.items():
        if not isinstance(relative, str) or not isinstance(checksum, str):
            raise ValueError("Dependency snapshot contains an invalid entry")
        path = directory / relative
        if path.is_symlink() or not path.is_file() or sha256(path) != checksum:
            raise ValueError(f"Dependency snapshot checksum mismatch: {relative}")
        source = subprocess.check_output(
            ["git", "show", f"{value['commit']}:{relative}"],
            cwd=repository,
        )
        if hashlib.sha256(source).hexdigest() != baseline[relative]:
            raise ValueError(f"Dependency snapshot baseline mismatch: {relative}")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--dependency-snapshot", type=Path, required=True)
    parser.add_argument("--system", choices=("windows", "linux", "macos"), required=True)
    parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    args = parser.parse_args()

    repository = args.repository.resolve(strict=True)
    build = args.build.resolve(strict=True)
    scripts = repository / "scripts"
    if not (repository / ".git").exists() or not scripts.is_dir():
        raise ValueError("The repository argument is not the selected worktree")
    sys.path.insert(0, str(scripts))
    import build_inputs
    import workflow_artifacts

    expected_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repository, text=True
    ).strip()
    artifact_manifest = json.loads(
        (build / "manifest.json").read_text(encoding="utf-8")
    )
    dependency_snapshot = load_dependency_snapshot(
        args.dependency_snapshot, repository, artifact_manifest
    )
    manifest = workflow_artifacts.verify_build(
        build,
        args.system,
        args.arch,
        expected_commit,
        dependency_snapshot=args.dependency_snapshot,
    )
    frozen_fields = ("commit", "baseline", "constraints", "files")
    manifest_inputs = manifest.get("build_inputs")
    if not isinstance(manifest_inputs, dict) or any(
        manifest_inputs.get(key) != dependency_snapshot.get(key)
        for key in frozen_fields
    ):
        raise ValueError("Build manifest dependency snapshot differs from the input artifact")
    source_artifact = build / "source-artifact.json"
    result = {
        "schema_version": 1,
        "outcome": "verified",
        "commit": manifest["commit"],
        "version": manifest["version"],
        "system": manifest["system"],
        "arch": manifest["arch"],
        "profile": manifest["profile"],
        "manifest_sha256": sha256(build / "manifest.json"),
        "files": len(manifest["files"]),
        "source_artifact": (
            json.loads(source_artifact.read_text(encoding="utf-8"))
            if source_artifact.is_file()
            else None
        ),
    }
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "outcome": "failed",
                    "message": str(error),
                },
                separators=(",", ":"),
            )
        )
        raise SystemExit(1)
