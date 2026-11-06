Customization
=============

The pipeline is designed to be flexible and customizable, given its modular structure.


Customizing Pipeline Steps
--------------------------

Each step of the pipeline runs two pieces of code: a thin wrapper repository, cloned at a pinned
commit when the step starts, and a processing library, installed in the step's container image.

Wrapper repositories
~~~~~~~~~~~~~~~~~~~~

The wrapper's repository and commit for each step are pinned in ``pipeline/process_versions.env``.
To run a modified wrapper, fork its repository, commit your change, and point the pipeline at your
fork. Instead of changing the default ``process_versions.env`` file, we recommend creating a
``pipeline/process_versions_custom.env`` file, which git ignores.

When ``process_versions_custom.env`` exists, the pipeline reads it **instead of**
``process_versions.env``, so start from a copy and change only the steps you need:

.. code:: bash

    cp pipeline/process_versions.env pipeline/process_versions_custom.env

For example, to run your fork of the dF/F wrapper:

.. code:: bash

    DFF_CAPSULE_REPO=https://github.com/your_username/aind-ophys-dff
    DFF_CAPSULE_COMMIT=full_40_character_commit_hash

Every step needs both entries, and each commit must be a full 40-character hash. The pipeline
clones the repository anonymously and runs its ``code/run`` script, so the repository must be
public.

The full list of steps is:

.. list-table::
   :header-rows: 1
   :widths: 25 40 35

   * - Prefix in ``process_versions.env``
     - Default wrapper repository
     - Step
   * - ``CONVERTER``
     - ``aind-pophys-converter-capsule``
     - Converter
   * - ``MOTION_CORRECTION``
     - ``aind-ophys-motion-correction``
     - Registration
   * - ``MOVIE_QC``
     - ``aind-ophys-movie-qc``
     - Movie QC
   * - ``DECROSSTALK_SPLIT``
     - ``aind-ophys-decrosstalk-split-session-json``
     - Pair splitting
   * - ``DECROSSTALK_ROI_IMAGES``
     - ``aind-ophys-decrosstalk-roi-images``
     - Decrosstalk
   * - ``EXTRACTION``
     - ``aind-ophys-extraction``
     - Extraction
   * - ``DFF``
     - ``aind-ophys-dff``
     - dF/F
   * - ``OASIS``
     - ``aind-ophys-oasis-event-detection``
     - Events
   * - ``CLASSIFIER``
     - ``aind-ophys-classifier``
     - Classifier
   * - ``NWB``
     - ``aind-ophys-nwb``
     - NWB packaging
   * - ``AGGREGATOR``
     - ``aind-metadata-manager-capsule``
     - Metadata merge

Processing libraries and images
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A step's processing library and its dependencies are part of the step's container image, so a
library change needs a new image. ``pipeline/images.env`` pins one image per step, by digest:

.. code:: bash

    DFF=ghcr.io/allenneuraldynamics/pophys-dff@sha256:<digest>

The pipeline accepts only digest-pinned images in the ``ghcr.io/allenneuraldynamics/pophys-*``
namespace and stops before running any step otherwise. The images are built from the
``environment/`` directory: ``environment/stages/<stage>/source.json`` records each step's library
repository and commit, and the lock files beside it pin the library's dependencies. See
``environment/README.md`` for building, checking and publishing images.


Custom Parameters
-----------------

Copy ``pipeline_parameters.json`` and pass your copy with ``--params_file`` or ``PARAMS_FILE``
(see :doc:`parameters`).


Custom Classifier Models
------------------------

The Classifier reads its soma and dendrite ONNX models from ``2p_roi_classifier/`` in the data
folder (see :ref:`model-files`). To use other models, set ``soma-classifier-path`` and
``dendrite-classifier-path`` to their paths inside the container. The data folder is mounted at
``/tmp/data``, so a model added as ``DATA_PATH/my_models/soma.onnx`` is
``/tmp/data/my_models/soma.onnx``. Set ``model-name`` to the identifier to record in
``processing.json``.
