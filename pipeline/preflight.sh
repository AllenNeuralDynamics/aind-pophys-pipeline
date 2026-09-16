#!/usr/bin/env bash
set -e

mode="${1:-local}"
pipeline_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
nextflow_bin="${NEXTFLOW_BIN:-nextflow}"
data_path="${DATA_PATH:-${pipeline_path}/../data}"
results_path="${RESULTS_PATH:-${pipeline_path}/../results}"
workdir="${WORKDIR:-${pipeline_path}/../work}"
params_file="${PARAMS_FILE:-${pipeline_path}/../pipeline_parameters.json}"
source_path="${OPHYS_MOUNT_URL:-${data_path}}"
image_set="${IMAGE_SET:-development-ghcr}"

if [ "$mode" != "local" ] && [ "$mode" != "slurm" ]; then
    echo "usage: $0 local|slurm" >&2
    exit 2
fi

if ! command -v "$nextflow_bin" >/dev/null 2>&1; then
    echo "Nextflow executable not found: ${nextflow_bin}" >&2
    exit 1
fi

java_major="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -z "$java_major" ] || [ "$java_major" -lt 17 ]; then
    echo "Java 17 or newer is required by Nextflow" >&2
    exit 1
fi

if [ "$mode" = "local" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker executable not found" >&2
        exit 1
    fi
else
    if ! command -v apptainer >/dev/null 2>&1 &&
        ! command -v singularity >/dev/null 2>&1; then
        echo "Apptainer or Singularity executable not found" >&2
        exit 1
    fi
    if [ "${DEFAULT_QUEUE:-CHANGE_ME}" = "CHANGE_ME" ]; then
        echo "Set DEFAULT_QUEUE before a SLURM run" >&2
        exit 1
    fi
fi

if [ ! -d "$data_path" ]; then
    echo "DATA_PATH directory not found: ${data_path}" >&2
    exit 1
fi
if [ ! -f "$params_file" ]; then
    echo "Parameter file not found: ${params_file}" >&2
    exit 1
fi
if [ "$image_set" != "default" ] && [ "$image_set" != "development-ghcr" ]; then
    echo "IMAGE_SET must be default or development-ghcr" >&2
    exit 1
fi
if [ "$mode" != "codeocean" ] && [ "$image_set" = "default" ]; then
    echo "Off-CO runs require IMAGE_SET=development-ghcr until promoted images exist" >&2
    exit 1
fi
if [[ "$source_path" != s3://* ]] && [ ! -d "$source_path" ]; then
    echo "OPHYS_MOUNT_URL directory not found: ${source_path}" >&2
    exit 1
fi
if [ ! -f "${pipeline_path}/development_images.env" ]; then
    echo "Development image manifest not found" >&2
    exit 1
fi

mkdir -p "${results_path}/nextflow" "$workdir"
