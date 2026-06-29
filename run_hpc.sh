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

# load nextflow (and its Java dependency); container runtime resolved at task time, not here
module load nextflow

export NXF_SINGULARITY_CACHEDIR=/allen/aind/scratch/ariellel/.singularity_cache
mkdir -p "$NXF_SINGULARITY_CACHEDIR"

nextflow run pipeline/main.nf -profile hpc \
    --local_session_dir training-002 \
    --capsule_code_dir /allen/aind/scratch/ariellel/capsules \
    --slurm_partition aind \
    --acquisition_data_type single \
    -resume
