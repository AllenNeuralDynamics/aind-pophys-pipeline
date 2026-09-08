# Off-Code-Ocean container images (GHCR)

These images give the pipeline a runtime environment on **local Docker** and **SLURM**
(Apptainer/Singularity), using the installer definitions pinned by the selected Code Ocean baseline. `main.nf` selects
`*_IMAGE_OFFCO` from `pipeline/capsule_versions.env` when `params.backend` is `local` or `slurm`;
those manifest slots stay empty until an image here is built, pushed, and its `ghcr.io/...` ref
pasted back in.

## How each Dockerfile is derived (the transform)

One image per stage, derived from that capsule's own `environment/Dockerfile` at the
manifest-pinned commit. This reproduces the build recipe, not necessarily its historical
resolved environment: ranged dependencies and mutable Git refs still need locking. Get the source with:

```bash
git show <CAPSULE_COMMIT>:environment/Dockerfile   # in the capsule's repo
```

Then apply two changes and nothing else:

1. `FROM $REGISTRY_HOST/codeocean/<base>` → keep `ARG REGISTRY_HOST=registry.codeocean.com`
   (Code Ocean's **public** base registry; anonymously pullable — verified for mambaforge3 and
   pytorch bases).
2. Drop CO's credential plumbing — `ARG GIT_ASKPASS`, `COPY git-ask-pass /`, and any
   `--mount=type=secret,id=git-access-token` / `GIT_ACCESS_TOKEN=$(...)` wrapper. Every git install
   in these capsules is a **public** repo, so no token is needed off-CO. (If a future capsule pulls
   a private repo, that stage needs a build secret instead.)

Keep all mamba/pip pins verbatim.

## Base-registry caveat

The selected `745be7a` baseline uses mambaforge Python 3.10/3.12 and PyTorch Python 3.12
bases across all nine GitHub-backed stages. The older Jupyterlab/Python-3.9 fallback
problem no longer applies. Public-base availability is not proof that the stage image
has been built or published; only the extraction recipe exists here so far.

## Build & push

`images.tsv` is the build map (stage, dockerfile, ghcr repo, tag, base_public). Adding a stage =
author `Dockerfile.<name>` + uncomment its row.

```bash
cd environment
./build_all.sh                 # or: ./build_all.sh EXTRACTION
docker login ghcr.io           # GitHub PAT / Actions token with packages:write
./push_all.sh                  # prints the *_IMAGE_OFFCO line to paste into the manifest
```

Tag = the capsule's pinned short commit SHA, a human-readable per-image label. Tags can
be overwritten; immutable production runtime identity requires the resulting image digest.

## Later: CI

A GitHub Actions workflow can build+push on the pinned SHAs and record the resulting digest,
replacing the manual run above and closing the floating-tag gap. Not required for first parity.
