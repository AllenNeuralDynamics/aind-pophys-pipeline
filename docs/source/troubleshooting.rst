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

Nextflow 24.10.4 runs on Java 17 to 23. Install it, or load it with your cluster's module system, for
example ``module load java/jdk-21.0.3`` on the Allen Institute cluster.


``New files in WORKDIR ... get no permission bits``
---------------------------------------------------

Some network storage, such as ``/allen``, grants access only through an NFS4 ACL and gives new
files mode 000 (``ls -l`` shows ``----------+``). Such files are readable in place, but a copy on
local disk keeps the mode and loses the ACL, so a step that copies one, such as the library
install, fails with ``Permission denied``. Give the work directory an inherited owner entry, then
resubmit:

.. code-block:: bash

    nfs4_setfacl -R -a 'A:fd:OWNER@:rwaDdxtTnNcCoy' "$WORKDIR"

Do the same for ``RESULTS_PATH`` to give published files normal permissions.

A repository clone on such storage needs the same entry. Without it, files that git rewrites
lose their permission bits, and ``git pull`` stops with ``Your local changes to the following files
would be overwritten by merge`` although ``git diff`` shows only mode changes. From the clone:

.. code-block:: bash

    nfs4_setfacl -R -a 'A:fd:OWNER@:rwaDdxtTnNcCoy' .
    git config core.fileMode false
    git pull --ff-only


Steps stay pending with ``QOSMaxJobsPerUserLimit``
--------------------------------------------------

The partition's QOS limits how many jobs a user can run, and the head job already uses that
allowance. Cancel the head job and resubmit, with ``-resume``, on a partition without the limit
(see :doc:`deployments`).


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

The pipeline checks ``environment/images.json``, the container tag, ``images_custom.env`` and
``pipeline/process_versions.env`` (or ``process_versions_custom.env``) before running any step:

* ``Cannot determine container tag`` or ``Invalid container tag``: set ``--container_tag``, the
  ``CONTAINER_TAG`` environment variable, or ``PIPELINE_VERSION`` in ``pipeline/nextflow.config``.
* ``environment/images.json must list exactly all 11 stages``: the image list was edited; restore
  it.
* ``Unknown stages in images_custom.env``: use the step names from ``environment/images.json``.
* ``Missing process manifest keys`` or ``<STAGE>_LIBRARY_COMMIT must be a 40-character lowercase
  SHA``: the versions file must give every step a repository and a full commit hash. A
  ``process_versions_custom.env`` replaces the default file entirely, so it must list every step
  (see :doc:`customization`).


``pip check`` fails when a step starts
--------------------------------------

Each task installs its processing library without dependencies, then checks them against the
step's image. A failure means the library commit in ``process_versions.env`` needs a dependency
the image does not have. Re-lock and rebuild that step's image (see :doc:`customization`).
