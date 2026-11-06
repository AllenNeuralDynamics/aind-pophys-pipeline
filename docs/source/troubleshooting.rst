.. _troubleshooting:

Troubleshooting
===============

This section provides solutions to common issues encountered while using the AIND Pophys
Pipeline. If you encounter a problem not listed here, please consider opening an issue on our
GitHub repository.


``Set PIPELINE_PATH to the repository's pipeline/ directory``
-------------------------------------------------------------

``sbatch`` runs a copy of ``slurm_submit.sh`` from SLURM's spool directory, so the script cannot
find ``main.nf`` next to itself. Export ``PIPELINE_PATH`` before submitting:

.. code-block:: bash

    export PIPELINE_PATH=/path/to/aind-pophys-pipeline/pipeline


``Set DEFAULT_QUEUE before a SLURM run``
----------------------------------------

``preflight.sh`` stops a SLURM run that has no partition for its steps. Export ``DEFAULT_QUEUE``,
and ``GPU_QUEUE`` when the GPUs are in a different partition (see :doc:`deployments`).


``Java 17 or newer is required by Nextflow``
--------------------------------------------

Nextflow needs Java 17 or newer. Install it, or load it with your cluster's module system, for
example ``module load java/jdk-21.0.3`` on the Allen Institute cluster.


``Unable to load AWS credentials from any provider in the chain``
-----------------------------------------------------------------

Nextflow reads S3 inputs with AWS credentials. For a public bucket, such as
``s3://aind-open-data``, set ``S3_ANONYMOUS=true`` to read it without credentials. For a private
bucket, configure AWS credentials for the user that runs Nextflow.


Apptainer image conversion fails with ``unpriv.lremovexattr``
-------------------------------------------------------------

Apptainer converts each image to a SIF file in ``APPTAINER_TMPDIR``, and fails when that directory
is on a filesystem that rejects extended-attribute changes, such as ``/allen``. Point
``APPTAINER_TMPDIR`` at node-local storage inside the job. ``$SLURM_JOB_ID`` only exists inside the
job, so set it in the submitted command:

.. code-block:: bash

    sbatch <options> --wrap 'export APPTAINER_TMPDIR=/scratch/fast/$SLURM_JOB_ID && mkdir -p "$APPTAINER_TMPDIR" && exec bash "$PIPELINE_PATH/slurm_submit.sh"'

Keep ``NXF_APPTAINER_CACHEDIR`` on shared storage, so each image is pulled only once.


Classifier fails with ``no kernel image is available for execution on the device``
----------------------------------------------------------------------------------

The classifier image uses a CUDA 13 runtime, which supports NVIDIA GPUs of the Turing generation
or newer. On a SLURM cluster, a generic ``--gres=gpu:1`` request can land on an older GPU; request a
supported model with ``GPU_CLUSTER_OPTIONS``, for example:

.. code-block:: bash

    export GPU_CLUSTER_OPTIONS='--gres=gpu:a100:1'


``OSError: Unable to synchronously open file``
----------------------------------------------

This error can occur when HDF5 files are opened on a filesystem that does not support file
locking, such as NFS on many SLURM clusters. Set the environment variable
``HDF5_USE_FILE_LOCKING`` to ``FALSE``. It is in the Apptainer ``envWhitelist`` of
``nextflow_slurm.config``, so the tasks receive it when it is set in the head job.


Image or version manifest errors
--------------------------------

The pipeline checks ``pipeline/images.env`` and ``pipeline/process_versions.env`` (or
``process_versions_custom.env``) before running any step:

* ``Image manifest must contain exactly all 11 stages`` or
  ``Image for <STAGE> must be GHCR digest-pinned``: ``images.env`` must list one
  ``ghcr.io/allenneuraldynamics/pophys-*@sha256:<digest>`` image for every step.
* ``Missing process manifest keys`` or ``<STAGE>_CAPSULE_COMMIT must be a 40-character lowercase
  SHA``: the versions file must give every step a repository and a full commit hash. A
  ``process_versions_custom.env`` replaces the default file entirely, so it must list every step
  (see :doc:`customization`).
