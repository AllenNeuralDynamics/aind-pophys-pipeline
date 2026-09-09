"""Generate parameter-specific preview DAGs without executing processing tasks."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEXTFLOW_VERSION = "24.10.4"
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


def process_graph(text):
    """Collapse operator paths, stopping at each intervening process."""
    nodes = dict(re.findall(r'^\s*(v\d+)\(\["?([^"\]]+)"?\]\)', text, re.MULTILINE))
    if not nodes or set(nodes.values()) - set(LABELS):
        raise ValueError("Unexpected process nodes in Nextflow DAG")
    adjacency = {}
    for source, target in re.findall(r"^\s*(v\d+)\s+-->\s+(v\d+)\s*$", text, re.MULTILINE):
        adjacency.setdefault(source, set()).add(target)
    edges = set()
    for source in nodes:
        pending = list(adjacency.get(source, ()))
        visited = set()
        while pending:
            target = pending.pop()
            if target in visited:
                continue
            visited.add(target)
            if target in nodes:
                if target != source:
                    edges.add((nodes[source], nodes[target]))
            else:
                pending.extend(adjacency.get(target, ()))
    return set(nodes.values()), edges


def waterfall(text, mode):
    """Render explicit process dependencies, without merging routes."""
    nodes, edges = process_graph(text)
    lines = [
        "digraph pophys {",
        'graph [rankdir=TB, bgcolor="white", pad=0.3, nodesep=0.55, ranksep=0.55, '
        'splines=polyline, outputorder=edgesfirst, fontname="Helvetica", fontsize=20, '
        f'label="Pophys: {mode}", labelloc=t];',
        'node [shape=box, style="rounded,filled", fillcolor="#edf5fc", color="#3973a3", '
        'fontname="Helvetica", fontsize=13, margin="0.18,0.13"];',
        'edge [color="#527a99", arrowsize=0.7, penwidth=1.3, fontname="Helvetica", fontsize=10];',
    ]
    for node in LABELS:
        if node in nodes:
            label = LABELS[node]
            if node == "decrosstalk_roi_images":
                label += "\\nRequires pair definitions + movies"
            lines.append(f'{node} [label="{label}"];')
    lines.append("{rank=same; classifier; dff_capsule;}")
    for source, target in sorted(edges):
        style = ""
        if target == "pipeline_processing_metadata_aggregator":
            weight = 8 if source == "ophys_nwb" else 0
            style = f' [color="#9aa5b1", style=dashed, penwidth=1, weight={weight}]'
        elif (source, target) == ("decrosstalk_split_json", "decrosstalk_roi_images"):
            style = ' [color="#185e37", penwidth=2.2, label="pair definitions"]'
        lines.append(f"{source} -> {target}{style};")
    lines.extend([
        'legend [shape=plain, fillcolor="white", fontcolor="#53616d", fontsize=11, '
        'label="Arrows are inputs, not alternative routes.\\n'
        'Dashed arrows: metadata/QC aggregation.\\n'
        'External inputs and channel operators omitted."];',
        "pipeline_processing_metadata_aggregator -> legend [style=invis];",
        "}",
    ])
    return "\n".join(lines) + "\n", nodes, edges


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
    renderer_version = subprocess.check_output(["dot", "-V"], stderr=subprocess.STDOUT, text=True).strip()
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
        dot_source, nodes, edges = waterfall(text, mode)
        if len(nodes) != expected:
            raise ValueError(f"{mode}: collapsed process count differs")
        if mode == "multiplane" and (
            "decrosstalk_split_json", "decrosstalk_roi_images"
        ) not in edges:
            raise ValueError("Missing required splitter-to-decrosstalk edge")
        dotfile = output / f"{mode}.dot"
        dotfile.write_text(dot_source)
        subprocess.run(["dot", "-Tsvg", str(dotfile), "-o", str(output / f"{mode}.svg")], check=True)
    (output / "provenance.json").write_text(json.dumps({
        "nextflow": NEXTFLOW_VERSION, "renderer": renderer_version,
        "main_nf_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "source_commit": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        "process_counts": counts, "processing_tasks_executed": False,
        "inputs": "Local placeholder paths, no scientific data or cloud mounts.",
        "scope": "Top-down process dependencies; operator paths collapsed without removing process edges.",
    }, indent=2) + "\n")
    if args.docs_output:
        args.docs_output.mkdir(parents=True, exist_ok=True)
        for filename in ("single.svg", "multiplane.svg", "provenance.json"):
            shutil.copyfile(output / filename, args.docs_output / filename)
    print(json.dumps({"candidate": 2, "processed": 2, "skipped": 0, "failed": 0, "processes": counts}))


if __name__ == "__main__":
    main()
