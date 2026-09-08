"""Install only pip additions and exact, historically observed conda replacements."""

import argparse
import importlib.metadata
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


def canonical(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def conda_distribution_versions(records):
    """Map the known conda/PyPI name differences for a pre-build overlap check.

    This checks solver metadata only. The image must repeat the check against
    importlib.metadata because conda names do not prove installed Python identity.
    """
    aliases = {
        "matplotlib-base": "matplotlib", "python-tzdata": "tzdata",
        "py-opencv": "opencv-python", "python-flatbuffers": "flatbuffers",
    }
    native = {"tzdata", "flatbuffers", "matplotlib", "opencv", "libopencv"}
    result = {}
    for row in records:
        if row["name"] in native:
            continue
        name = aliases.get(canonical(row["name"]), canonical(row["name"]))
        if name in result and result[name] != row["version"]:
            raise ValueError(f"Ambiguous conda distribution identity: {name}")
        result[name] = row["version"]
    return result


def decide(name, version, installed, policy):
    """Reject all unapproved replacements, including unexpected new source versions."""
    name = canonical(name)
    if name in policy["conda_only"] or name == "caiman":
        raise ValueError(f"{name} must come only from conda-forge")
    if name not in installed:
        return "install"
    if installed[name] == version:
        return "skip"
    expected = policy["replacements"].get(name)
    if expected and (installed[name], version) == (expected["before"], expected["after"]):
        return "replace"
    raise ValueError(f"Unsafe conda overlay: {name} {installed[name]} would become {version}")


def verify_base(installed, policy):
    for name, version in policy["protected"].items():
        if installed.get(name) != version:
            raise ValueError(f"Protected conda distribution {name} must be {version}")


def requirement_identity(line):
    match = re.fullmatch(r"([\w.-]+)(?:\[[^\]]+\])?\s*(==|@)\s*(.+)", line)
    if not match:
        raise ValueError(f"Expected a locked requirement: {line}")
    name, operator, value = match.groups()
    version = value if operator == "==" else None
    if operator == "@" and urlsplit(value).path.endswith(".whl"):
        version = unquote(urlsplit(value).path).rsplit("/", 1)[-1].split("-")[1]
    return canonical(name), version


def select_requirements(lines, installed, policy):
    verify_base(installed, policy)
    selected = []
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        name, version = requirement_identity(line)
        if decide(name, version, installed, policy) != "skip":
            selected.append(line)
    return selected


def select_wheels(wheels, installed, policy):
    verify_base(installed, policy)
    selected, replacements, skipped = [], [], []
    seen = set()
    shared = policy["shared_namespace"]
    for path in sorted(wheels):
        name, version = path.name.split("-")[:2]
        name = canonical(name)
        if name in seen:
            raise ValueError(f"Duplicate wheel distribution: {name}")
        seen.add(name)
        if name == shared["pip_distribution"]:
            if (version != shared["pip_version"]
                    or installed.get(shared["conda_distribution"]) != shared["conda_version"]):
                raise ValueError("Unapproved cv2 namespace overlay")
        action = decide(name, version, installed, policy)
        if action == "skip":
            skipped.append(name)
        else:
            selected.append(path)
            if action == "replace":
                replacements.append(name)
    return selected, replacements, skipped


def verify_final(installed, policy, cv2):
    verify_base(installed, policy)
    for name, versions in policy["replacements"].items():
        if installed.get(name) != versions["after"]:
            raise ValueError(f"Missing reviewed replacement: {name}")
    shared = policy["shared_namespace"]
    if installed.get(shared["pip_distribution"]) != shared["pip_version"]:
        raise ValueError("Missing locked opencv-python-headless distribution")
    if cv2.__version__ != shared["expected_import_version"]:
        raise ValueError(f"Unexpected effective cv2 version: {cv2.__version__}")
    return {"effective_cv2_version": cv2.__version__, "module_path": cv2.__file__,
            "shared_namespace_risk": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "install", "verify"))
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--wheels", type=Path, default=Path("/wheels"))
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text())
    installed = {canonical(dist.name): dist.version for dist in importlib.metadata.distributions()}
    if args.mode == "prepare":
        lines = args.lock.read_text().splitlines()
        selected = select_requirements(lines, installed, policy)
        args.output.write_text("\n".join(selected) + "\n")
        print(json.dumps({"selected_requirements": len(selected), "same_version_conda": "excluded"}))
    elif args.mode == "install":
        wheels = list(args.wheels.glob("*.whl"))
        selected, replacements, skipped = select_wheels(wheels, installed, policy)
        if not selected:
            raise ValueError("The extraction pip overlay must not be empty")
        subprocess.run([sys.executable, "-m", "pip", "install", "--no-cache-dir", "--no-index",
                        "--no-deps", *map(str, selected)], check=True)
        print(json.dumps({
            "candidate": len(wheels), "processed": len(selected), "skipped": len(skipped),
            "failed": 0, "parse_failure": 0, "replacements": replacements,
            "shared_namespace_risk": policy["shared_namespace"],
        }, sort_keys=True))
    else:
        import cv2
        print(json.dumps(verify_final(installed, policy, cv2)))


if __name__ == "__main__":
    main()
