#!/usr/bin/env python3
"""Prepare and validate independent, unpromoted image candidates (Python 3.12+)."""

import argparse
import hashlib
import json
import os
import re
import runpy
import subprocess
import sys
import tomllib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT = ROOT / "environment"
IMAGE_ORG = "AllenNeuralDynamics"
STAGES = (
    "CONVERTER", "MOTION_CORRECTION", "MOVIE_QC", "DECROSSTALK_SPLIT",
    "DECROSSTALK_ROI_IMAGES", "EXTRACTION", "DFF", "OASIS", "CLASSIFIER",
    "NWB", "AGGREGATOR",
)
PYTHON = {stage: "3.12" for stage in STAGES}
PYTHON.update({stage: "3.10" for stage in (
    "MOTION_CORRECTION", "DECROSSTALK_ROI_IMAGES", "EXTRACTION",
)})
LOG_NAMES = {
    "aind-pophys-converter": "CONVERTER",
    "aind-ophys-motion-correction": "MOTION_CORRECTION",
    "aind-ophys-movie-qc": "MOVIE_QC",
    "aind-ophys-decrosstalk-roi-images": "DECROSSTALK_ROI_IMAGES",
    "aind-ophys-extraction": "EXTRACTION",
    "aind-ophys-dff": "DFF",
    "aind-ophys-oasis-event-detection": "OASIS",
    "aind-ophys-classifier": "CLASSIFIER",
    "aind-ophys-nwb": "NWB",
}
LOG_SHA = "f09685e8b6f4228d0dd37e867b52de0286fffccb"
AGGREGATOR_SHA = "06ae8790b1ecf106ea376ddc52785a027877a3d3"


