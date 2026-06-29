#!/bin/bash
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 4
#SBATCH --mem=16G
#SBATCH -p aind
#SBATCH -t 24:00:00
#SBATCH -o nf_%j.out
#SBATCH -e nf_%j.err

set -euo pipefail

# nextflow lives in ~/.local/bin; SLURM jobs don't inherit login PATH, so add it explicitly.
# container runtime resolved at task time, not here
export PATH="$HOME/.local/bin:$PATH"

export NXF_SINGULARITY_CACHEDIR=/allen/aind/scratch/ariellel/.singularity_cache
mkdir -p "$NXF_SINGULARITY_CACHEDIR"

# Keep Nextflow's scratch work dir off the SLURM/home filesystem (it fills up fast).
export NXF_WORK=/allen/aind/scratch/ariellel/nf_work
mkdir -p "$NXF_WORK"

RESULTS_DIR=/allen/aind/scratch/ariellel/results
mkdir -p "$RESULTS_DIR"

nextflow run pipeline/main.nf -profile hpc \
    --local_session_dir training-002 \
    --capsule_code_dir /allen/aind/scratch/ariellel/capsules \
    --slurm_partition aind \
    --acquisition_data_type single \
    --RESULTS_PATH "$RESULTS_DIR" \
    -resume
