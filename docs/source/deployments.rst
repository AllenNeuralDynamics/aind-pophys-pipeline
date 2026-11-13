Deployment Options
==================

The pipeline can be deployed in several environments. Every environment runs the same
``pipeline/main.nf`` with the same container images; a Nextflow configuration file selects the
backend:

* ``nextflow.config``: Code Ocean (AWS Batch)
* ``nextflow_slurm.config``: SLURM clusters, with Apptainer or Singularity
* ``nextflow_local.config``: a single machine, with Docker


SLURM Deployment
----------------

Deploying on a SLURM cluster runs each step as its own SLURM job, so the per-plane steps run in
parallel across nodes.

Requirements
~~~~~~~~~~~~
See the :doc:`installation` page for detailed setup instructions.

Configuration
~~~~~~~~~~~~~

1. Clone the repository:

   .. code-block:: bash

      git clone https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
      cd aind-pophys-pipeline
      cd pipeline

2. Set the run's environment variables in your shell. ``sbatch`` passes them to the head job, where
   ``slurm_submit.sh`` and ``nextflow_slurm.config`` read them. Paths must be absolute:

.. list-table::
   :header-rows: 1
   :widths: 25 25 50

   * - Variable
     - Default
     - Description
   * - ``PIPELINE_PATH``
     - none (required)
     - Absolute path of the repository's ``pipeline/`` directory. ``sbatch`` runs a copy of
       ``slurm_submit.sh``, so the script cannot locate the repository by itself.
   * - ``DEFAULT_QUEUE``
     - none (required)
     - Partition for every step's job.
   * - ``GPU_QUEUE``
     - ``DEFAULT_QUEUE``
     - Partition for the classifier job, when GPUs are in a different partition.
   * - ``GPU_CLUSTER_OPTIONS``
     - ``--gres=gpu:1``
     - SLURM options for the classifier job. Request a GPU model of the Turing generation or
       newer, for example ``--gres=gpu:a100:1``.
   * - ``OPHYS_MOUNT_URL``
     - none (required)
     - The session to process: an S3 URL or an absolute directory (see :doc:`input_output`).
       Nextflow copies an S3 session in full into ``WORKDIR`` before the first step starts.
   * - ``PARAMS_FILE``
     - ``pipeline_parameters.json`` at the repository root
     - The parameter file (see :doc:`parameters`).
   * - ``DATA_PATH``
     - ``data/`` at the repository root
     - The model files folder, mounted in every task at ``/tmp/data`` (see :ref:`model-files`).
   * - ``RESULTS_PATH``
     - ``results/`` at the repository root
     - Where results and the Nextflow reports are published.
   * - ``WORKDIR``
     - ``work/`` at the repository root
     - Nextflow's work directory. It must be on storage that every node can reach, and is kept
       for ``-resume``.
   * - ``S3_ANONYMOUS``
     - ``false``
     - Set to ``true`` to read a public bucket, such as ``s3://aind-open-data``, without AWS
       credentials.
   * - ``CONTAINER_TAG``
     - ``PIPELINE_VERSION`` in ``nextflow.config``
     - The tag of every step image. ``dev`` selects the development images.
   * - ``NEXTFLOW_BIN``
     - ``nextflow``
     - The Nextflow executable.

3. Point Apptainer's temporary directory at node-local storage. Apptainer converts each image to a
   SIF file in ``APPTAINER_TMPDIR``, and filesystems that reject extended attributes make this
   fail (see :ref:`troubleshooting`).

4. Submit the head job. Options given to ``sbatch`` override the ``#SBATCH`` lines in the script,
   and the head job must be allowed to run for the whole pipeline:

.. code-block:: bash

   sbatch --partition="$DEFAULT_QUEUE" --cpus-per-task=4 --mem=8G --time=24:00:00 \
       --output=pophys-%j.log "$PIPELINE_PATH/slurm_submit.sh" --acquisition_data_type multiplane

``slurm_submit.sh`` runs ``preflight.sh``, which checks Java, Nextflow, Apptainer, the parameter
file, the image list and the input paths, then starts Nextflow with ``nextflow_slurm.config``.
Arguments after the script name are passed to Nextflow; here ``--acquisition_data_type`` selects a
multiplane session (the default is ``single``). Each step may run for up to a day, so give the head
job more time for large sessions.

Nextflow's progress goes to the ``--output`` file, one line per submitted or finished task, and
each task runs as its own ``nf-<step>`` job in ``squeue``. The full log is
``RESULTS_PATH/nextflow/nextflow.log``, and a failed task's output is ``.command.log`` in the work
directory that the error names.

A failed run continues from its last completed tasks when resubmitted from the same directory,
which holds Nextflow's run history:

.. code-block:: bash

   sbatch --partition="$DEFAULT_QUEUE" --cpus-per-task=4 --mem=8G --time=24:00:00 \
       --output=pophys-%j.log "$PIPELINE_PATH/slurm_submit.sh" --acquisition_data_type multiplane -resume

Nextflow pulls each image from the GitHub Container Registry the first time it is used and caches
it in ``NXF_APPTAINER_CACHEDIR``. Optionally, pull them before the first run, for example from a
login node:

