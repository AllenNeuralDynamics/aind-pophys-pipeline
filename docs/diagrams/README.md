# Workflow previews

Generated from the actual `pipeline/main.nf` using Nextflow 24.10.4 `-preview`.
Single-plane selects nine processes; multiplane selects eleven, including the
splitter and decrosstalk. No processing tasks execute. Placeholder paths are isolated
under `.image-work/diagrams/preview`; no scientific data or cloud mounts are used.

The raw `.mmd` files retain channel/operator nodes. `.display.mmd` files change only
process labels. nf-metro 2.0.0 simplifies channel plumbing when rendering SVGs.
Edges include both scientific inputs and metadata dependencies; these are process
graphs, not per-plane task traces or all-branches control-flow diagrams.
`provenance.json` records the source hash and generator versions.

With Java 17+ and uv available, run from the pipeline repository:

```bash
mkdir -p .image-work/diagrams
curl -fL https://github.com/nextflow-io/nextflow/releases/download/v24.10.4/nextflow-24.10.4-dist \
  -o .image-work/diagrams/nextflow
chmod +x .image-work/diagrams/nextflow
uv run --python 3.12 --no-project scripts/render-diagrams.py \
  --nextflow .image-work/diagrams/nextflow
```

Optionally pass `--docs-output /path/to/aind-software-docs/docs/source/_static/pophys`
to refresh the embedded documentation copies.
