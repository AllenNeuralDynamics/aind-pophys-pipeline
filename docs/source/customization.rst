Customization
=============

The pipeline is designed to be flexible and customizable, given its modular structure.


Customizing Pipeline Steps
--------------------------

Each step runs a processing library. When a step starts, the pipeline clones the library at the
commit pinned in ``pipeline/process_versions.env``, installs it without dependencies into the step's
container image, which holds the library's dependencies, and runs it.

Running a fork or branch of a library
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Fork the library, commit your change, and point the pipeline at your commit. Instead of changing
the default ``process_versions.env`` file, we recommend creating a
``pipeline/process_versions_custom.env`` file, which git ignores.

When ``process_versions_custom.env`` exists, the pipeline reads it **instead of**
``process_versions.env``, so start from a copy and change only the steps you need:

.. code:: bash

    cp pipeline/process_versions.env pipeline/process_versions_custom.env

For example, to run your fork of the dF/F library:

.. code:: bash

    DFF_LIBRARY_REPO=https://github.com/your_username/aind-ophys-dff-library
    DFF_LIBRARY_COMMIT=full_40_character_commit_hash

Every step needs both entries, and each commit must be a full 40-character hash; for a branch, use
its latest commit. The pipeline clones the repository anonymously, so it must be public. If your
change keeps the library's dependencies, no image rebuild is needed. If it changes them, rebuild
the step's image (see below); the step fails at start-up with a ``pip check`` error otherwise.

The full list of steps is:

.. list-table::
   :header-rows: 1
   :widths: 25 45 30

   * - Prefix in ``process_versions.env``
     - Default library repository
     - Step
   * - ``CONVERTER``
     - ``aind-pophys-converter``
     - Converter
   * - ``MOTION_CORRECTION``
     - ``aind-ophys-motion-correction-library``
     - Registration
   * - ``MOVIE_QC``
     - ``aind-ophys-movie-qc-library``
     - Movie QC
   * - ``DECROSSTALK_SPLIT``
     - ``aind-ophys-decrosstalk-split-session-json-library``
     - Pair splitting
   * - ``DECROSSTALK_ROI_IMAGES``
     - ``aind-ophys-decrosstalk-roi-images-library``
     - Decrosstalk
   * - ``EXTRACTION``
     - ``aind-ophys-extraction-library``
     - Extraction
   * - ``DFF``
     - ``aind-ophys-dff-library``
     - dF/F
   * - ``OASIS``
     - ``aind-ophys-oasis-event-detection-library``
     - Events
   * - ``CLASSIFIER``
     - ``aind-ophys-classifier-library``
     - Classifier
   * - ``NWB``
     - ``aind-ophys-nwb-library``
     - NWB packaging
   * - ``AGGREGATOR``
     - ``aind-metadata-manager``
     - Metadata merge

Building images
~~~~~~~~~~~~~~~

``pipeline/images.env`` pins each step's published image by digest. To use an image you built,
for example after changing a library's dependencies, list it in ``pipeline/images_custom.env``,
which git ignores and which overrides only the steps it names:

.. code:: bash

    DFF=ghcr.io/allenneuraldynamics/pophys-dff:my-build

The images are built from ``environment/``. ``environment/images.json`` gives each step's
Dockerfile, image name and Python version, and ``environment/stages/<step>/requirements.lock``
pins its dependencies. With Docker, ``jq`` and, for re-locking, ``uv``:

.. code:: bash

    # Re-resolve the lock from the library commit in process_versions(_custom).env
    uv run --python 3.12 --no-project environment/lock.py DFF
    # Build into the local Docker daemon as <registry>/pophys-dff:my-build
    environment/build_all.sh my-build main DFF

``IMAGE_REGISTRY`` (default ``ghcr.io/allenneuraldynamics``) sets the registry part of the image
name. For SLURM, push the image to a registry the cluster can reach with
``environment/push_all.sh my-build main DFF``, which prints the digest to put in
``images_custom.env``. Review the lock diff before building: a re-lock keeps the versions already
locked wherever the library's dependencies allow.


Custom Parameters
-----------------

Copy ``pipeline_parameters.json`` and pass your copy with ``--params_file`` or ``PARAMS_FILE``
(see :doc:`parameters`).


.. _custom-classifier-models:

Custom Classifier Models
------------------------

The Classifier reads its soma and dendrite ONNX models from ``2p_roi_classifier/`` in the data
folder (see :ref:`model-files`). To use other models, set ``soma-classifier-path`` and
``dendrite-classifier-path`` to their paths inside the container. The data folder is mounted at
``/tmp/data``, so a model added as ``DATA_PATH/my_models/soma.onnx`` is
``/tmp/data/my_models/soma.onnx``. Set ``model-name`` to the identifier to record in
``processing.json``.
