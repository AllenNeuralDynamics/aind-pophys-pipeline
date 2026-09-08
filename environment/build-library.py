"""Build only the pinned processing library, independently of dependency wheels."""

import hashlib
import argparse
import json
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(Path("/opt/image/source.json").read_text())
    commit = source["library_commit"]
    data = (args.source / "pyproject.toml").read_bytes()
    if hashlib.sha256(data).hexdigest() != source["pyproject_sha256"]:
        raise ValueError("Library dependency contract changed; recapture inputs")
    subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps", "--no-cache-dir",
                    "--build-constraint", "/opt/build.constraints",
                    "--wheel-dir", "/library", str(args.source)], check=True)
    wheels = list(Path("/library").glob("*.whl"))
    if len(wheels) != 1:
        raise ValueError("Expected exactly one processing library wheel")
    Path("/opt/image/library-wheel.json").write_text(json.dumps({
        "library_commit": commit, "wheel": wheels[0].name,
        "sha256": hashlib.sha256(wheels[0].read_bytes()).hexdigest(),
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
