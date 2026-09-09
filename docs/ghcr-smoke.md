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
