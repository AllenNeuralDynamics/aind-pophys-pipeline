# Step images

Each pipeline step runs in its own `linux/amd64` image. An image holds the dependencies of the
step's processing library, not the library itself: each task clones the library at the commit in
`pipeline/process_versions.env` and installs it with `--no-deps`, so a library change that keeps
its dependencies needs no rebuild.

| File | Purpose |
| --- | --- |
| `images.json` | Step name to Dockerfile, image name and Python version |
| `Dockerfile_python` | Image for every step except extraction |
| `Dockerfile_extraction` | Extraction image: a conda CaImAn environment plus a pip overlay |
| `stages/<step>/requirements.in` | The library's declared dependencies, written by `lock.py` |
| `stages/<step>/requirements.lock` | Resolved dependency versions built into the image |
| `stages/<step>/build.constraints` | Build tool and NumPy versions used to build wheels |
| `stages/extraction/conda-*`, `overlay-policy.json`, `overrides.in` | The extraction conda lock and the pip packages allowed to replace conda ones |
| `builder-requirements.txt` | pip, setuptools, setuptools-scm, packaging, tomli and wheel, used to build wheels; the setuptools, setuptools-scm, packaging and tomli pins are also installed in `/opt/build-tools`, which tasks use to install the processing library |
| `runtime-check.py` | Import checks run while building each image |
| `lock.py` | Writes `requirements.in` and resolves `requirements.lock` for one or more steps |
| `build_all.sh`, `push_all.sh` | Build images into the local Docker daemon, and push them |
| `resolve-extraction-conda.py`, `conda-overlay-check.py` | Resolve the extraction conda lock; check the pip overlay at build time |

## Re-lock after a dependency change

```bash
uv run --python 3.12 --no-project environment/lock.py DFF        # or: all
git diff environment/stages/dff/requirements.lock
```

`lock.py` reads the library repository and commit from `pipeline/process_versions_custom.env`
when it exists, otherwise from `pipeline/process_versions.env`. The resolver keeps the versions
already in the lock wherever the library's dependencies allow, and pins CPU PyTorch wheels by URL
and hash for every step except the classifier. To re-solve the extraction conda layer, run
`uv run --python 3.12 --no-project environment/resolve-extraction-conda.py --micromamba /path/to/micromamba`
before `lock.py EXTRACTION`.

## Build and push

```bash
environment/build_all.sh <tag> [main|dev] [STEP,STEP|all]
environment/push_all.sh <tag> [main|dev] [STEP,STEP|all]
```

`build_all.sh` loads each image into the local Docker daemon as
`$IMAGE_REGISTRY/<image_name>:<tag>` (default registry `ghcr.io/allenneuraldynamics`); `dev` appends
`-dev` to the tag. `push_all.sh` pushes them, and with `main` also tags them `latest`. Run every
step with one tag with `--container_tag <tag>`, or name individual images in
`pipeline/images_custom.env`.

In CI, pull requests and pushes into `dev` build every image with the `dev` tag, skipping a step
whose image already carries the same build-input hash (`.github/scripts/image_info.sh`). The release
pull request into `main` checks the `dev` images match its head, and after each release they are
promoted to the new version and `latest`.
