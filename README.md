# Planar Optical Physiology Processing Pipeline

The planar optical physiology pipeline is capable of processing single plane and multiplane image data. Inputs can be in the form of an HDF5 timeseries or of a group of TIFF files. Motion correction and segmentation are both done using [Suite2p](https://github.com/MouseLand/suite2p) and the final outputs of the pipeline are the cellular events detected by [OASIS](https://github.com/j-friedrich/OASIS). For multiplane data only, a step to de-multiplex ghosting in images acquired asynchronously is applied for better ROI and thus event detection.

The pipeline runs on [Nextflows](https://www.nextflow.io/) DLS2 and contains the following steps:

* [aind-pophys-converter-capsule](https://github.com/AllenNeuralDynamics/aind-pophys-converter-capsule): Used to determine input type and pre-process data to run in the pipeline. For multiplane data that is stored in an interleaved TIFF, data are de-interleaved into planes and stored as separate HDF5 timeseries. Data collected on our Bergamo rig requires special handling of portions (or epochs) of the data. Epochs need to be annotated for special handling in the motion correction and segmentation repositories. 

* [aind-ophys-motion-correction](https://github.com/AllenNeuralDynamics/aind-ophys-motion-correction): Suite2p non-rigid motion correction is run on each plane in parallel.

* [aind-ophys-group-planes](https://github.com/AllenNeuralDynamics/aind-ophys-group-planes): Uses metadata from the session JSON file to associate grouped planes for decrosstalk processing.

* [aind-ophys-decrosstalk-roi-images](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images): Removes the ghosting of cells from plane pairs scanned consecutively.

* [aind-ophys-extraction](https://github.com/AllenNeuralDynamics/aind-ophys-extraction): Combination of Cellpose and Suite2p cell detection and extraction.

* [aind-ophys-dff](https://github.com/AllenNeuralDynamics/aind-ophys-dff/blob/main/code/run_capsule.py#L116): Uses [aind-ophys-utils](https://github.com/AllenNeuralDynamics/aind-ophys-utils/tree/main) to compute the delta F over F from the fluorescence traces.

* [aind-ophys-oasis-event-detection](https://github.com/AllenNeuralDynamics/aind-ophys-oasis-event-detection): Generates events for each detected ROI using the OASIS library.

* [aind-ophys-processing-json-collection](https://github.com/AllenNeuralDynamics/aind-ophys-processing-json-collection): The processing JSON generated for each plane are appended together and saved into the top-level session directory.

# Input

Currently, the pipeline supports the following input data types:

* `aind`: data ingestion used at AIND. The input folder must contain a subdirectory called `pophys` (for planar-ophys) which contains the raw TIFF timeseries. The root directory must contain JSON files following [aind-data-schema](https://github.com/AllenNeuralDynamics/aind-data-schema).

```plaintext
📦data
 ┣ 📂MouseID_YYYY-MM-DD_HH-M-S
 ┃ ┣ 📂pophys
 ┣ 📜data_description.json
 ┣ 📜session.json
 ┗ 📜processing.json
 ```

 The `pophys` directory can take in a TIFF, series of TIFFs or an HDF5 file.

# Output

Tools used to read files in python are [h5py](https://pypi.org/project/h5py/), json and csv.

* `aind`: The pipeline outputs are saved under the `results` top-level folder with JSON files following [aind-data-schema](https://github.com/AllenNeuralDynamics/aind-data-schema). Each field of view (plane) runs as a parallel process from motion-correction to event detection. The first subdirectory under `results` is named according to Allen Institute for Neural Dynamics standard for derived asset formatting. Below that folder, each field of view is named according to the anatomical region of imaging and the index (or plane number) it corresponds to. The index number is generated before processing in the session.json which details out the imaging configuration during acquisition. As the movies go through the processsing pipeline, a JSON file called processing.json is created where processing data from input parameters are appended. The final JSON will sit at the root of the `results` folder at the end of processing. 

```plaintext
📦results
 ┣ 📂multiplane-ophys_MouseID_YYYY-MM-DD_HH-M-S_
 ┃ ┣ 📂anatomicalRegion_index
 ┃ ┣ 📂...
 ┃ ┣ 📂anatomicalRegion_index
 ┗ 📜processing.json
 ```

The following folders will be under the field of view directory within the `results` folder:

`ophys_converter`

The converter can determine if a session is multiplane or related to AIND's Bergamo rig. If the data are neither of thess, the converter will drop a text file. The multiplane and Bergamo outputs do not get saved since they are transitional artifacts of processing. 

`motion_correction`

```plaintext
📦motion_correction
 ┣ 📜anatomicalRegion_index_registered.h5
 ┣ 📜anatomicalRegion_index_max_projection.png
 ┣ 📜anatomicalRegion_index_motion_preview.webm
 ┣ 📜anatomicalRegion_index_average_projection.png
 ┣ 📜anatomicalRegion_index_summary_nonrigid.png
 ┣ 📜anatomicalRegion_index_summary_PC0high.png
 ┣ 📜anatomicalRegion_index_summary_PC0low.png
 ┣ 📜anatomicalRegion_index_summary_PC0rof.png
 ┣ 📜anatomicalRegion_index_summary_PC27high.png
 ┣ 📜anatomicalRegion_index_summary_PC27low.png
 ┣ 📜anatomicalRegion_index_summary_PC27rof.png
 ┗ 📜anatomicalRegion_index_registration_summary.png
 ```

Motion corrected data are stored as a numpy array under the 'data' key of the registered data asset.

`decrosstalk`

```plaintext
📦decrosstalk
 ┣ 📜anatomicalRegion_index_decrosstalk_episodic_mean_fov.h5
 ┣ 📜anatomicalRegion_index_decrosstalk_episodic_mean_fov.webm
 ┣ 📜anatomicalRegion_index_registered_episodic_mean_fov.h5
 ┗ 📜anatomicalRegion_index_registered_to_pair_episodic_mean_fov.h5
 ```

All data within the following HDF5 files are stored under the 'data' key as a NumPy array. This capsule is only relevant for multiplane imaging data.

`extraction`

```plaintext
📦extraction
 ┣ 📜anatomicalRegion_index_ROIs_withIDs.png
 ┣ 📜anatomicalRegion_index_ROIs.png
 ┗ 📜anatomicalRegion_index_extraction.h5
```
Visit [aind-ophys-extraction](https://github.com/AllenNeuralDynamics/aind-ophys-extraction) to view the contents of the extracted file.

`dff`

```plaintext
📦dff
 ┗ 📜anatomicalRegion_index_dff.h5
```
dF/F signals for each ROI are packed into the 'data' key within the dataset. 

`events`

```plaintext
📦events
 ┣ 📂plots
 ┃ ┣ 📜cell_0.png
 ┃ ┣ 📜cell_1.png
 ┃ ┣ 📜...
 ┃ ┗ 📜cell_n.png
 ┗ 📜anatomicalRegion_index_events.h5
```
The events.h5 contains the following keys:

* 'cell_roi_ids', list of ROI ID values
* 'events', event traces for each ROI

# Parameters

Argparse is used to parse arguments from the command line. All capsules take in the input directory and output directory.

`aind-ophys-motion-correction` and `aind-ophys-extraction-suite2p` can take in parameters to adjust all Suite2p motion-correction and segmentation settings.

`aind-ophys-motion-correction`

```bash
        --input_dir                                   Input directory. (default: '/data')
        --output_dir                                  Output directory to save the data to. (default: '/results')
        --data_type                                   Data input type, h5 or TIFF. (default: h5)
        --debug                                       Choose to run in debug form where it clips the incoming movie to 6 minutes. (default: False)
        --force_refImg                                Force the use of an external reference image (default: True)

        --outlier_detrend_window                      For outlier rejection in the xoff/yoff outputs of suite2p, the offsets are first de-trended with a median filter of this duration [seconds]. This value is ~30 or 90 samples in size for 11 and 31 Hz sampling rates respectively.

        --outlier_maxregshift                         Units [fraction FOV dim]. After median-filter etrending, outliers more than this value are clipped to this value in x and y offset, independently.This is similar to Suite2Ps internal maxregshift, but allows for low-frequency drift. Default value of 0.05 is typically clipping outliers to 512 * 0.05 = 25 pixels above or below the median trend.

        --clip_negative                               Whether or not to clip negative pixel values in output. Because the pixel values in the raw movies are set by the current coming off a photomultiplier tube, there can be pixels with negative values (current has a sign), possibly due to noise in the rig. Some segmentation algorithms cannot handle negative values in the movie, so we have this option to artificially set those pixels to zero.

        --max_reference_iterations                    Maximum number of iterations for creating a reference image (default: 8)

        --auto_remove_empty_frames                    Automatically detect empty noise frames at the start and end of the movie. Overrides values set in trim_frames_start and trim_frames_end. Some movies arrive with otherwise quality data but contain a set of frames that are empty and contain pure noise. When processed, these frames tend to receive large random shifts that throw off motion border calculation. Turning on this setting automatically detects these frames before processing and removes them from reference image creation, automated smoothing parameter searches, and finally the motion border calculation. The frames are still written however any shift estimated is removed and their shift is set to 0 to avoid large motion borders.

        --trim_frames_start                           Number of frames to remove from the start of the movie if known. Removes frames from motion border calculation and resets the frame shifts found. Frames are still written to motion correction. Raises an error if auto_remove_empty_frames is set and trim_frames_start > 0

        --trim_frames_end                             Number of frames to remove from the end of the movie if known. Removes frames from motion border calculation and resets the frame shifts found. Frames are still written to motion correction. Raises an error if uto_remove_empty_frames is set and trim_frames_start > 0

        --do_optimize_motion_params                   Do a search for best parameters of smooth_sigma and smooth_sigma_time. Adds significant runtime cost to motion correction and should only be run once per experiment with the resulting parameters being stored for later use.

        --use_ave_image_as_reference                  Only available if `do_optimize_motion_params` is set. After the a best set of smoothing parameters is found, use the resulting average image as the reference for the full registration. This can be used as two step registration by setting by setting smooth_sigma_min=smooth_sigma_max and smooth_sigma_time_min=smooth_sigma_time_max and steps=1.

```

`aind-ophys-extraction-suite2p`

```bash
        --diameter                                    Diameter that will be used for cellpose. If set to zero, diameter is estimated.
    
        --anatomical_only                             If greater than 0, specifies what to use Cellpose on. 1: Will find masks on max projection image divided by mean image 2: Will find masks on mean image 3: Will find masks on enhanced mean image 4: Will find masks on maximum projection image
    
        --denoise                                     Whether or not binned movie should be denoised before cell detection.
    
        --cellprob_threshold                          Threshold for cell detection that will be used by cellpose.
    
        --flow_threshold                              Flow threshold that will be used by cellpose.
    
        --spatial_hp_cp                               Window for spatial high-pass filtering of image to be used for cellpose

        --pretrained_model                            Path to pretrained model or string for model type (can be user’s model).

        --use_suite2p_neuropil                        Whether to use the fix weight provided by suite2p for neuropil correction. If not, we use a mutual information based method.

```

# Run

`aind` Runs in the Code Ocean pipeline [here](https://codeocean.allenneuraldynamics.org/capsule/7026342/tree). If a user has credentials for `aind` Code Ocean, the pipeline can be run using the [Code Ocean API](https://github.com/codeocean/codeocean-sdk-python). 

Derived from the example on the [Code Ocean API Github](https://github.com/codeocean/codeocean-sdk-python/blob/main/examples/run_pipeline.py)

```python
import os

from codeocean import CodeOcean
from codeocean.computation import RunParams
from codeocean.data_asset import (
    DataAssetParams,
    DataAssetsRunParam,
    PipelineProcessParams,
    Source,
    ComputationSource,
    Target,
    AWSS3Target,
)

# Create the client using your domain and API token.

client = CodeOcean(domain=os.environ["CODEOCEAN_URL"], token=os.environ["API_TOKEN"])

# Run a pipeline with ordered parameters.

run_params = RunParams(
    pipeline_id=os.environ["PIPELINE_ID"],
    data_assets=[
        DataAssetsRunParam(
            id="eeefcc52-b445-4e3c-80c5-0e65526cd712",
            mount="Reference",
        ),
)

computation = client.computations.run_capsule(run_params)

# Wait for pipeline to finish.

computation = client.computations.wait_until_completed(computation)

# Create an external (S3) data asset from computation results.

data_asset_params = DataAssetParams(
    name="My External Result",
    description="Computation result",
    mount="my-result",
    tags=["my", "external", "result"],
    source=Source(
        computation=ComputationSource(
            id=computation.id,
        ),
    ),
    target=Target(
        aws=AWSS3Target(
            bucket=os.environ["EXTERNAL_S3_BUCKET"],
            prefix=os.environ.get("EXTERNAL_S3_BUCKET_PREFIX"),
        ),
    ),
)

data_asset = client.data_assets.create_data_asset(data_asset_params)

data_asset = client.data_assets.wait_until_ready(data_asset)
```


