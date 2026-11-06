Introduction
============

The AIND Pophys Pipeline is a planar optical physiology analysis pipeline built with
`Nextflow <https://www.nextflow.io/>`_. It takes a two-photon imaging session from raw ScanImage
TIFF movies to motion-corrected movies, cell masks, fluorescence and dF/F traces, events, ROI
classifications and an NWB file, and records every step in
`aind-data-schema <https://aind-data-schema.readthedocs.io/en/latest/>`_ processing and quality
control metadata.

Key Concepts
------------

The pipeline processes a session through a series of discrete steps (for example registration,
extraction, dF/F and event detection; see :ref:`pipeline_steps` for more details).

Each step is a `Nextflow process <https://www.nextflow.io/docs/latest/process.html>`_ that runs
independently in a containerized environment. The code a step runs has two parts: a processing
library, installed in the step's container image, and a thin wrapper repository, cloned at a pinned
commit when the step starts. Images are pinned by digest in ``pipeline/images.env`` and wrapper
commits in ``pipeline/process_versions.env``. The combination of pinned images and pinned code
for each step **ensures full reproducibility**.

``Nextflow`` orchestrates the pipeline, managing the flow of data between processes and ensuring
that each step is executed in the correct order. It also runs the per-plane steps in parallel:
registration, movie QC, extraction, dF/F, classification and event detection run as one task per
imaging plane, and decrosstalk runs as one task per coupled plane pair.

.. note::

    With **parallel** we do not mean using parallel processes/threads on the same machine, but
    rather running multiple independent *nodes* (e.g., on a cluster or on a cloud batch) in
    parallel.

For example, a multiplane session with 8 imaging planes in 4 coupled pairs runs 8 registration
tasks, 4 decrosstalk tasks, and 8 tasks for each of extraction, dF/F, classification and event
detection.

Key Features
------------

- Single-plane (Bergamo) and multiplane (mesoscope) sessions
- Parallel processing per imaging plane
- Suite2p rigid and non-rigid motion correction
- Crosstalk removal between coupled multiplane planes
- Cell detection with Cellpose, Suite2p or CaImAn, with neuropil correction
- dF/F, OASIS event detection and soma/dendrite ROI classification
- Standardized NWB output
- Processing and quality control metadata for every step, merged per run
- Container-based deployment
- Support for multiple platforms (Code Ocean, SLURM, local)

The pipeline is designed to be modular and flexible, allowing for deployment across various
platforms while maintaining consistent processing standards and output formats.
