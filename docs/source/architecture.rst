.. _architecture:

Pipeline Architecture
=====================

The pipeline is a single Nextflow DSL2 script, ``pipeline/main.nf``, that runs eleven steps, each in
its own container image. This page describes the components a run uses and how data moves between
them.

Architecture Components
-----------------------

Deployment Modes
~~~~~~~~~~~~~~~~

The pipeline main Nextflow script ``main.nf`` can be deployed to several different execution
environments, including Code Ocean, SLURM clusters, and local machines. Each environment has its
own configuration file, which sets the executor, the container runtime and the resources for each
step:

* ``nextflow.config``: Code Ocean, on AWS Batch
* ``nextflow_slurm.config``: SLURM, with Apptainer or Singularity, started by ``slurm_submit.sh``
* ``nextflow_local.config``: a single machine, with Docker, started by ``run_local.sh``

The steps, images and parameters are the same in every environment.

Infrastructure Components
~~~~~~~~~~~~~~~~~~~~~~~~~

**Container Registry**
   Eleven container images from the GitHub Container Registry (ghcr.io), one per step, named
   ``ghcr.io/allenneuraldynamics/pophys-<step>``. Each image holds the dependencies of its step's
   processing library for ``linux/amd64``. The classifier image includes a CUDA-enabled PyTorch;
   the other images are CPU-only. The images are public, so every backend pulls them without
   credentials.

**Processing Libraries**
   Each task clones its step's processing library from GitHub at a pinned commit, installs it into
   the image's environment without dependencies, and runs the library's ``run`` entry point.

**Model Files**
   The Classifier's ONNX soma and dendrite models and ROInet weights, the Cellpose weights used by
   Decrosstalk and Extraction, and the schemas staged into NWB packaging, read from the data folder
   (see :ref:`model-files`).

Data Flow
~~~~~~~~~

**Input**: The session given by ``ophys_mount_url``, read from S3 or from a directory, and the
model files, mounted in every task at ``/tmp/data``.

**Processing**: Every task runs in its own Nextflow work directory, with ``capsule/data``,
``capsule/results`` and ``capsule/scratch`` folders; its inputs are staged into ``capsule/data``.
The Converter runs once per session. Registration, Movie QC, Extraction, dF/F, Classifier and
Events run once per plane, and Decrosstalk once per coupled pair of a multiplane session. NWB
packaging and Metadata merge run once per session.

**Output**: Each step's results are published to the results directory under their relative
paths, so every plane has one folder holding all of its steps' outputs (see
:doc:`input_output`). Each step's ``processing.json`` and ``quality_control.json`` are also passed
to the Metadata merge step, which writes the run-level documents.

Version Control
~~~~~~~~~~~~~~~

Three sets of files pin every piece of code a run uses, ensuring reproducibility across pipeline
runs:

* ``pipeline/process_versions.env``: the processing library repository and commit of each step
* ``pipeline/images.env``: the image digest of each step
* ``environment/stages/<step>/requirements.lock``: the dependency versions built into each image

Pipeline releases are tagged from Conventional Commit messages (see :ref:`releases`).

Pipeline Steps Detailed Breakdown
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

1. **Converter** (`aind-pophys-converter-capsule <https://github.com/AllenNeuralDynamics/aind-pophys-converter-capsule>`_):
   Converts the raw ScanImage TIFFs into one HDF5 movie per plane, for S3 inputs.

2. **Registration** (`aind-ophys-motion-correction <https://github.com/AllenNeuralDynamics/aind-ophys-motion-correction>`_):
   Suite2p rigid and non-rigid motion correction of each plane.

3. **Movie QC** (`aind-ophys-movie-qc <https://github.com/AllenNeuralDynamics/aind-ophys-movie-qc>`_):
   Saturation, photon, epileptiform event and z-drift metrics for each registered movie.

4. **Pair Splitting** (`aind-ophys-decrosstalk-split-session-json <https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-split-session-json>`_):
   Groups the planes of a multiplane session into coupled pairs.

5. **Decrosstalk** (`aind-ophys-decrosstalk-roi-images <https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images>`_):
   Removes crosstalk between the two planes of each coupled pair.

6. **Extraction** (`aind-ophys-extraction <https://github.com/AllenNeuralDynamics/aind-ophys-extraction>`_):
   Cell detection and ROI and neuropil trace extraction.

7. **dF/F** (`aind-ophys-dff <https://github.com/AllenNeuralDynamics/aind-ophys-dff>`_):
   dF/F traces for every ROI.

8. **Classifier** (`aind-ophys-classifier <https://github.com/AllenNeuralDynamics/aind-ophys-classifier>`_):
   Soma, dendrite and border labels for every ROI, on a GPU.

9. **Events** (`aind-ophys-oasis-event-detection <https://github.com/AllenNeuralDynamics/aind-ophys-oasis-event-detection>`_):
   OASIS event detection on each dF/F trace.

10. **NWB Packaging** (`aind-ophys-nwb <https://github.com/AllenNeuralDynamics/aind-ophys-nwb>`_):
    One NWB Zarr store with every plane's masks, images and traces.

11. **Metadata Merge** (`aind-metadata-manager-capsule <https://github.com/AllenNeuralDynamics/aind-metadata-manager-capsule>`_):
    Run-level ``processing.json``, ``quality_control.json`` and ``data_description.json``.

Pair Splitting and Decrosstalk run only for multiplane sessions. See :doc:`pipeline_steps` for
more detailed information about each processing step.
