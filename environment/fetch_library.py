"""Fetch one pinned processing-library source tree."""

import argparse
import json
from pathlib import Path

from fetch_sources import fetch_repository


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-json", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(args.source_json.read_text())
    repo = source["library_repo"]
    commit = source["library_commit"]
    if not repo or not commit:
        raise ValueError("A processing library source is required")
    fetch_repository(
        f"https://github.com/AllenNeuralDynamics/{repo}.git",
        commit,
        args.directory,
    )
    pyproject = args.directory / "pyproject.toml"
    if not pyproject.is_file():
        raise ValueError(f"Processing library has no pyproject.toml: {repo}")
    import hashlib

    digest = hashlib.sha256(pyproject.read_bytes()).hexdigest()
    if digest != source["pyproject_sha256"]:
        raise ValueError("Processing library dependency contract changed")
    print(f"fetched {repo}@{commit}")


if __name__ == "__main__":
    main()
