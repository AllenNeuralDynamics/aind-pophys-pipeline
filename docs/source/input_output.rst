Input and Output
================

Input Data Types
----------------

The pipeline reads one session at a time, given by the ``ophys_mount_url`` parameter as either an
S3 URL or an absolute directory.

AIND
~~~~
* Used for AIND data ingestion, from an S3 URL. The Converter step reads it.
* Input folder structure:
   * ``pophys/`` directory containing the raw ScanImage TIFF files
   * JSON files following the `aind-data-schema <https://aind-data-schema.readthedocs.io/en/latest/>`_
     specification at the top level. The acquisition metadata (``acquisition.json``, or
     ``session.json`` for v1 metadata) is required. ``data_description.json``, ``subject.json``,
     ``procedures.json`` and ``instrument.json`` (``rig.json`` for v1) are recommended; the
     Metadata merge step builds on them.
* The instrument id in the acquisition metadata selects the conversion path:
   * Bergamo sessions are single-plane: ``pophys/`` holds per-epoch TIFF files, and the epochs come
     from the stimulus epochs in the acquisition metadata. Run with
     ``acquisition_data_type=single``.
   * Mesoscope sessions are multiplane: ``pophys/`` holds the multiplexed
     ``*timeseries.tiff``, the ``*averaged_depth.tiff`` and ``*averaged_surface.tiff`` images,
     optional ``*local_z*.tiff`` z-stacks, ``*fullfield*.tiff`` and ``*_vasculature.tif``
     images, and ``*platform.json``. Run with ``acquisition_data_type=multiplane``.

.. code-block:: text

   multiplane-ophys_<subject>_<date>_<time>/
   ├── pophys/
   ├── acquisition.json
   ├── data_description.json
   ├── instrument.json
   ├── procedures.json
   └── subject.json

Local directory
~~~~~~~~~~~~~~~
* An absolute directory with the same top-level JSON files and ``pophys/`` directory
* The Converter step does not run: the directory is passed to the Registration step as it is

Pipeline Output
---------------

The pipeline output is organized in the results directory (``RESULTS_PATH`` on SLURM and local
runs). Every per-plane step writes into a folder for each plane, named with the plane id:
``plane_0`` for a single-plane session, and ``<targeted structure>_<plane index>`` (for example
``VISp_0``) for a multiplane session. Each step folder also holds that step's ``processing.json``
and, for every step except NWB packaging, its ``quality_control.json``.

.. code-block:: text

   results/
   ├── <plane_id>/
   │   ├── motion_correction/
   │   ├── movie_qc/
   │   ├── decrosstalk/          (multiplane only)
   │   ├── extraction/
   │   ├── dff/
   │   ├── classification/
   │   └── events/
   ├── nwb/
   ├── processing.json
   ├── quality_control.json
   └── data_description.json

Converter files
~~~~~~~~~~~~~~~
The Converter output sits directly in each plane folder:

* ``<plane_id>.h5``: the converted movie
* Mesoscope sessions: ``<plane_id>_depth.tif`` and ``<plane_id>_surface.tif`` (averaged depth
  and surface images) and ``<plane_id>_z_stack_local.h5`` (the plane's local z-stack, when the
  session has one)
* ``stitched_full_field_img.h5`` at the results root, when the session has a full-field image

``motion_correction/``
~~~~~~~~~~~~~~~~~~~~~~
Contains the Registration output, each file named after the plane:

* ``*_registered.h5``: the registered movie (``data``), the reference image, run metadata and
  registration metrics
* ``*_motion_transform.csv``: per-frame x and y offsets, correlation and validity, with per-block
  columns when non-rigid registration ran
* ``*_maximum_projection.png`` and ``*_average_projection.png``
* ``*_registration_summary.png``: projections with offset and correlation traces
* ``*_motion_preview.webm``: a raw versus registered preview movie
* Bergamo sessions also write ``trial_locations.json`` and ``epoch_locations.json``