.. code-block:: bash

   NXF_APPTAINER_CACHEDIR=/path/to/cache "$PIPELINE_PATH/../scripts/pull_pipeline_images.sh"

``--steps CONVERTER,MOTION_CORRECTION`` limits it to some steps. Images already in the cache are
skipped. The script needs ``jq``.

Example: Allen Institute HPC
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

On the Allen Institute cluster, submit from the login node with the ``aind`` partition,
an A100 GPU for the classifier and a node-local ``APPTAINER_TMPDIR``. ``$SLURM_JOB_ID`` only exists
inside the job, so the temporary directory is set in the ``--wrap`` command:

.. code-block:: bash

   module load java/jdk-21.0.3
   export NXF_VER=24.10.4
   export PIPELINE_PATH=/path/to/aind-pophys-pipeline/pipeline
   export DEFAULT_QUEUE=aind
   export GPU_CLUSTER_OPTIONS='--gres=gpu:a100:1'
   export OPHYS_MOUNT_URL=s3://aind-open-data/multiplane-ophys_851711_2026-08-19_11-13-08
   export S3_ANONYMOUS=true
   export RESULTS_PATH=/allen/aind/scratch/$USER/pophys/results
   export WORKDIR=/allen/aind/scratch/$USER/pophys/work
   export NXF_APPTAINER_CACHEDIR=/allen/aind/scratch/$USER/pophys/apptainer-cache
   export APPTAINER_CACHEDIR=$NXF_APPTAINER_CACHEDIR

   sbatch --partition=aind --cpus-per-task=4 --mem=8G --time=24:00:00 \
       --output=/allen/aind/scratch/$USER/pophys/head-%j.log \
       --wrap 'export APPTAINER_TMPDIR=/scratch/fast/$SLURM_JOB_ID && mkdir -p "$APPTAINER_TMPDIR" && exec bash "$PIPELINE_PATH/slurm_submit.sh" --acquisition_data_type multiplane'


Local Deployment
----------------

.. warning::
   While local deployment is possible, it's recommended to use SLURM or batch processing systems
   for better performance. Local deployment runs at most four tasks of each step at a time, and
   several steps request 64 to 128 GB of memory.

Requirements
~~~~~~~~~~~~
See the :doc:`installation` page for detailed setup instructions.

Running Locally
~~~~~~~~~~~~~~~

1. Clone the repository:

   .. code-block:: bash

      git clone https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
      cd aind-pophys-pipeline
      cd pipeline

2. Run the pipeline:

.. code-block:: bash

   OPHYS_MOUNT_URL=s3://aind-open-data/single-plane-ophys_869385_2026-11-07_12-33-14 \
       S3_ANONYMOUS=true ./run_local.sh -resume

For a multiplane session, add ``--acquisition_data_type multiplane``. See :doc:`input_output` for
example sessions.

``run_local.sh`` reads ``OPHYS_MOUNT_URL``, ``PARAMS_FILE``, ``DATA_PATH``, ``RESULTS_PATH``,
``WORKDIR`` and ``NEXTFLOW_BIN`` with the same defaults as the SLURM launcher, runs
``preflight.sh``, and starts Nextflow with ``nextflow_local.config``. Arguments are passed to
Nextflow. Containers run with ``--platform=linux/amd64``, and the classifier with ``--gpus all``.

Docker pulls each image the first time a step uses it. To pull them all beforehand, run
``./scripts/pull_pipeline_images.sh --engine docker`` from the repository root; ``--save`` with
``--cache`` also writes each image to a ``zstd`` archive, for copying to a machine that cannot
reach ``ghcr.io``. Runs still install each step's library from GitHub.


Code Ocean Deployment (AIND)
----------------------------

For AIND internal use, the pipeline is deployed on Code Ocean with the same ``main.nf``.
``nextflow.config`` runs every step on AWS Batch, with the same images as every other backend.

Configuration
~~~~~~~~~~~~~

* Parameters come from the App Builder panel (``.codeocean/app-panel.json``), or from a
  ``pipeline_parameters.json`` file copied into the pipeline's ``/data`` directory (see
  :doc:`parameters`).
* The model files are the data assets attached by ``.codeocean/datasets.json``
  (see :ref:`model-files`).
* Set ``ophys_mount_url`` to the session's S3 URL, and ``acquisition_data_type`` to ``single`` or
  ``multiplane``.

This example shows how to run the pipeline using the Code Ocean Python API:

.. code-block:: python

   from codeocean.client import CodeOcean
   from codeocean.computation import NamedRunParam, RunParams

   co_client = CodeOcean(domain=YOUR_DOMAIN, token=YOUR_TOKEN)

   named_parameters = [
      NamedRunParam(
         param_name="ophys_mount_url",
         value="s3://aind-open-data/<session>",
      ),
      NamedRunParam(
         param_name="acquisition_data_type",
         value="multiplane",
      ),
   ]

   run_params = RunParams(
      pipeline_id=PIPELINE_ID,
      named_parameters=named_parameters,
   )

   # Run the pipeline
   computation = co_client.computations.run_capsule(run_params)

.. note::

   Code Ocean fills in every App Builder parameter that a request leaves out with its panel
   default, and ``acquisition_data_type`` defaults to ``single``. Always pass it for multiplane
   sessions.
