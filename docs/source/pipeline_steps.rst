.. _pipeline_steps:

Pipeline Steps
==============

The AIND Pophys Pipeline consists of several key processing steps that are executed in sequence.
Each step has a wrapper repository, which the pipeline clones when the step starts, and a
processing library that holds its logic. Here's a detailed look at each step:

Converter
---------

The `converter <https://github.com/AllenNeuralDynamics/aind-pophys-converter-capsule/>`_ step
(library: `aind-pophys-converter <https://github.com/AllenNeuralDynamics/aind-pophys-converter/>`_)
reads the raw session and writes one HDF5 movie per imaging plane:

* Runs once per session, and only when the input is an S3 URL (see :doc:`input_output`)
* Selects a conversion path from the instrument id in the acquisition metadata:
   * Bergamo (single-plane): stitches the per-epoch TIFF files into one HDF5 movie, in acquisition
     order, with epoch and trial locations
   * Mesoscope (multiplane): splits the multiplexed ScanImage timeseries TIFF into one HDF5 movie
     per plane, together with each plane's averaged depth and surface images, its local z-stack
     and a stitched full-field image when those are present
* Records quality control metrics for mesoscope sessions

Registration
------------

The `registration <https://github.com/AllenNeuralDynamics/aind-ophys-motion-correction/>`_ step
(library: `aind-ophys-motion-correction-library <https://github.com/AllenNeuralDynamics/aind-ophys-motion-correction-library/>`_)
corrects motion in each plane with `Suite2p <https://github.com/MouseLand/suite2p>`_:

* Rigid registration, followed by non-rigid registration when enabled
* Detection of empty frames at the start and end of the movie
* Clipping of outlier frame offsets
* Projection images, a registration summary and a preview movie for review

Movie QC
--------

The `movie QC <https://github.com/AllenNeuralDynamics/aind-ophys-movie-qc/>`_ step
(library: `aind-ophys-movie-qc-library <https://github.com/AllenNeuralDynamics/aind-ophys-movie-qc-library/>`_)
computes quality metrics on each registered movie:

* Pixel saturation and under-saturation
* Photon statistics and intensity plots
* Epileptiform event probability
* Z-drift against the local z-stack, when the session has one

Pair Splitting
--------------

The `pair splitting <https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-split-session-json/>`_
step runs only for multiplane sessions:

* Reads the coupled plane pairs from the acquisition metadata
* Writes one pair file per coupled pair, which routes each pair to its own decrosstalk task

Decrosstalk
-----------

The `decrosstalk <https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images/>`_ step
(library: `aind-ophys-decrosstalk-roi-images-library <https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images-library/>`_)
removes the ghosting of cells between planes that are scanned together. It runs only for
multiplane sessions, as one task per coupled pair:

* Warps each plane's movie into its partner's frame
* Segments the mean images with `Cellpose <https://github.com/MouseLand/cellpose>`_
* Estimates the unmixing coefficients for each epoch with a mutual-information grid search
* Writes an unmixed movie for each plane of the pair

Extraction
----------

The `extraction <https://github.com/AllenNeuralDynamics/aind-ophys-extraction/>`_ step
(library: `aind-ophys-extraction-library <https://github.com/AllenNeuralDynamics/aind-ophys-extraction-library/>`_)
detects cells and extracts their signals in each plane:

* Cell detection, selected with the ``init`` parameter:
   * Cellpose on the mean, maximum or enhanced mean projection image
   * Suite2p functional detection, with or without sparse mode
   * `CaImAn <https://github.com/flatironinstitute/CaImAn>`_ functional detection
* ROI and neuropil fluorescence traces
* Neuropil correction
* For multiplane sessions, it runs on the decrosstalk movie

dF/F
----

The `dF/F <https://github.com/AllenNeuralDynamics/aind-ophys-dff/>`_ step
(library: `aind-ophys-dff-library <https://github.com/AllenNeuralDynamics/aind-ophys-dff-library/>`_)
computes dF/F for every ROI, using
`aind-ophys-utils <https://github.com/AllenNeuralDynamics/aind-ophys-utils/>`_:

* Triexponential baseline fit (default) or rolling-percentile baseline
* Noise and skewness estimates for every trace

Classifier
----------

The `classifier <https://github.com/AllenNeuralDynamics/aind-ophys-classifier/>`_ step
(library: `aind-ophys-classifier-library <https://github.com/AllenNeuralDynamics/aind-ophys-classifier-library/>`_)
labels each ROI in each plane. It is the only step that requires a GPU:

* Embeds the ROI images with `ROICaT <https://github.com/RichieHakim/ROICaT>`_'s ROInet
* Classifies every ROI as soma and as dendrite with two pretrained ONNX classifiers
* Flags ROIs near the field-of-view border

Events
------

The `event detection <https://github.com/AllenNeuralDynamics/aind-ophys-oasis-event-detection/>`_ step
(library: `aind-ophys-oasis-event-detection-library <https://github.com/AllenNeuralDynamics/aind-ophys-oasis-event-detection-library/>`_)
infers neural events from each dF/F trace with
`OASIS <https://github.com/j-friedrich/OASIS>`_:

* Deconvolved events and a denoised trace for every ROI
* Model parameters estimated from the noise level of each trace

NWB Packaging
-------------

The `NWB packaging <https://github.com/AllenNeuralDynamics/aind-ophys-nwb/>`_ step
(library: `aind-ophys-nwb-library <https://github.com/AllenNeuralDynamics/aind-ophys-nwb-library/>`_)
runs once per session and writes one NWB Zarr store containing, for each plane:

* ROI and neuropil masks, with the classifier labels
* Projection and segmentation images
* Raw, neuropil, neuropil-corrected, dF/F and event traces

Metadata Merge
--------------

The final `metadata merge <https://github.com/AllenNeuralDynamics/aind-metadata-manager-capsule/>`_ step
(library: `aind-metadata-manager <https://github.com/AllenNeuralDynamics/aind-metadata-manager/>`_):

* Merges every step's ``processing.json`` into one run-level ``processing.json``
* Merges every step's ``quality_control.json`` into one run-level ``quality_control.json``
* Writes the derived ``data_description.json`` and copies the session's other metadata files
