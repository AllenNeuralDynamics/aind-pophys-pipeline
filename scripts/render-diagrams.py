"""Generate parameter-specific preview DAGs without executing processing tasks."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEXTFLOW_VERSION = "24.10.4"
RENDERER = "nf-metro==2.0.0"
LABELS = {
    "converter_capsule": "Converter",
    "motion_correction": "Registration",
    "movie_qc": "Movie QC",
    "decrosstalk_split_json": "Pair splitting",
    "decrosstalk_roi_images": "Decrosstalk",
    "extraction": "Extraction",
    "dff_capsule": "dF/F",
    "oasis_event_detection": "Events",
    "classifier": "Classifier",
    "ophys_nwb": "NWB packaging",
    "pipeline_processing_metadata_aggregator": "Metadata merge",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nextflow", type=Path, required=True)
    parser.add_argument("--docs-output", type=Path, help="Copy SVGs and provenance into the software docs")
    args = parser.parse_args()
    runtime = args.nextflow.resolve()
    scratch = ROOT / ".image-work/diagrams/preview"
    output = ROOT / "docs/diagrams"
    scratch.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    environment = {
        **os.environ,
        "NXF_HOME": str(ROOT / ".image-work/diagrams/nxf-home"),
        "NXF_OFFLINE": "true",
        "NXF_ANSI_LOG": "false",
        "NXF_DISABLE_CHECK_LATEST": "true",
    }
    version = subprocess.check_output([str(runtime), "-version"], env=environment, text=True)
    if f"version {NEXTFLOW_VERSION} " not in version:
        raise ValueError(f"Use Nextflow {NEXTFLOW_VERSION}")
    source = ROOT / "pipeline/main.nf"
    counts = {}
    for mode, expected in (("single", 9), ("multiplane", 11)):
        case = scratch / mode
        pipeline = case / "pipeline"
        data = case / "data"
        pipeline.mkdir(parents=True, exist_ok=True)
        for filename in ("main.nf", "capsule_versions.env"):
            shutil.copyfile(ROOT / "pipeline" / filename, pipeline / filename)
        for mount in ("schemas", "2p_roi_classifier", "cellpose_models", "roinet", "raw/pophys"):
            folder = data / mount
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "placeholder").touch()
        (data / "raw/session.json").write_text("{}\n")
        params = json.loads((ROOT / "pipeline_parameters.json").read_text())
        params.update(acquisition_data_type=mode, ophys_mount_url=str(data / "raw"))
        (case / "params.json").write_text(json.dumps(params))
        config = case / "preview.config"
        config.write_text(
            "params.backend = 'codeocean'\nprocess.executor = 'local'\n"
            "docker.enabled = false\ndag.overwrite = true\n"
        )
        raw = output / f"{mode}.mmd"
        command = [
            str(runtime), "-C", str(config), "run", str(pipeline / "main.nf"),
            "-preview", "-params-file", str(case / "params.json"), "-with-dag", str(raw),
        ]
        with (case / "preview.log").open("w") as log:
            subprocess.run(command, cwd=case, env={
                **environment, "RESULTS_PATH": str(case / "results"),
                "REGISTRY_HOST": "registry.codeocean.allenneuraldynamics.org",
            }, stdout=log, stderr=subprocess.STDOUT, check=True)
        text = raw.read_text()
        count = sum(text.count(f'([{name}])') + text.count(f'(["{name}"])') for name in LABELS)
        if count != expected:
            raise ValueError(f"{mode}: expected {expected} process nodes, found {count}")
        counts[mode] = count
        display = text
        for name, label in LABELS.items():
            display = display.replace(f'([{name}])', f'(["{label}"])')
            display = display.replace(f'(["{name}"])', f'(["{label}"])')
        labeled = output / f"{mode}.display.mmd"
        labeled.write_text(display)
        subprocess.run([
            "uvx", "--from", RENDERER, "nf-metro", "render", str(labeled),
            "--from-nextflow", "--theme", "seqera", "--mode", "light",
            "--title", f"Pophys: {mode} preview", "-o", str(output / f"{mode}.svg"),
        ], check=True)
    (output / "provenance.json").write_text(json.dumps({
        "nextflow": NEXTFLOW_VERSION, "renderer": RENDERER,
        "main_nf_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "source_commit": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        "process_counts": counts, "processing_tasks_executed": False,
        "inputs": "Local placeholder paths, no scientific data or cloud mounts.",
        "scope": "Parameter-selected process graphs; metro rendering simplifies channel operators.",
    }, indent=2) + "\n")
    if args.docs_output:
        args.docs_output.mkdir(parents=True, exist_ok=True)
        for filename in ("single.svg", "multiplane.svg", "provenance.json"):
            shutil.copyfile(output / filename, args.docs_output / filename)
    print(json.dumps({"candidate": 2, "processed": 2, "skipped": 0, "failed": 0, "processes": counts}))


if __name__ == "__main__":
    main()
