# Off-Code-Ocean image candidates

**Status (2026-09-08): all eleven candidates built locally for Linux amd64.**
`candidate-inventory.json` records the exact selected archive paths, tags, digests,
and sizes. Every referenced manifest, config and compressed layer was verified
against its SHA-256. The builds passed their embedded import checks; scientific
parity and actual GPU execution remain unverified. The splitter has been published
with an identical remote digest and user-confirmed Internal visibility; the other
ten remain local. No production pins have been promoted.
Candidates were built across successive recipe revisions, not one identical checkout.

Candidate packages may be **Private or Internal, never Public** (approved 2026-09-08).
Internal allows authenticated enterprise members; Sean explicitly accepted that
audience. Existing `private` entries in the image map remain the preferred setting,
not a prohibition on Internal packages. The pipeline repository is public, while
several installed AIND libraries are internal. GHCR creates packages on the first
push, with private visibility by default; there is no separate empty-package creation
step. Existing package visibility and access must be checked before uploading
internal code. Build-only runs do not publish packages.

## Exact-artifact publication preparation

Use the recorded OCI archives, not `candidates.py build --publish`, to publish this
specific candidate set. The latter rebuilds and can produce different bytes.
An OCI-aware copier such as Skopeo can retain the manifest and layer digests:

```bash
skopeo copy --preserve-digests \
  oci-archive:/absolute/path/to/image.tar \
  docker://ghcr.io/allenneuraldynamics/pophys-STAGE:candidate-TAG
```

Replace both references with the corresponding inventory entry, check package privacy
before copying, and verify remote digest and Private/Internal visibility afterward. Do not
enable format conversion or recompression. Failed or mismatching copies must not
update production pins. Publication has not been performed.

The currently active local GitHub CLI token lacks `write:packages`. Publication
requires a separate GHCR login with suitable package scopes and organization SSO
authorization; source-code read access alone is insufficient.

Regenerate the inventory with explicit build reports (one per stage):

```bash
uv run --python 3.12 --no-project environment/inventory.py \
  --output environment/candidate-inventory.json \
  --reports .image-work/<candidate>/<stage>/report.json ...
```

This reads and hashes archives without extracting or publishing them. It rejects
missing/duplicate stages, incorrect platforms, digest mismatches and incomplete reports.

`images.tsv` assigns **each of all eleven stages its own GHCR image**. Shared recipes do
not mean shared stage images. These are newly authored, pipeline-owned off-CO environments,
not edited capsule environments or copies of CO notebook images. `main.nf`, all CO image
references, model mounts, and production `*_IMAGE_OFFCO` slots are unchanged.

## Runtime choices and limitations

| Stage | Runtime | Scientific contract |
| --- | --- | --- |
| CONVERTER | Python 3.12 slim, CPU | aind-ophys-utils 0.0.8, ScanImage reader, selected TIFF/Pillow pins |
| MOTION_CORRECTION | Python 3.10 slim, CPU | suite2p 0.14.6, torch 2.13.0+cpu / torchvision 0.28.0+cpu |
| MOVIE_QC | Python 3.12 slim | oasis-deconv 0.2.0, numpy 2.2.6, scipy 1.15.3 |
| DECROSSTALK_SPLIT | Python 3.12 slim | Standard library only; no backing library |
| DECROSSTALK_ROI_IMAGES | Python 3.10 slim, CPU | suite2p 0.14.3, cellpose 2.2.3, numpy 1.26.4 |
| EXTRACTION | Micromamba 2.3.2, Python 3.10, CPU | CaImAn 1.10.3 from conda-forge, with an explicitly allowlisted pip overlay |
| DFF | Python 3.12 slim, CPU | aind-ophys-utils **0.1.0**, joblib 1.5.3 |
| OASIS | Python 3.12 slim | oasis-deconv 0.2.0, scipy 1.15.3 |
| CLASSIFIER | Python 3.12 slim, GPU | **roicat[all] 1.7.3**, torch 2.11.0, torchvision 0.26.0 |
| NWB | Python 3.12 slim | PyNWB 4.1, HDMF 6.1, HDMF-Zarr 0.13, aind-nwb-utils 0.2.8 |
| AGGREGATOR | Python 3.12 slim | manager 06ae879, schema **2.9.0**, models **6.2.0**, upgrader 0.17.12 |

