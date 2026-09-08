"""Resolve the pre-pip CaImAn environment without downloading scientific packages."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "environment/stages/extraction"
BASE_IMAGE = (
    "mambaorg/micromamba:2.3.2@sha256:"
    "955819619f303e2aa1dc1ba89beefe7f326a378b3d0782a4a0d28b1cf11b68b6"
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--micromamba", type=Path, required=True)
    parser.add_argument("--build-log-evidence", type=Path)
    args = parser.parse_args()
    work = ROOT / ".image-work/solver"
    work.mkdir(parents=True, exist_ok=True)
    (FOLDER / "conda-solve.json").write_text(json.dumps({
        "success": False, "solver_problems": ["Conda resolution has not completed successfully"],
        "counts": {"candidate": 1, "processed": 0, "skipped": 0, "failed": 1, "parse_failure": 0},
    }, indent=2) + "\n")
    environment = dict(os.environ, MAMBA_ROOT_PREFIX=str(work / "root"), TMPDIR=str(work),
                       CONDA_OVERRIDE_GLIBC="2.41", CONDA_OVERRIDE_LINUX="5.15",
                       CONDA_OVERRIDE_CUDA="")
    result = subprocess.run([
        str(args.micromamba.resolve()), "create", "--name", "extraction",
        "--platform", "linux-64", "--override-channels", "--channel", "conda-forge",
        "--file", str(FOLDER / "conda-spec.txt"), "--dry-run", "--json",
    ], env=environment, capture_output=True, text=True)
    (work / "extraction-solve.json").write_text(result.stdout)
    data = json.loads(result.stdout)
    report = {
        "solver": subprocess.check_output([str(args.micromamba.resolve()), "--version"],
                                         text=True).strip(),
        "base_image": BASE_IMAGE, "base_distribution": "Debian trixie",
        "platform": "linux-64", "virtual_packages": {"__glibc": "2.41", "__linux": "5.15"},
        "channels": ["conda-forge"], "spec_sha256": digest(FOLDER / "conda-spec.txt"),
        "success": bool(data.get("success")) and result.returncode == 0,
        "solver_problems": data.get("solver_problems", []),
    }
    policy = json.loads((FOLDER / "overlay-policy.json").read_text())
    report["build_log_sha256"] = policy["build_log_sha256"]
    if args.build_log_evidence:
        evidence = json.loads(args.build_log_evidence.read_text())
        if (evidence["failures"] or not evidence["invariants"]["complete"]
                or evidence["source_sha256"] != policy["build_log_sha256"]
                or evidence["suite2p_commit"] != policy["suite2p_commit"]):
            raise ValueError("The build-log evidence does not match the extraction policy")
        for name, change in policy["replacements"].items():
            if any(change[key] != evidence["pip_replacements"][name][key]
                   for key in ("before", "after")):
                raise ValueError("An overlay replacement is not supported by the build log")
        report["historical_transaction_packages"] = evidence["counts"]["conda_packages"]
    packages = data.get("actions", {}).get("LINK", [])
    if report["success"]:
        if not packages or len({row["name"] for row in packages}) != len(packages):
            raise ValueError("The conda solve returned an empty or duplicate package set")
        records = []
        for row in sorted(packages, key=lambda item: item["name"]):
            if not re.fullmatch(
                r"https://conda\.anaconda\.org/conda-forge/(linux-64|noarch)/[^/#]+",
                row["url"],
            ) or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
                raise ValueError("Every conda artifact must have a conda-forge URL and SHA-256")
            records.append({key: row[key] for key in (
                "name", "version", "build_string", "url", "sha256",
            )})
        lock = FOLDER / "conda-linux-64.lock"
        lock.write_text("@EXPLICIT\n" + "".join(
            row["url"] + "#" + row["sha256"] + "\n" for row in records
        ))
        inventory = FOLDER / "conda-packages.json"
        inventory.write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
        report.update(conda_lock_sha256=digest(lock), packages_sha256=digest(inventory))
    report["counts"] = {
        "candidate": len(packages) if report["success"] else 1,
        "processed": len(packages) if report["success"] else 1,
        "skipped": 0, "failed": int(not report["success"]), "parse_failure": 0,
    }
    (FOLDER / "conda-solve.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["counts"], sort_keys=True))
    return int(not report["success"])


if __name__ == "__main__":
    raise SystemExit(main())
