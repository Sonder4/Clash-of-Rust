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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--system", choices=("windows", "linux", "macos"), required=True)
    parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    args = parser.parse_args()

    repository = args.repository.resolve(strict=True)
    build = args.build.resolve(strict=True)
    scripts = repository / "scripts"
    if not (repository / ".git").exists() or not scripts.is_dir():
        raise ValueError("The repository argument is not the selected worktree")
    sys.path.insert(0, str(scripts))
    from workflow_artifacts import verify_build

    expected_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repository, text=True
    ).strip()
    manifest = verify_build(build, args.system, args.arch, expected_commit)
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
