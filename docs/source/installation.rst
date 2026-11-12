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

* Java 17 or newer
* ``nextflow`` 24.10.4, the version Code Ocean runs
* ``docker``, with the `NVIDIA Container Toolkit <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>`_
  for the classifier step
* An NVIDIA GPU of the Turing generation or newer for the classifier step, whose CUDA 13 runtime
  does not support older GPUs
* The model files described in :ref:`model-files`

Installation Steps
~~~~~~~~~~~~~~~~~~

1. Install Java and Nextflow:

   Follow the `Nextflow installation guide <https://www.nextflow.io/docs/latest/install.html>`_,
   then pin the version:

   .. code-block:: bash

      export NXF_VER=24.10.4

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

* Java 17 or newer
* ``nextflow`` 24.10.4, the version Code Ocean runs
* ``apptainer`` or ``singularity``
* Access to a SLURM cluster, with a partition that has NVIDIA GPUs of the Turing generation or
  newer for the classifier step
* The model files described in :ref:`model-files`, on storage that every compute node can read

Installation Steps
~~~~~~~~~~~~~~~~~~

1. Install Nextflow on your cluster environment, and make Java 17 or newer available (for
   example with ``module load``)
2. Ensure Apptainer/Singularity is available
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


Code Ocean Deployment
---------------------

To set up the pipeline in Code Ocean, you can simply "Create New" --> "Pipeline" --> "Clone from Git"
and point to the repository URL: ``https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git``

Code Ocean attaches the data assets listed in ``.codeocean/datasets.json``, which hold the model
files, and builds the App Builder panel from ``.codeocean/app-panel.json``. See
:doc:`deployments` for running the pipeline.


.. _model-files:

Model Files
-----------

Several steps read model files from a data folder, which every task mounts at ``/tmp/data``.
On SLURM and local runs this folder is ``DATA_PATH`` (by default ``data/`` at the repository root).
On Code Ocean the folders are the data assets in ``.codeocean/datasets.json``, attached under the
same names.

For SLURM and local runs, download them all from a public bucket into ``DATA_PATH``. No AWS
account is needed:

.. code-block:: bash

   aws s3 sync --no-sign-request s3://aind-scratch-data/aind-pophys-pipeline/data/ "$DATA_PATH"

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
     - NWB packaging: ``ndx-aibs-behavior-ophys.namespace.yaml`` and
       ``ndx-aibs-behavior-ophys.extension.yaml``, from
       `aind-ophys-nwb <https://github.com/AllenNeuralDynamics/aind-ophys-nwb/tree/main/code>`_
   * - ``cellpose_models/``
     - No
     - Decrosstalk and Extraction: Cellpose weights. When absent, Cellpose downloads them.
   * - ``roinet/``
     - No
     - Classifier: ``ROInet.zip`` and the ConvNeXt checkpoint under
       ``torch/hub/checkpoints/``. When absent, both are downloaded.

Decrosstalk and Extraction record the Cellpose model files they loaded in their
``processing.json``.