def canonical(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def manifest():
    return dict(
        line.split("=", 1)
        for line in (ROOT / "pipeline/capsule_versions.env").read_text().splitlines()
        if line and not line.startswith("#")
    )


def selected(value):
    names = value.replace(",", " ").split()
    if names == ["all"]:
        return list(STAGES)
    if not names or len(set(names)) != len(names) or set(names) - set(STAGES):
        raise ValueError("Select all or unique, comma/space-separated stage names: " + ", ".join(STAGES))
    return [stage for stage in STAGES if stage in names]


def read_pinned(repositories, repo, commit, path):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError(f"{repo}: a full Git commit is required")
    return subprocess.check_output(
        ["git", "-C", str(repositories / repo), "show", f"{commit}:{path}"], text=True
    )


def parse_observations(lines):
    """Read every tagged pip row, rejecting discrepancies instead of choosing a task."""
    tasks, failures = {}, []
    candidates = skipped = processed = 0
    pattern = re.compile(r"^\[([^@]+)@([^\]]+)\] pip\s+(.*)$")
    for number, line in enumerate(lines, 1):
        if "] pip " not in line:
            continue
        candidates += 1
        match = pattern.match(line.rstrip())
        if not match:
            failures.append(f"line {number}: malformed package tag")
            continue
        name, host, payload = match.groups()
        stage = LOG_NAMES.get(name)
        if stage is None:
            failures.append(f"line {number}: unknown package stage {name}")
            continue
        fields = payload.split()
        if not fields or fields[0] == "Package" or set(fields[0]) == {"-"}:
            skipped += 1
            continue
        if (len(fields) not in (2, 3)
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", fields[0])
                or not re.fullmatch(r"[0-9][A-Za-z0-9_.+!-]*", fields[1])):
            failures.append(f"line {number}: malformed package row")
            continue
        package, version = canonical(fields[0]), fields[1]
        packages = tasks.setdefault(stage, {}).setdefault(host, {})
        if package in packages and packages[package] != version:
            failures.append(f"{stage}/{host}: conflicting {package} versions")
        packages[package] = version
        processed += 1
    result = {}
    for stage in sorted(tasks):
        hosts = tasks[stage]
        first = hosts[sorted(hosts)[0]]
        if any(packages != first for packages in hosts.values()):
            failures.append(f"{stage}: package lists differ between tasks")
        result[stage] = {"task_count": len(hosts), "packages": dict(sorted(first.items()))}
    missing = set(LOG_NAMES.values()) - set(result)
    if missing:
        failures.append("Missing package evidence: " + ", ".join(sorted(missing)))
    return {
        "counts": {"candidate": candidates, "processed": processed, "skipped": skipped,
                   "failed": len(failures), "parse_failure": sum("line " in f for f in failures)},
        "invariants": {"nine_stages": not missing, "consistent_per_task": not failures},
        "failures": failures, "stages": result,
    }


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def capture(args):
    """Export only exact Git objects; never consume a clone's checkout."""
    pins = manifest()
    inventory = json.loads(args.inventory.read_text())
    baseline = json.loads((ROOT / "pipeline/baseline.json").read_text())
    if inventory["pipeline_commit"] != baseline["pipeline_commit"]:
        raise ValueError("Inventory does not match the selected pipeline baseline")
    records = {row["stage"]: row for row in inventory["stages"]}
    if len(inventory["stages"]) != len(STAGES) or set(records) != set(STAGES):
        raise ValueError("Inventory must contain exactly eleven unique stages")
    with args.log.open() as stream:
        observations = parse_observations(stream)
    observations["computation_id"] = baseline["computation_id"]
    observations["log_sha256"] = hashlib.sha256(args.log.read_bytes()).hexdigest()
    write_json(ENVIRONMENT / "observed-packages.json", observations)
    if observations["failures"]:
        raise ValueError("; ".join(observations["failures"]))
    for stage in STAGES:
        record = records[stage]
        folder = ENVIRONMENT / "stages" / stage.lower()
        folder.mkdir(parents=True, exist_ok=True)
        repo, commit = record.get("library_repo"), record.get("library_commit")
        if stage == "AGGREGATOR":
            repo, commit = "aind-metadata-manager", AGGREGATOR_SHA
        if stage in baseline["stage_source_pins"]:
            if [record["capsule_commit"], commit] != baseline["stage_source_pins"][stage]:
                raise ValueError(f"{stage}: inventory/source baseline mismatch")
        if repo and pins[f"{stage}_LIBRARY_COMMIT"] != commit:
            raise ValueError(f"{stage}: library manifest mismatch")
        project = {}
        raw = ""
        if repo:
            raw = read_pinned(args.repositories, repo, commit, "pyproject.toml")
            project = tomllib.loads(raw)
        dependencies = project.get("project", {}).get("dependencies", [])
        requirements = [
            dep.replace("@f09685e#", f"@{LOG_SHA}#") for dep in dependencies
        ]
        if stage == "AGGREGATOR":
            requirements += ["aind-data-schema==2.9.0", "aind-data-schema-models==6.2.0"]
        # Source identity is deliberately NOT written into the dependency-cache inputs.
        (folder / "requirements.in").write_text("\n".join(requirements) + "\n")
        excluded = {canonical(repo or ""), "aind-pophys-metadata", "log-schema", "suite2p"}
        packages = observations["stages"].get(stage, {}).get("packages", {})
        constraints = [
            f"{name}=={version}" for name, version in sorted(packages.items())
            if name not in excluded
        ]
        (folder / "observed.constraints").write_text("\n".join(constraints) + "\n")
        build_constraints = (ENVIRONMENT / "builder-requirements.txt").read_text().splitlines()
        if "numpy" in packages:
            build_constraints.append("numpy==" + packages["numpy"])
        if "cython" in packages:
            build_constraints.append("Cython==" + packages["cython"])
        (folder / "build.constraints").write_text("\n".join(build_constraints) + "\n")
        write_json(folder / "source.json", {
            "stage": stage, "python": PYTHON[stage], "library_repo": repo,
            "library_commit": commit,
            "distribution": project.get("project", {}).get("name"),
            "requires_python": project.get("project", {}).get("requires-python"),
            "build_requires": project.get("build-system", {}).get("requires", []),
            "declared_dependencies": dependencies,
            "pyproject_sha256": hashlib.sha256(raw.encode()).hexdigest() if raw else None,
            "capsule_source_mode": pins[f"{stage}_CAPSULE_SOURCE_MODE"],
            "capsule_ref": pins.get(f"{stage}_CAPSULE_COMMIT", pins.get(f"{stage}_REF")),
        })
    print(json.dumps(observations["counts"], sort_keys=True))


def validate():
    pins = manifest()
    rows = [
        line.split("\t") for line in (ENVIRONMENT / "images.tsv").read_text().splitlines()
        if line and not line.startswith("#")
    ]
    if len(rows) != len(STAGES) or {row[0] for row in rows} != set(STAGES):
        raise ValueError("images.tsv must contain exactly all eleven stages")
    if any(len(row) != 4 for row in rows):
        raise ValueError("images.tsv rows must have stage, recipe, image, visibility")
    if len({row[2] for row in rows}) != len(STAGES):
        raise ValueError("Every stage must have its own image identity")
    for stage, recipe, image, visibility in rows:
        if not re.fullmatch(r"ghcr.io/allenneuraldynamics/[a-z0-9-]+", image):
            raise ValueError(f"{stage}: invalid GHCR image")
        if visibility not in ("private", "internal"):
            raise ValueError(f"{stage}: candidate image visibility must be private or internal")
        if not (ENVIRONMENT / recipe).is_file():
            raise ValueError(f"{stage}: missing recipe")
        source = json.loads((ENVIRONMENT / "stages" / stage.lower() / "source.json").read_text())
        if source["stage"] != stage or source["python"] != PYTHON[stage]:
            raise ValueError(f"{stage}: invalid runtime contract")
        if source["library_repo"] and source["library_commit"] != pins[f"{stage}_LIBRARY_COMMIT"]:
            raise ValueError(f"{stage}: stale library source; recapture before building")
        if source["capsule_source_mode"] != pins[f"{stage}_CAPSULE_SOURCE_MODE"]:
            raise ValueError(f"{stage}: stale capsule source mode")
        expected_ref = pins.get(f"{stage}_CAPSULE_COMMIT", pins.get(f"{stage}_REF"))
        if source["capsule_ref"] != expected_ref:
            raise ValueError(f"{stage}: stale capsule source ref")
        requirements = (ENVIRONMENT / "stages" / stage.lower() / "requirements.in").read_text()
        for requirement in source["declared_dependencies"]:
            if requirement.replace("@f09685e#", f"@{LOG_SHA}#") not in requirements.splitlines():
                raise ValueError(f"{stage}: declared dependency was dropped: {requirement}")
    return {row[0]: {"stage": row[0], "recipe": row[1], "image": row[2],
                    "visibility": row[3], "python": PYTHON[row[0]]} for row in rows}


def require_private_package(image, allow_missing=False):
    """Require private or enterprise-internal visibility; never public."""
    match = re.fullmatch(r"ghcr\.io/([^/]+)/([a-z0-9-]+)", image)
    if not match or match[1].lower() != IMAGE_ORG.lower():
        raise ValueError(f"Invalid GHCR candidate image: {image}")
    package = match[2]
    result = subprocess.run(
        [
            "gh", "api",
            f"orgs/{IMAGE_ORG}/packages/container/{package}",
            "--include",
            "--jq", ".visibility",
        ],
        capture_output=True,
        text=True,
    )
    status = re.search(r"^HTTP/\S+\s+(\d{3})\b", result.stdout, re.MULTILINE)
    if status is None:
        raise ValueError(f"{image}: unable to determine GHCR package status")
    status_code = int(status[1])
    if status_code == 404 and allow_missing:
        return "absent; first GHCR publish defaults to private"
    if result.returncode != 0 or status_code != 200:
        raise ValueError(
            f"{image}: unable to verify GHCR package visibility (HTTP {status_code})"
        )
    visibility = result.stdout.strip().splitlines()[-1]
    if visibility not in ("private", "internal"):
        raise ValueError(f"{image}: refusing publication with visibility {visibility!r}")
    return visibility


def dependency_hash(folder):
    names = ("requirements.in", "observed.constraints", "build.constraints",
             "overrides.in", "conda-spec.txt", "conda-provided.in", "overlay-policy.json",
             "conda-linux-64.lock", "conda-packages.json", "../../builder-requirements.txt")
    return hashlib.sha256(b"".join(
        name.encode() + (folder / name).read_bytes()
        for name in names if (folder / name).exists()
    )).hexdigest()


def extraction_conda_contract(folder):
    report = json.loads((folder / "conda-solve.json").read_text())
    if not report["success"]:
        raise ValueError("The extraction conda solve failed: " + "; ".join(report["solver_problems"]))
    for filename, key in (
        ("conda-spec.txt", "spec_sha256"),
        ("conda-linux-64.lock", "conda_lock_sha256"),
        ("conda-packages.json", "packages_sha256"),
    ):
        if hashlib.sha256((folder / filename).read_bytes()).hexdigest() != report[key]:
            raise ValueError(f"EXTRACTION: stale or modified {filename}; rerun the conda solve")
    if report["base_image"] not in (ENVIRONMENT / "Dockerfile.extraction").read_text():
        raise ValueError("EXTRACTION: the conda target and runtime base disagree")
    records = json.loads((folder / "conda-packages.json").read_text())
    expected = "@EXPLICIT\n" + "".join(
        row["url"] + "#" + row["sha256"] + "\n"
        for row in sorted(records, key=lambda row: row["name"])
    )
    if (folder / "conda-linux-64.lock").read_text() != expected:
        raise ValueError("EXTRACTION: explicit conda lock does not match its package inventory")
    policy = json.loads((folder / "overlay-policy.json").read_text())
    provided = {
        line for line in (folder / "conda-provided.in").read_text().splitlines()
        if line and not line.startswith("#")
    }
    if provided != set(policy["conda_only"]):
        raise ValueError("EXTRACTION: conda-provided requirements and overlay policy disagree")
    names = {row["name"]: row["version"] for row in records}
    for name, entry in policy["conda_only"].items():
        if names.get(entry["conda_package"]) != entry["version"]:
            raise ValueError(f"EXTRACTION: missing conda-provided {name}")
    return report


def extraction_overlay_contract(folder):
    guard = runpy.run_path(str(ENVIRONMENT / "conda-overlay-check.py"))
    records = json.loads((folder / "conda-packages.json").read_text())
    policy = json.loads((folder / "overlay-policy.json").read_text())
    lines = (folder / "requirements.lock").read_text().splitlines()
    installed = guard["conda_distribution_versions"](records)
    selected = guard["select_requirements"](lines, installed, policy)
    shared = policy["shared_namespace"]
    if f"{shared['pip_distribution']}=={shared['pip_version']}" not in lines:
        raise ValueError("EXTRACTION: missing reviewed cv2 namespace overlay")
    return {"pip_overlay_requirements": len(selected),
            "same_version_conda_requirements": len(lines) - len(selected)}


def cpu_wheel(package, version, python):
    """Use a verified index URL and hash, not a guessed CPU wheel filename."""
    abi = "cp" + python.replace(".", "")
    with urllib.request.urlopen(f"https://download.pytorch.org/whl/cpu/{package}/") as response:
        urls = re.findall(r'href="([^"]+)"', response.read().decode())
    stem = f"{package}-{version.replace('+', '%2B')}-{abi}-{abi}-"
    matches = [url for url in urls if stem in url and
               re.search(r"(manylinux_[0-9_]+|linux)_x86_64\.whl#sha256=[0-9a-f]{64}$", url)]
    if len(matches) != 1:
        raise ValueError(f"{package} {version}: expected exactly one Linux {abi} CPU wheel")
    return f"{package} @ {matches[0]}"


def resolve(stages):
    failed = 0
    for stage in stages:
        folder = ENVIRONMENT / "stages" / stage.lower()
        status = {"dependency_inputs_sha256": dependency_hash(folder), "image_built": False}
        if stage == "DECROSSTALK_SPLIT":
            (folder / "requirements.lock").write_text("# Standard library only.\n")
            status.update(status="resolved", resolver="none; standard library only")
        else:
            command = [
                "uv", "pip", "compile", str(folder / "requirements.in"),
                "--constraint", str(folder / "observed.constraints"),
                "--build-constraints", str(folder / "build.constraints"),
                "--python-version", PYTHON[stage], "--python-platform", "x86_64-manylinux_2_28",
                "--no-header", "--no-annotate", "--no-strip-extras",
                "--output-file", str(folder / "requirements.lock"),
            ]
            if stage != "CLASSIFIER":
                command += ["--torch-backend", "cpu"]
            if (folder / "overrides.in").exists():
                command += ["--overrides", str(folder / "overrides.in")]
            if stage == "EXTRACTION":
                try:
                    extraction_conda_contract(folder)
                except (ValueError, OSError, KeyError) as error:
                    status.update(status="blocked", reason=str(error))
                    write_json(folder / "lock-status.json", status)
                    failed += 1
                    print(f"{stage}: blocked")
                    continue
                # Resolve the compatible PyPI OpenCV metadata, but do not emit or install it.
                # The real conda version 4.7.0 is separately locked and validated.
                provided = json.loads((folder / "overlay-policy.json").read_text())["conda_only"]
                constraints = folder / "pip.constraints"
                constraints.write_text("\n".join(
                    line for line in (folder / "observed.constraints").read_text().splitlines()
                    if canonical(line.split("==")[0]) not in provided
                ) + "\n")
                command[command.index("--constraint") + 1] = str(constraints)
                for name in sorted(provided):
                    command += ["--no-emit-package", name]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                # Keep resolver diagnostics local, but never credential-bearing URL userinfo.
                reason = re.sub(r"https://[^/\s]+@", "https://[REDACTED]@", result.stderr)
                status.update(status="blocked", reason=reason.strip())
            else:
                lock = folder / "requirements.lock"
                lines = lock.read_text().splitlines()
                for index, line in enumerate(lines):
                    if re.fullmatch(r"(torch|torchvision|torchaudio)==[^ ]+\+cpu", line):
                        package, version = line.split("==")
                        lines[index] = cpu_wheel(package, version, PYTHON[stage])
                lock.write_text("\n".join(lines) + "\n")
                status.update(status="resolved", resolver=subprocess.check_output(
                    ["uv", "--version"], text=True).strip())
                if stage == "EXTRACTION":
                    try:
                        status.update(extraction_overlay_contract(folder))
                    except ValueError as error:
                        status.update(status="blocked", reason=str(error))
        if status["status"] == "resolved":
            status["lock_sha256"] = hashlib.sha256((folder / "requirements.lock").read_bytes()).hexdigest()
        else:
            failed += 1
        write_json(folder / "lock-status.json", status)
        print(f"{stage}: {status['status']}")
    print(json.dumps({"candidate": len(stages), "processed": len(stages), "skipped": 0,
                      "failed": failed, "parse_failure": 0}))
    return bool(failed)


def preflight(stage):
    folder = ENVIRONMENT / "stages" / stage.lower()
    status = json.loads((folder / "lock-status.json").read_text())
    if status["status"] != "resolved":
        raise ValueError(f"{stage}: {status['reason']}")
    if status["dependency_inputs_sha256"] != dependency_hash(folder):
        raise ValueError(f"{stage}: dependency inputs changed; resolve and review the lock again")
    if status["lock_sha256"] != hashlib.sha256((folder / "requirements.lock").read_bytes()).hexdigest():
        raise ValueError(f"{stage}: lock changed without a successful resolution")
    if stage == "EXTRACTION":
        extraction_conda_contract(folder)
        extraction_overlay_contract(folder)
    return status


def build(args, rows):
    stages = selected(args.stages)
    if not re.fullmatch(r"candidate-[a-z0-9][a-z0-9_.-]{0,100}", args.tag):
        raise ValueError("Use a unique candidate-* tag, never a production tag")
    if args.publish:
        for stage in stages:
            if rows[stage]["visibility"] not in ("private", "internal"):
                raise ValueError(f"{stage}: publishing requires private or internal visibility")
            require_private_package(rows[stage]["image"], allow_missing=True)
    for stage in stages:
        preflight(stage)
    subprocess.run(["docker", "buildx", "version"], check=True)
    for stage in stages:
        row = rows[stage]
        output = ROOT / ".image-work" / args.tag / stage
        output.mkdir(parents=True, exist_ok=True)
        image = f"{row['image']}:{args.tag}"
        command = [
            "docker", "buildx", "build", str(ENVIRONMENT), "--platform", "linux/amd64",
            "--file", str(ENVIRONMENT / row["recipe"]), "--tag", image,
            "--build-arg", f"STAGE_DIR={stage.lower()}",
            "--build-arg", f"PYTHON_VERSION={row['python']}",
            "--metadata-file", str(output / "metadata.json"), "--provenance=false",
        ]
        source_token = (
            "IMAGE_SOURCE_TOKEN"
            if os.environ.get("IMAGE_SOURCE_TOKEN")
            else "SERVICE_TOKEN"
        )
        if os.environ.get(source_token):
            command += ["--secret", f"id=github_token,env={source_token}"]
        command += ["--push"] if args.publish else [
            "--output", f"type=oci,dest={output / 'image.tar'}"
        ]
        subprocess.run(command, check=True)
        if args.publish:
            require_private_package(row["image"])
        metadata = json.loads((output / "metadata.json").read_text())
        report = [sys.executable, str(ENVIRONMENT / "image-report.py"), "--image", image,
                  "--digest", metadata["containerimage.digest"], "--stage", stage,
                  "--output", str(output / "report.json")]
        report += ["--published"] if args.publish else ["--archive", str(output / "image.tar")]
        subprocess.run(report, check=True)
    print(json.dumps({"candidate": len(stages), "processed": len(stages),
                      "skipped": 0, "failed": 0, "parse_failure": 0}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture")
    capture_parser.add_argument("--repositories", type=Path, required=True)
    capture_parser.add_argument("--inventory", type=Path, required=True)
    capture_parser.add_argument("--log", type=Path, required=True)
    commands.add_parser("validate")
    matrix = commands.add_parser("matrix")
    matrix.add_argument("stages")
    resolver = commands.add_parser("resolve")
    resolver.add_argument("stages")
    ready = commands.add_parser("preflight")
    ready.add_argument("stage", choices=STAGES)
    private = commands.add_parser("private-check")
    private.add_argument("image")
    private.add_argument("--allow-missing", action="store_true")
    builder = commands.add_parser("build")
    builder.add_argument("stages")
    builder.add_argument("--tag", required=True)
    builder.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    if args.command == "capture":
        capture(args)
    elif args.command == "private-check":
        print(json.dumps({
            "image": args.image,
            "visibility": require_private_package(args.image, args.allow_missing),
        }))
    else:
        rows = validate()
        if args.command == "matrix":
            print(json.dumps({"include": [rows[stage] for stage in selected(args.stages)]}))
        elif args.command == "resolve":
            return resolve(selected(args.stages))
        elif args.command == "preflight":
            print(json.dumps(preflight(args.stage), sort_keys=True))
        elif args.command == "build":
            build(args, rows)
        else:
            print(json.dumps({"candidate": 11, "processed": 11, "skipped": 0,
                              "failed": 0, "parse_failure": 0}))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
