#!/usr/bin/env bash
# Pulls every GHCR image referenced by profiles.{local,hpc} in pipeline/nextflow.config
# as Singularity .sif files into $CACHE_DIR.
#
# To make Nextflow reuse these without re-pulling, point it at the same dir:
#     export NXF_SINGULARITY_CACHEDIR=$PWD/singularity_cache
# (Nextflow names cached images by replacing ':' and '/' with '-'.)
#
# For private GHCR images, set GitHub PAT with read:packages first:
#     export SINGULARITY_DOCKER_USERNAME=<your-gh-username>
#     export SINGULARITY_DOCKER_PASSWORD=<your-gh-pat>
set -euo pipefail

CACHE_DIR="${NXF_SINGULARITY_CACHEDIR:-$PWD/singularity_cache}"
mkdir -p "$CACHE_DIR"

IMAGES=(
    ghcr.io/allenneuraldynamics/motion-correction:v5
    ghcr.io/allenneuraldynamics/ophys-movie-qc:v4
    ghcr.io/allenneuraldynamics/ophys-extraction:v4
    ghcr.io/allenneuraldynamics/ophys-roicat-classifier:v4
    ghcr.io/allenneuraldynamics/ophys-dff:v4
    ghcr.io/allenneuraldynamics/oasis-event-detection:v3
    ghcr.io/allenneuraldynamics/ophys-nwb-packaging:v2
    ghcr.io/allenneuraldynamics/metadata-manager:v2
    ghcr.io/allenneuraldynamics/ophys-quality-control-aggregator:v2
)

failed=()
for img in "${IMAGES[@]}"; do
    # Nextflow's cache filename: replace ':' and '/' with '-', append .img
    sif_name="$(echo "$img" | tr ':/' '--').img"
    sif_path="$CACHE_DIR/$sif_name"

    if [ -f "$sif_path" ]; then
        echo ">>> $img already cached at $sif_path"
        continue
    fi

    echo ">>> singularity pull $sif_path docker://$img"
    if ! singularity pull "$sif_path" "docker://$img"; then
        failed+=("$img")
        rm -f "$sif_path"
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "FAILED:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi

echo
echo "All ${#IMAGES[@]} images present in $CACHE_DIR"
echo "Set: export NXF_SINGULARITY_CACHEDIR=$CACHE_DIR"
