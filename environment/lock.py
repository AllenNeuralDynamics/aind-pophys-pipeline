#!/usr/bin/env python3
"""Resolve each step's dependency lock from its pinned processing library.

Usage (from the repository root, Python 3.11+ and uv required):

    uv run --python 3.12 --no-project environment/lock.py DFF OASIS
    uv run --python 3.12 --no-project environment/lock.py all

For each step this reads ``<STEP>_LIBRARY_REPO`` and ``<STEP>_LIBRARY_COMMIT``
from ``pipeline/process_versions.env`` (or ``process_versions_custom.env``),
writes the library's declared dependencies to
``environment/stages/<step>/requirements.in`` and resolves them into
``requirements.lock`` for linux/amd64. The existing lock is used as the
preferred set of versions, so only what the library's dependencies require
changes. Review the lock diff before building.
"""

import json
import re
import subprocess
import sys
import tempfile
import tomllib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT = ROOT / "environment"
IMAGES = json.loads((ENVIRONMENT / "images.json").read_text())
GPU_STEPS = {"CLASSIFIER"}


def read_versions():
    """Return the process manifest the pipeline would read."""
    custom = ROOT / "pipeline" / "process_versions_custom.env"
    manifest = custom if custom.exists() else ROOT / "pipeline" / "process_versions.env"
    values = {}
    for line in manifest.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def library_dependencies(repo, commit):
    """Return the ``[project] dependencies`` of ``repo`` at ``commit``."""
    with tempfile.TemporaryDirectory() as work:
        subprocess.run(["git", "init", "-q", work], check=True)
        subprocess.run(["git", "-C", work, "fetch", "-q", "--depth", "1", repo, commit], check=True)
        pyproject = subprocess.check_output(
            ["git", "-C", work, "show", "FETCH_HEAD:pyproject.toml"], text=True
        )
    return tomllib.loads(pyproject)["project"].get("dependencies", [])


def cpu_wheel(package, version, python):
    """Pin a CPU torch wheel by its verified index URL and hash."""
    abi = "cp" + python.replace(".", "")
    with urllib.request.urlopen(f"https://download.pytorch.org/whl/cpu/{package}/") as response:
        urls = re.findall(r'href="([^"]+)"', response.read().decode())
    stem = f"{package}-{version.replace('+', '%2B')}-{abi}-{abi}-"
    matches = [
        url for url in urls
        if stem in url and re.search(r"(manylinux_[0-9_]+|linux)_x86_64\.whl#sha256=[0-9a-f]{64}$", url)
    ]
    if len(matches) != 1:
        raise ValueError(f"{package} {version}: expected one Linux {abi} CPU wheel")
    return f"{package} @ {matches[0]}"


def lock(step, versions):
    """Write ``requirements.in`` and resolve ``requirements.lock`` for one step."""
    folder = ENVIRONMENT / "stages" / step.lower()
    python = IMAGES[step]["python"]
    requirements = library_dependencies(
        versions[f"{step}_LIBRARY_REPO"], versions[f"{step}_LIBRARY_COMMIT"]
    )
    extra = folder / "extra.in"
    if extra.exists():
        requirements += [line for line in extra.read_text().splitlines() if line and not line.startswith("#")]
    (folder / "requirements.in").write_text("\n".join(requirements) + "\n")
    command = [
        "uv", "pip", "compile", str(folder / "requirements.in"),
        "--build-constraints", str(folder / "build.constraints"),
        "--python-version", python, "--python-platform", "x86_64-manylinux_2_28",
        "--no-header", "--no-annotate", "--no-strip-extras",
        "--output-file", str(folder / "requirements.lock"),
    ]
    if step not in GPU_STEPS:
        command += ["--torch-backend", "cpu"]
    if (folder / "overrides.in").exists():
        command += ["--overrides", str(folder / "overrides.in")]
    if step == "EXTRACTION":
        # Packages the conda environment provides are resolved but not emitted.
        policy = json.loads((folder / "overlay-policy.json").read_text())
        for name in sorted(policy["conda_only"]):
            command += ["--no-emit-package", name]
    lock_file = folder / "requirements.lock"
    if lock_file.exists():
        # The resolver prefers versions already in the lock, but only reads
        # name==version lines, so turn pinned CPU wheel URLs back into versions.
        previous = [
            re.sub(r"^(torch|torchvision|torchaudio) @ \S+/\1-([^-]+)-.*$",
                   lambda m: f"{m[1]}=={m[2].replace('%2B', '+')}", line)
            for line in lock_file.read_text().splitlines()
        ]
        lock_file.write_text("\n".join(previous) + "\n")
    subprocess.run(command, check=True)
    lines = lock_file.read_text().splitlines()
    for index, line in enumerate(lines):
        if re.fullmatch(r"(torch|torchvision|torchaudio)==[^ ]+\+cpu", line):
            package, version = line.split("==")
            lines[index] = cpu_wheel(package, version, python)
    lock_file.write_text("\n".join(lines) + "\n")


def main(argv):
    names = [name for arg in argv for name in arg.replace(",", " ").split()]
    steps = list(IMAGES) if names == ["all"] else names
    unknown = set(steps) - set(IMAGES)
    if not steps or unknown:
        sys.exit(f"Name steps from {', '.join(IMAGES)}, or all")
    versions = read_versions()
    failed = []
    for step in steps:
        try:
            lock(step, versions)
            print(f"{step}: locked")
        except (subprocess.CalledProcessError, ValueError, KeyError) as error:
            failed.append(step)
            print(f"{step}: failed: {error}", file=sys.stderr)
    print(json.dumps({"steps": len(steps), "locked": len(steps) - len(failed), "failed": failed}))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
