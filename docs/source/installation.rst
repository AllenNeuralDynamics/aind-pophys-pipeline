Installation
============

Requirements
------------

The pipeline has different requirements depending on your deployment target.
Here are the core requirements for each deployment option:


Local Deployment
----------------

Requirements
~~~~~~~~~~~~

For local deployment, you need:

* At least 16 CPUs and 128 GB of memory, which the largest steps request; Nextflow stops a run
  whose requests exceed the machine. The work directory needs several times the session's size.
* Java 17 to 23
* ``nextflow`` 24.10.4, the version Code Ocean runs
* ``docker``, with the `NVIDIA Container Toolkit <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>`_
  for the classifier step
* An NVIDIA GPU of the Turing generation or newer, with a driver that supports CUDA 13, for the
  classifier step
* HTTPS access to ``github.com``, from which each step installs its processing library, and
  ``ghcr.io``, which serves the step images
* The model files described in :ref:`model-files`

Installation Steps
~~~~~~~~~~~~~~~~~~

1. Install Java 17 to 23, then Nextflow 24.10.4 (see the
   `Nextflow installation guide <https://www.nextflow.io/docs/latest/install.html>`_ for other
   options):

   .. code-block:: bash

      export NXF_VER=24.10.4
      curl -fsSL https://get.nextflow.io | bash
      mkdir -p ~/bin && mv nextflow ~/bin/
      export PATH="$HOME/bin:$PATH"

2. Install Docker:

   Follow the `Docker installation instructions <https://docs.docker.com/engine/install/>`_

3. Clone the pipeline repository:

   .. code-block:: bash

      git clone https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
      cd aind-pophys-pipeline
      cd pipeline

4. Place the model files in ``data/`` at the repository root, or in another folder that you pass as
   ``DATA_PATH`` (see :ref:`model-files`).


SLURM Deployment
----------------

Requirements
~~~~~~~~~~~~

For SLURM cluster deployment:

* Java 17 to 23
* ``nextflow`` 24.10.4, the version Code Ocean runs
* ``apptainer`` or ``singularity`` on the compute nodes
* Partitions whose limits fit the step requests in ``nextflow_slurm.config`` (up to 16 CPUs,
  128 GB and one day per step), with NVIDIA GPUs of the Turing generation or newer, and a driver
  that supports CUDA 13, for the classifier step
* HTTPS access from the compute nodes to ``github.com`` and ``ghcr.io``, and to S3 for sessions
  read from S3
* The model files described in :ref:`model-files`, on storage that every compute node can read

Installation Steps
~~~~~~~~~~~~~~~~~~

1. Make Java 17 to 23 available, for example with ``module load``. Load a specific version: a
   cluster's default Java module can be older. Then install Nextflow in your home directory:

   .. code-block:: bash

      export NXF_VER=24.10.4
      curl -fsSL https://get.nextflow.io | bash
      mkdir -p ~/bin && mv nextflow ~/bin/
      export PATH="$HOME/bin:$PATH"

   ``sbatch`` passes your environment, including ``PATH``, to the job, so do this before
   submitting.

2. Check that Apptainer or Singularity is available on a compute node:

   .. code-block:: bash

      srun --partition=CHANGE_ME --time=5 bash -c 'command -v apptainer singularity'

3. Set up environment variables:

   .. code-block:: bash

      export NXF_VER=24.10.4
      # Optional: set a shared Apptainer (or Singularity) image cache directory
      export NXF_APPTAINER_CACHEDIR="/path/to/cache"
      # export NXF_SINGULARITY_CACHEDIR="/path/to/cache"

4. Clone the pipeline repository:

   .. code-block:: bash

      git clone https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
      cd aind-pophys-pipeline
      cd pipeline

5. Place the model files in ``data/`` at the repository root, or in another folder that you pass as
   ``DATA_PATH`` (see :ref:`model-files`).


Code Ocean Deployment (AIND)
----------------------------

The Code Ocean configuration targets the AIND deployment: ``.codeocean/datasets.json`` attaches
AIND data assets, including the model files, and ``.codeocean/settings.json`` names an AIND AWS
role. To set it up there, "Create New" --> "Pipeline" --> "Clone from Git" and point to the
repository URL: ``https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git``

Code Ocean builds the App Builder panel from ``.codeocean/app-panel.json``. See
:doc:`deployments` for running the pipeline.


.. _model-files:

Model Files
-----------

Several steps read model files from a data folder, which every task mounts at ``/tmp/data``.
On SLURM and local runs this folder is ``DATA_PATH`` (by default ``data/`` at the repository root).
On Code Ocean the folders are the data assets in ``.codeocean/datasets.json``, attached under the
same names.

For SLURM and local runs, download them all from a public bucket into ``DATA_PATH``. No AWS
account or AWS CLI is needed. From anywhere inside the repository:

.. code-block:: bash

   DATA_PATH="${DATA_PATH:-$(git rev-parse --show-toplevel)/data}"
   BASE=https://aind-scratch-data.s3.amazonaws.com/aind-pophys-pipeline/data
   mkdir -p "$DATA_PATH" && cd "$DATA_PATH"
   curl -fsSO "$BASE/SHA256SUMS"
   awk '{print $2}' SHA256SUMS | while read -r f; do
       mkdir -p "$(dirname "$f")" && curl -fsS -o "$f" "$BASE/$f"
   done
   sha256sum -c SHA256SUMS   # on macOS: shasum -a 256 -c SHA256SUMS
   cd -

With the AWS CLI, the same download is:

.. code-block:: bash

   aws s3 sync --no-sign-request s3://aind-scratch-data/aind-pophys-pipeline/data/ \
       "${DATA_PATH:-$(git rev-parse --show-toplevel)/data}"

.. code-block:: text

   data/
   ├── 2p_roi_classifier/
   │   ├── soma.classification_training.autoclassifier.onnx
   │   └── dendrite.classification_training.autoclassifier.onnx
   ├── schemas/
   ├── cellpose_models/
   └── roinet/

.. list-table::
   :header-rows: 1
   :widths: 25 15 60

   * - Folder
     - Required
     - Used by
   * - ``2p_roi_classifier/``
     - Yes
     - Classifier: the soma and dendrite ONNX classifiers
   * - ``schemas/``
     - Yes
     - NWB packaging: the NWB extension schema, ``ndx-aibs-behavior-ophys.namespace.yaml`` and
       ``ndx-aibs-behavior-ophys.extension.yaml``
   * - ``cellpose_models/``
     - No
     - Decrosstalk and Extraction: Cellpose weights. When absent, Cellpose downloads them.
   * - ``roinet/``
     - No
     - Classifier: ``ROInet.zip`` and the ConvNeXt checkpoint under
       ``torch/hub/checkpoints/``. When absent, both are downloaded.

Decrosstalk and Extraction record the Cellpose model files they loaded in their
``processing.json``.

