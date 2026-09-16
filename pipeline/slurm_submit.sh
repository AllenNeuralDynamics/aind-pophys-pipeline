#!/usr/bin/env bash
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=8GB
#SBATCH --partition=CHANGE_ME
#SBATCH --time=2:00:00

set -e

pipeline_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
nextflow_bin="${NEXTFLOW_BIN:-nextflow}"
data_path="${DATA_PATH:-${pipeline_path}/../data}"
results_path="${RESULTS_PATH:-${pipeline_path}/../results}"
workdir="${WORKDIR:-${pipeline_path}/../work}"
params_file="${PARAMS_FILE:-${pipeline_path}/../pipeline_parameters.json}"
source_path="${OPHYS_MOUNT_URL:-${data_path}}"
image_set="${IMAGE_SET:-development-ghcr}"
default_queue="${DEFAULT_QUEUE:-CHANGE_ME}"

export DATA_PATH="$data_path"
export RESULTS_PATH="$results_path"
export WORKDIR="$workdir"
export PARAMS_FILE="$params_file"
export OPHYS_MOUNT_URL="$source_path"
export IMAGE_SET="$image_set"

"${pipeline_path}/preflight.sh" slurm

nextflow_args=(
    -C "${pipeline_path}/nextflow_slurm.config"
    -log "${results_path}/nextflow/nextflow.log"
    run "${pipeline_path}/main.nf"
    -work-dir "$workdir"
    --params_file "$params_file"
    --ophys_mount_url "$source_path"
    --image_set "$image_set"
    --default_queue "$default_queue"
)
if [ -n "${GPU_QUEUE:-}" ]; then
    nextflow_args+=(--gpu_queue "$GPU_QUEUE")
fi

exec "$nextflow_bin" "${nextflow_args[@]}" "$@"