All images retain bash, Git, certificates, and timing. The pipeline creates
`/data`, `/results`, and `/scratch` symlinks per task; the images deliberately
do not pre-create those paths.
All model weights remain external mounts. No Dockerfile starts a notebook server.
ROICaT's declared `[all]` extras themselves require Jupyter and numerous other packages;
these are deliberately retained, not silently removed to meet a size target.
Similarly, `oasis-deconv==0.2.0` declares Cython as a runtime requirement, so that
Python package is retained. The C/C++ compiler remains confined to the builder.
The classifier uses PyPI's CUDA-enabled torch and its CUDA 13 dependencies on a plain
Python base, avoiding a second preinstalled CUDA/PyTorch stack. Its pinned
`fused-local-corr==0.3.211` has a Linux x86_64 cp312 wheel. GPU driver compatibility and
actual scientific execution still require testing on the target GPU host.

**Images alone do not complete off-CO portability.** The splitter and aggregator
wrappers still clone from CO-internal Git. The splitter's algorithm and wrapper are not
copied or rewritten here. The aggregator's library provenance has been added without
changing `AGGREGATOR_CAPSULE_SOURCE_MODE=co_git`. Those two wrapper sources must be made
accessible separately before a full local/SLURM pipeline run can succeed.

## Dependency and processing-library layers

1. `stages/<stage>/source.json` records the full processing-library SHA, exact pinned
   pyproject checksum, declared requirements, Python contract, and capsule source identity.
2. `requirements.in` contains those declared dependencies, **not the processing library**.
   The abbreviated log-schema Git dependency is expanded to its verified full SHA.
   `observed.constraints` constrains only packages reached by resolution; it does not
   install an inherited CO base environment.
3. `requirements.lock` is a new Linux amd64 resolution. CPU torch wheel URLs and SHA-256
   hashes are verified against the official CPU index. Processing-library SHAs never
   enter the dependency cache key. `lock-status.json` detects stale inputs or edited locks.
4. Authenticated Git fetches happen in an isolated BuildKit step. Package build hooks
   never receive the GitHub token. The builder then makes dependency wheels, then
   independently fetches and verifies the
   processing library and builds **one noneditable wheel with `--no-deps`**.
   `build.constraints` pins isolated packaging tools and the observed NumPy/Cython
   versions where available, so compiled OASIS wheels use the selected NumPy ABI.
5. The final runtime installs dependency wheels from a BuildKit mount, then installs the
   processing-library wheel in the **last installation layer**. Compiler, wheelhouse,
   cloned sources, and builder virtual environment do not enter the final image.
   `pip check`, library identity/checksum checks, scientific imports, and small OASIS
   numerical smoke checks must pass inside the image. Inventory is retained in
   `/opt/image/packages.json`; processing provenance is under `/opt/image/`.

This is **not byte-identical historic reproduction**. Ranged requirements have been
resolved with observed versions where available, CPU wheel variants intentionally replace
CUDA torch for CPU candidates, and aggregation has no historical installed-package list.
The aggregator lock retains the baseline schema/model versions; its upgrader wheel was
inspected for `TYPE_MAPPING`, `UPGRADE_VERSIONS`, and `upgrade_mapping.MAPPING`.
Container builds additionally import those symbols. Except for extraction's verified
Micromamba digest, base-image tags and apt packages are not artifact/digest-locked yet. The dependency files pin
Python distribution versions and Git commits, not every wheel/sdist hash. Built-image
digests are the eventual immutable runtime identity.

The selected log was parsed in full: **9,664 candidate pip lines, 9,556 package rows,
108 headers/separators, zero failed or malformed rows**. All repeated tasks agreed
within each of the nine logged stages. `observed-packages.json` stores compact package
evidence, task counts and the source-log checksum, not bulk console output.

## Extraction's two installation layers

The successful selected CO build log corrected the initial blocker: the historical
environment **did replace some conda-installed distributions with pip wheels**.
Asking conda to solve the final pip versions of matplotlib and h5py together with
OpenCV 4.7 incorrectly combined two distinct installation phases.

