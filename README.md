# AIND Pophys Pipeline
## aind-pophys-pipeline

Planar optical physiology analysis pipeline for single-plane and multiplane two-photon imaging data, built on [Nextflow](https://www.nextflow.io/).


# Overview

The pipeline takes an imaging session from raw ScanImage TIFF movies to registered movies, cell masks, dF/F traces, events, ROI classifications and an NWB file, and records every step in [aind-data-schema](https://github.com/AllenNeuralDynamics/aind-data-schema) processing and quality control metadata.

**Key Points:**
- **Single Pipeline**: [`main.nf`](pipeline/main.nf) runs on Code Ocean (AWS Batch), SLURM and local machines; `nextflow.config`, `nextflow_slurm.config` and `nextflow_local.config` select the backend
- **11 Processing Steps**:
  - *1*. Converter
  - *2-3*. Registration → Movie QC
  - *4-5*. Pair splitting → Decrosstalk (multiplane only)
  - *6-9*. Extraction → dF/F and Classifier → Events
  - *10-11*. NWB packaging → Metadata merge
- **Infrastructure**: 11 container images from [GHCR](https://github.com/orgs/AllenNeuralDynamics/packages), pinned by digest in [`images.env`](pipeline/images.env)
- **Parallelization**: Steps run in parallel per imaging plane, and decrosstalk per coupled plane pair; each step's code is version controlled via [`process_versions.env`](pipeline/process_versions.env)


# Documentation

The documentation is available at [ReadTheDocs](https://aind-pophys-pipeline.readthedocs.io/en/latest/).
