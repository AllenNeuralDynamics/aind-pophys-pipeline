Pipeline Parameters
===================

Global Parameters
-----------------

The pipeline accepts several global parameters that control its overall behavior:

.. code-block:: bash

   --ophys_mount_url URL_OR_DIR        Session to process: an S3 URL or an absolute directory
   --acquisition_data_type {single,multiplane}
                                       single runs the single-plane steps; multiplane adds
                                       pair splitting and decrosstalk
   --debug {0,1}                       Process a shortened movie, for fast end-to-end checks
   --params_file PATH                  Parameter file (or the PARAMS_FILE environment variable)
   --input_dir, --output_dir, --temp_dir
                                       Absolute container paths given to every step
                                       (default /data, /results and /scratch)

The defaults ``/data``, ``/results`` and ``/scratch`` map to the ``data``, ``results`` and
``scratch`` folders inside each task's work directory; any other absolute path is passed to the
steps unchanged. The paths must not contain whitespace. On SLURM, ``--default_queue`` and
``--gpu_queue`` select the partitions; ``slurm_submit.sh`` sets them from ``DEFAULT_QUEUE`` and
``GPU_QUEUE`` (see :doc:`deployments`).

With ``--debug 1``, the Converter clips each plane's movie, Registration runs on part of the
movie, and Decrosstalk truncates each movie to its first 360 seconds.


Parameter File
--------------

A parameter file can be used to set all parameters at once.
This is the recommended way to configure the pipeline. The parameter file is a flat JSON object
of parameter names and values, and you can use ``pipeline_parameters.json`` at the repository root
as a template; it sets every parameter that the steps read.

To use a parameter file, specify it with the ``--params_file`` option or the ``PARAMS_FILE``
environment variable:

.. code-block:: bash

   --params_file PATH_TO_PARAMS_FILE
   # Example: --params_file pipeline_parameters.json

Without either, the pipeline looks for ``data/pipeline_parameters.json`` at the repository root,
then ``/data/pipeline_parameters.json``. A named file that does not exist stops the run. The
launchers ``slurm_submit.sh`` and ``run_local.sh`` always pass a file, by default
``pipeline_parameters.json`` at the repository root.

.. note::

   A value from the parameter file applies only when the parameter is not already set on the
   command line, in a Nextflow configuration file, or at the top of ``main.nf``. Command line
   arguments therefore override the parameter file. ``ophys_mount_url``, ``input_dir``,
   ``output_dir`` and ``temp_dir`` are set at the top of ``main.nf``, so set them on the command
   line.

The pipeline log names the parameter file it used and prints every resolved parameter as
``PARAM: <name> = <value>``.


.. _app-builder-panel:

App Builder Panel
-----------------

On Code Ocean, parameters are set in the pipeline's App Builder panel, which is generated from
``.codeocean/app-panel.json``. The panel groups the parameters into Motion correction, Extraction,
DF / F, Classification and Metadata Manager categories, plus the global parameters. Code Ocean
passes each panel parameter to Nextflow as a command line argument, so panel values override a
parameter file.

The classifier parameters keep the hyphenated names of their panel entries
(``soma-classifier-path``, ``dendrite-classifier-path``, ``model-name`` and ``border-size``), in
the panel and in parameter files alike.


Process-Specific Arguments
--------------------------

Parameters can be specified via the parameter file or passed directly as command line arguments
when running the pipeline. CLI arguments will override any conflicting parameters set in the
parameter file. Each step receives only the parameters listed in its section; the defaults below
are the values in ``pipeline_parameters.json``. Movie QC, Pair splitting, Events and NWB packaging
run with their libraries' defaults.

Converter Parameters
~~~~~~~~~~~~~~~~~~~~

The Converter receives ``--debug`` (see `Global Parameters`_).

Registration Parameters
~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 12 63

   * - Parameter
     - Default
     - Description
   * - ``do_registration``
     - ``True``
     - Whether to register the movie.
   * - ``data_type``
     - ``h5``
     - Input movie format: ``h5``, ``tif`` or ``bruker``.
   * - ``batch_size``
     - ``500``
     - Number of frames per registration batch.
   * - ``maxregshift``
     - ``0.1``
     - Maximum rigid shift, as a fraction of the larger frame dimension. Ignored when an external
       reference image is forced, which is the library default.
   * - ``maxregshiftNR``
     - ``5``
     - Maximum non-rigid shift in pixels, relative to the rigid shift.
   * - ``align_by_chan``
     - ``1``
     - Channel to align by in multi-channel data (1-based).
   * - ``smooth_sigma_time``
     - ``0``
     - Gaussian smoothing in time before registration.
   * - ``smooth_sigma``
     - ``1.15``
     - Spatial Gaussian smoothing before registration. About 1 suits two-photon data; 3 to 5 suits
       one-photon data.
   * - ``nonrigid``
     - ``True``
     - Whether to run non-rigid registration.
   * - ``snr_thresh``
     - ``1.2``
     - Non-rigid blocks below this signal-to-noise ratio are smoothed until they exceed it. 1.0
       disables the smoothing.

Registration also receives ``--debug``.

Decrosstalk Parameters
~~~~~~~~~~~~~~~~~~~~~~