The log identifies library `d5b8b8c`, capsule image `8e4ffe13e38690275e1273600f9e5cc7`,
180 conda transaction packages, and these five pip replacements:

| Distribution | Before pip | After pip |
| --- | --- | --- |
| h5py | 3.9.0 | 3.11.0 |
| matplotlib | 3.8.0 | 3.10.9 |
| python-json-logger | 2.0.7 | 4.1.0 |
| PyYAML | 6.0 | 6.0.3 |
| typing-extensions | 4.7.1 | 4.16.0 |

`overlay-policy.json` pins these exact pairs and the source-log SHA-256
`e96be5d44a02ad5a474fd5ec56d1bc2d4f509bdce7a372f4a2c2e845ad467747`.
The same build log directly resolves Suite2p to
`ae0e9313b881f1d4bb51d7461f4796532a76e8aa`, recorded in `overrides.in`.
No mutable branch is fetched when building the candidate.

`conda-spec.txt` now pins the actual pre-pip scientific builds: CaImAn 1.10.3,
NumPy 1.26.4, SciPy 1.14.1, OpenCV 4.7.0, h5py 3.9.0, matplotlib 3.8.0 and
scikit-image 0.24.0. Other conda/Python overlap pins retain the selected versions
without inventing additional pip replacements. A fresh, successful linux-64 solve
produces **419 explicit conda-forge artifact URLs with SHA-256 hashes**.
Micromamba's dry-run reader separately accepted all 419 SHA-256 references.
The base is pinned to its verified Linux amd64 image digest: Debian trixie/glibc
2.41, not an assumed older Ubuntu base. The solve uses Linux 5.15 as a target
kernel assumption; actual host compatibility remains untested.

CaImAn itself declares TensorFlow, Jupyter, IPython, notebook/widget and GUI-related
dependencies. They are included rather than silently dropped. A minimal new base
does not make this declared dependency closure small; image size is still unmeasured.
Conda archives are cached outside the final image layer and environment files are
copied, not linked back into the disposable package cache.

The pip lock resolves **85 requirements**, including the selected CPU torch
`2.4.0+cpu` candidate variant. Its OpenCV PyPI metadata is used only during resolution:
the unavailable-on-PyPI conda distribution `opencv-python==4.7.0` is separately
locked, checked, and never emitted for pip installation. `conda-provided.in` and
`overlay-policy.json` explicitly account for this requirement; the original
library's `opencv-python>=4.7,<4.8` declaration is unchanged.

The overlap check selects **47 pip requirements** and leaves **38 identical-version
conda distributions untouched**. It filters them before wheel construction and
again before installation: pip never receives their wheels. Only the five exact
replacement pairs above are allowed; an unknown replacement, unexpected source
version, missing protected distribution, PyPI CaImAn, or plain PyPI OpenCV fails
before installation. Build-time checks repeat this against actual installed
Python distribution metadata, not just inferred conda package names.

**Known namespace risk:** the historical pip step also installs
`opencv-python-headless==4.11.0.86` while conda's `opencv-python==4.7.0` remains
registered. Those distributions both own `cv2`; different distribution names do
not make this safe. The candidate explicitly reproduces that combination and
requires the built image to report effective `cv2.__version__ == "4.11.0"`.
This is a candidate assertion, not a measured historical import identity.
Any other effective version fails the image build. Even when imports and
`pip check` pass, ABI and scientific compatibility still need real extraction data
and model-mount tests. No candidate image has been built here.

Regenerate on a machine with Micromamba, then review both lock diffs:

```bash
uv run --python 3.12 --no-project environment/resolve-extraction-conda.py \
  --micromamba /path/to/micromamba
uv run --python 3.12 --no-project environment/candidates.py resolve EXTRACTION
uv run --python 3.12 --no-project environment/candidates.py preflight EXTRACTION
```

The resolver uses `--dry-run` and downloads metadata, not scientific package
payloads. `conda-solve.json` records the successful solve, target and input/output
checksums; `conda-packages.json` records every selected build. Preflight fails on
stale specs, mismatched locks, missing conda-provided requirements or an unapproved
overlay. No live solve or blanket overwrite fallback occurs during image creation.