``movie_qc/``
~~~~~~~~~~~~~
Contains the Movie QC output, where ``<base>`` is the registered movie's name:

* ``<base>_metrics.json``: the computed metrics
* ``<base>_mean_projection_image.png`` and the photon statistics, intensity and epilepsy
  probability plots
* With a local z-stack: ``<base>_zdrift.png`` and the registered z-stack

``decrosstalk/``
~~~~~~~~~~~~~~~~
Contains the Decrosstalk output for multiplane sessions:

* ``<plane_id>_decrosstalk.h5``: the unmixed movie (``data``) with the per-epoch unmixing
  coefficients
* ``<plane_id>_decrosstalk_episodic_mean_fov.h5`` and ``.webm``: per-epoch mean images of the
  unmixed movie
* ``<plane_id>_registered_episodic_mean_fov.h5`` and
  ``<plane_id>_registered_to_pair_episodic_mean_fov.h5``: per-epoch mean images of the plane's own
  movie and of its movie warped into its partner's frame
* Average and maximum projection images, and on the lower-indexed plane of each pair, the
  coupled-plane comparison image

``extraction/``
~~~~~~~~~~~~~~~
Contains the Extraction output:

* ``<plane_id>_extraction.h5``: ROI, neuropil and neuropil-corrected traces
  (``traces/roi``, ``traces/neuropil``, ``traces/corrected``), sparse ROI masks, ``iscell`` and
  summary images
* ``<plane_id>_detected_ROIs.png`` and ``<plane_id>_detected_ROIs_withIDs.png``

``dff/``
~~~~~~~~
Contains the dF/F output:

* ``<plane_id>_dff.h5``: datasets ``data`` (dF/F), ``baseline``, ``noise`` and ``skewness``
* ``<plane_id>_dff_logs.json``: per-ROI baseline fit logs
* ``plots/``: one figure per ROI

``classification/``
~~~~~~~~~~~~~~~~~~~
Contains the Classifier output:

* ``<plane_id>_classification.h5``: groups ``soma`` and ``dendrites``, each with ``predictions``
  and ``probabilities``, and ``border/labels``
* Prediction, probability and border figures

``events/``
~~~~~~~~~~~
Contains the Events output:

* ``<plane_id>_events_oasis.h5``: datasets ``events`` (deconvolved activity) and ``denoised``
  (denoised fluorescence), each shaped ``(n_rois, n_frames)``, with the estimated model parameters
* ``plots/``: one figure per ROI

``nwb/``
~~~~~~~~
Contains the NWB packaging output:

* ``pophys.nwb.zarr``: one NWB file in Zarr format, with a processing module per plane holding
  the ROI and neuropil tables, projection and segmentation images, and the raw, neuropil,
  neuropil-corrected, dF/F and event traces
* ``processing.json``

Files can be read with `h5py <https://pypi.org/project/h5py/>`_ and
`PyNWB <https://pynwb.readthedocs.io/>`_ with `hdmf-zarr <https://hdmf-zarr.readthedocs.io/>`_:

.. code-block:: python

   import h5py
   from hdmf_zarr import NWBZarrIO

   with h5py.File("results/VISp_0/dff/VISp_0_dff.h5", "r") as f:
       dff = f["data"][()]

   with NWBZarrIO("results/nwb/pophys.nwb.zarr", mode="r") as io:
       nwbfile = io.read()

Additional Files
----------------

* ``processing.json``: every step's processing record, merged for the run
* ``quality_control.json``: every step's quality control metrics, merged for the run
* ``data_description.json``: the derived data description
* Copies of the session's ``subject.json``, ``procedures.json``, ``instrument.json`` and
  ``acquisition.json`` (``rig.json`` and ``session.json`` for v1), unless
  ``skip_ancillary_files`` is set
* ``nextflow/``: the Nextflow log, report, timeline, trace and DAG (SLURM and local runs)
