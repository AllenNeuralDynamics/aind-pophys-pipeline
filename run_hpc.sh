#!/bin/bash
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 1
#SBATCH --mem=2G
#SBATCH -p aind
#SBATCH -t 24:00:00
#SBATCH -o nf_%j.out
#SBATCH -e nf_%j.err

set -euo pipefail

module load nextflow singularity

export NXF_SINGULARITY_CACHEDIR=/allen/aind/scratch/ariellel/.singularity_cache
mkdir -p "$NXF_SINGULARITY_CACHEDIR"

nextflow run pipeline/main.nf -profile hpc \
    --local_session_dir training-002 \
    --capsule_code_dir /allen/aind/scratch/ariellel/capsules \
    --slurm_partition aind \
    --acquisition_data_type single \
    -until motion_correction