## Manual GitHub Actions builds

After the user commits and pushes these files, use **Actions → Images → Run workflow**.
GitHub must know this workflow on the default branch before it is dispatchable; select
the desired committed feature ref when dispatching.

- `stages`: `DECROSSTALK_SPLIT` by default, any single stage, `DFF,OASIS`, or `all`.
  Unknown/duplicate selections fail. Maximum two concurrent jobs; `all` includes
  every stage and applies each stage's lock gate rather than silently omitting failures.
- `publish`: **false by default**. Build-only jobs have no `packages:write`; the
  separate explicit publication job grants it, rejects existing packages unless
  Private or Internal, and verifies visibility after publishing. A missing package
  may be created by the first push. It never edits the production manifest.
- If source repositories require authentication, the workflow passes the inherited
  `SERVICE_TOKEN` as a BuildKit secret. Source credentials are read by Git askpass,
  never build arguments, Docker ENV values, global Git configuration, or persisted files.
- The public repository does **not** export a GitHub Actions BuildKit cache. A
  `mode=max` cache could expose intermediate wheels containing internal library source
  to workflows with repository cache access. Layer ordering still preserves cache
  locality on a trusted/private builder; a private cache backend is a later task.
  arguments, Docker ENV values, global Git configuration, or persisted files.
- Candidate tags include pipeline commit, run ID and attempt. The candidate image
  itself remains unpromoted until a human validates its digest and updates the
  production manifest.
- Artifacts report the image digest, Linux amd64 manifest digest, compressed layer
  bytes, archive bytes for build-only output, and whether publication occurred.
  OCI archives are not uploaded as artifacts. Large classifier builds may require
  a larger-disk runner; size and memory requirements remain unmeasured.
  `image_built: false` in committed lock-status files describes lock-authoring time;
  a successful build report records `image_built: true` separately.
- No job edits the production manifest, dispatches a pipeline, or promotes candidates.
  After independent pull/import/data/GPU/model-mount validation, a human can review a
  separate change to `*_IMAGE_OFFCO=ghcr.io/...@sha256:...`.

Action pins are full official tag SHAs verified through GitHub's API on 2026-09-08.
The worker is a reusable workflow so build-only and publish paths share implementation
without granting write permission to build-only jobs.

## Local tooling (Python 3.12+, uv; Docker only for an actual build)

From the pipeline repository:

```bash
uv run --python 3.12 --no-project environment/candidates.py validate
uv run --python 3.12 --no-project environment/candidates.py matrix "DFF,OASIS"
uv run --python 3.12 --no-project environment/candidates.py preflight DFF
uv run --python 3.12 --no-project environment/candidates.py resolve "DFF,OASIS"
uv run --python 3.12 --no-project python -m unittest \
  tests.test_pipeline_contract tests.test_image_candidates
```

`resolve all` exits nonzero if any stage fails. A failed resolution cannot
reuse an old lock: preflight requires current successful status and matching hashes.
Do not treat lock regeneration as approval to change numerical dependencies.

Recapture source/dependency inputs only from pinned Git objects:

```bash
uv run --python 3.12 --no-project environment/candidates.py capture \
  --repositories /path/to/workspace/repositories \
  --inventory /path/to/selected-745be7a/inventory.json \
  --log /path/to/eea0f242-8983-43e2-a367-430f33c60969__output
```

On a future Docker/BuildKit host, use a unique candidate label. These commands have
**not** been executed here:

```bash
uv run --python 3.12 --no-project environment/candidates.py build \
  DECROSSTALK_SPLIT --tag candidate-my-first-build
# Explicit publication requires package write access and Private/Internal visibility:
uv run --python 3.12 --no-project environment/candidates.py build \
  "DFF,OASIS" --tag candidate-my-reviewed-build --publish
```

`build_all.sh` is a Python 3.12+ convenience wrapper; `push_all.sh` now refuses the old
unvalidated floating-tag push path. Local build artifacts go under ignored `.image-work/`.
