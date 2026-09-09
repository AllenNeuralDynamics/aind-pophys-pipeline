# Code Ocean GHCR pull probe

Use only the isolated development pipeline:
<https://codeocean.allenneuraldynamics.org/capsule/9120064/tree>
(`e4c03dcc-f43a-481c-ac55-257cfe538041`), linked to `proj21/multi-backend-refactor`.

Set the named pipeline parameter `ghcr_smoke_only=true` to run one small process
using the published splitter image by digest. The workflow returns before constructing
scientific input or model channels. It does not run splitting or any other processing
algorithm. Normal execution remains the default (`false`).

The process requests one CPU, 1 GB memory, ten minutes, and no task retries. It writes
only `ghcr-smoke.json`. Code Ocean may still stage pipeline-attached assets independently
of Nextflow; the probe does not detach them or change permissions.

Success requires exit code zero and the marker `probe=pophys-ghcr-pull-v1` in the
published JSON. The image reference in the process definition is the pull identity;
the JSON's digest is a declared marker, not an independent runtime digest measurement.
An authentication failure before startup establishes that registry access is not ready.
Do not respond by making internal code public or putting registry credentials in the
process script.

No API run is triggered by adding this file. Commit/push, confirm the linked branch,
then explicitly authorize the development-pipeline sync and probe submission.
Do not sync or submit the production or Project 19 baseline pipeline.

## Development probe update (2026-09-08)

The pipeline App Panel must declare `ghcr_smoke_only`; verify the resolved run
parameters immediately after submission. The initial API request omitted this
parameter from the resolved set and started normal processing instead.

The splitter package is now Public. Computation
`29dae2af-9852-478f-8378-9e13fd58d2d9` passed image pulling but failed before the
probe script because Nextflow's metrics wrapper requires `ps`. The updated splitter
recipe installs `procps` and checks `ps --version` during the build.

The replacement tag is `candidate-procps-20260908`. Its OCI index digest is
`sha256:df5dcbec7a6eeae88c9fbd820665293a551adfd3470825ea1ff6d6916c1c37d4`;
the smoke process pins its Linux amd64 manifest directly:
`sha256:c6ab7e57139ad47074aa15599f3a6d1aee41db05e1c2bdf8da21aebaf3e111b6`.
The original candidate archive inventory and normal processing image pins remain
unchanged. This replacement still requires a successful Code Ocean smoke run.

On an Apple Silicon host, inspect the index with explicit target-platform flags:

```bash
skopeo inspect --no-creds --override-os linux --override-arch amd64 \
  docker://ghcr.io/allenneuraldynamics/pophys-decrosstalk-split:candidate-procps-20260908
```
