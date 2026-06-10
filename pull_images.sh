#!/usr/bin/env bash
# Pulls every GHCR image referenced by profiles.{local,hpc} in pipeline/nextflow.config.
# Requires `docker login ghcr.io` first (see GH PAT with read:packages scope).
set -euo pipefail

IMAGES=(
    ghcr.io/allenneuraldynamics/motion-correction:v4
    ghcr.io/allenneuraldynamics/ophys-movie-qc:v2
    ghcr.io/allenneuraldynamics/ophys-extraction:v2
    ghcr.io/allenneuraldynamics/ophys-roicat-classifier:v2
    ghcr.io/allenneuraldynamics/ophys-dff:v2
    ghcr.io/allenneuraldynamics/oasis-event-detection:v1
    ghcr.io/allenneuraldynamics/ophys-nwb-packaging:v2
    ghcr.io/allenneuraldynamics/metadata-manager:v2
    ghcr.io/allenneuraldynamics/ophys-quality-control-aggregator:v2
)

failed=()
for img in "${IMAGES[@]}"; do
    echo ">>> docker pull $img"
    if ! docker pull "$img"; then
        failed+=("$img")
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "FAILED:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi

echo
echo "All ${#IMAGES[@]} images pulled."