Decrosstalk receives ``--debug`` (see `Global Parameters`_).

Extraction Parameters
~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 12 63

   * - Parameter
     - Default
     - Description
   * - ``init``
     - ``sparsery``
     - Cell detection method: ``max/mean`` (Cellpose on the maximum projection divided by the
       mean image), ``mean``, ``enhanced_mean`` or ``max`` (Cellpose on that image),
       ``sourcery`` and ``sparsery`` (Suite2p functional detection without and with sparse
       mode), ``greedy_roi`` and ``corr_pnr`` (CaImAn functional detection).
   * - ``diameter``
     - ``0``
     - Expected cell diameter in pixels. 0 lets Cellpose estimate it.
   * - ``cellprob_threshold``
     - ``0.0``
     - Cellpose cell probability threshold. Decrease it if Cellpose returns too few ROIs.
   * - ``functional_chan``
     - ``1``
     - Channel used to extract functional ROIs (1-based).
   * - ``threshold_scaling``
     - ``1``
     - Multiplier on the automatically determined detection threshold.
   * - ``max_overlap``
     - ``0.75``
     - ROIs overlapping more than this fraction are removed during triage, before refinement.
   * - ``soma_crop``
     - ``0``
     - Crop dendrites when computing cell statistics such as compactness.
   * - ``allow_overlap``
     - ``0``
     - Whether overlapping pixels are discarded (0) or added to both ROIs (1).
   * - ``suite2p_params``
     - empty
     - JSON string of Suite2p parameters that override the defaults, for the Suite2p-based
       methods (every ``init`` value except ``greedy_roi`` and ``corr_pnr``). Keys that the
       pipeline controls, such as paths and the frame rate, are dropped. Applied after
       ``suite2p_ops``.
   * - ``suite2p_ops``
     - empty
     - Path to a Suite2p ``ops.npy`` file to load parameters from, for the Suite2p-based methods.

dF/F Parameters
~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 12 63

   * - Parameter
     - Default
     - Description
   * - ``method``
     - ``triexp``
     - Baseline method: ``triexp`` (triexponential baseline fit) or ``percentile``
       (rolling-percentile baseline).
   * - ``sigma_anneal_steps``
     - ``1``
     - Sigma-annealing steps of the baseline fit. 1 or 2 disable annealing. ``triexp`` only.
   * - ``triexp_config_overrides``
     - ``{}``
     - JSON object of overrides for the triexponential fit configuration. ``triexp`` only.
   * - ``long_window``
     - ``60``
     - Baseline window in seconds. ``percentile`` only.
   * - ``short_window``
     - ``3.333``
     - Detrending window in seconds. ``percentile`` only.
   * - ``inactive_percentile``
     - ``10``
     - Percentile of inactive frames used for the baseline. ``percentile`` only.
   * - ``noise_method``
     - ``mad``
     - Noise estimator: ``mad``, ``fft`` or ``welch``. ``percentile`` only.

Classifier Parameters
~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 12 63

   * - Parameter
     - Default
     - Description
   * - ``soma-classifier-path``
     - empty
     - Path of the soma classifier ONNX model. Empty uses the model in ``2p_roi_classifier/``
       (see :ref:`model-files`).
   * - ``dendrite-classifier-path``
     - empty
     - Path of the dendrite classifier ONNX model. Empty uses the model in
       ``2p_roi_classifier/``.
   * - ``model-name``
     - empty
     - Model identifier recorded in ``processing.json``. Empty uses the directory name of the
       soma classifier.
   * - ``border-size``
     - ``10``
     - Distance in pixels from the field-of-view border within which an ROI is labeled a
       border ROI.

Metadata Merge Parameters
~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 25 15 60

   * - Parameter
     - Default
     - Description
   * - ``processor_full_name``
     - ``pipeline user``
     - Name of the person responsible for processing, recorded in ``processing.json``.
   * - ``modality``
     - ``pophys``
     - Modality written to the derived data description.
   * - ``data_summary``
     - empty
     - Data summary written to the derived data description.
   * - ``aggregate_quality_control``
     - ``1``
     - Whether to merge the steps' quality control documents into the run-level
       ``quality_control.json``.
   * - ``skip_ancillary_files``
     - ``0``
     - Skip copying the session's metadata files into the results.
   * - ``verbose``
     - ``1``
     - Print verbose output.

The pipeline name, version and URL recorded in the metadata come from the ``PIPELINE_NAME``,
``PIPELINE_VERSION`` and ``PIPELINE_URL`` variables in the Nextflow configuration files.


Full example with custom parameters
-----------------------------------

Copy ``pipeline_parameters.json``, change the values you need, and pass the copy to the run.
For example, for a multiplane session with Cellpose detection on the mean image and a
percentile dF/F baseline:

.. code-block:: json

   {
       "acquisition_data_type": "multiplane",
       "init": "mean",
       "method": "percentile",
       "long_window": "60",
       "processor_full_name": "Jane Doe"
   }

The excerpt shows only the changed values; keep the rest of the template's entries in the file.

.. code-block:: bash

   PARAMS_FILE=$PWD/../my_parameters.json \
   OPHYS_MOUNT_URL=s3://aind-open-data/<session> S3_ANONYMOUS=true \
       ./run_local.sh --debug 1
