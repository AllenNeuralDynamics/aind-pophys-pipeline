# Planar Optical Physiology Processing Pipeline

The planar optical physiology pipeline is capable of processing single plane and multiplane image data. Inputs can be in the form of an HDF5 timeseries or of a group of TIFF files. Motion correction is done using [Suite2p](https://github.com/MouseLand/suite2p) and segmentation can be done using Suite2p, Cellpose or CaImAn, see `--init`. Trace extraction with neuropil correction uses either Suite2p or CaImAn, see `--neuropil`.  and the final outputs of the pipeline are the cellular events detected by [OASIS](https://github.com/j-friedrich/OASIS). For multiplane data only, a step to de-multiplex ghosting in images acquired asynchronously is applied for better ROI and thus event detection.

The pipeline runs on [Nextflow](https://www.nextflow.io/) DSL2 and contains the following steps:

* [aind-pophys-converter-capsule](https://github.com/AllenNeuralDynamics/aind-pophys-converter-capsule): Used to determine input type and pre-process data to run in the pipeline. For multiplane data that is stored in an interleaved TIFF, data are de-interleaved into planes and stored as separate HDF5 timeseries. Data collected on our Bergamo rig requires special handling of portions (or epochs) of the data. Epochs need to be annotated for special handling in the motion correction and segmentation repositories. 

* [aind-ophys-motion-correction](https://github.com/AllenNeuralDynamics/aind-ophys-motion-correction): Suite2p non-rigid motion correction is run on each plane in parallel.

* [aind-ophys-group-planes](https://github.com/AllenNeuralDynamics/aind-ophys-group-planes): Uses metadata from the session JSON file to associate grouped planes for decrosstalk processing.

* [aind-ophys-decrosstalk-roi-images](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images): Removes the ghosting of cells from plane pairs scanned consecutively.

* [aind-ophys-extraction](https://github.com/AllenNeuralDynamics/aind-ophys-extraction): Uses a mix-and-match approach to combine Cellpose, Suite2p, and CaImAn for cell detection and signal extraction.

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

The converter can determine if a session is multiplane or related to AIND's Bergamo rig. If the data are neither of these, the converter will drop a text file. The multiplane and Bergamo outputs do not get saved since they are transitional artifacts of processing. 

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

* `events`: The deconvolved neural activity ("events" / "spike rates").
* `denoised`: The inferred denoised fluorescence signal.

# Parameters

Parameters are available to set through the App-Panel in Code Ocean.

**General Parameters**

Data Type - Option to run in multiplane or single plane mode (default: `single`, type: `str`)

**aind-pophys-converter-capsule**

Input directory - Where to find input data (default: `/data`, type: `str`)

Output directory - Where to save outputs (default: `/results`, type: `str`)

Temporary directory - Specify temporary save location (default: `/scratch`, type: `str`)

Debug - Run in debug mode (default: `False`, type: `str`)

**aind-ophys-motion-correction**

Input directory - Where to find input data (default: `/data`, type: `str`)

Data format - Format of input data (default: `HDF5`, type: `str`)

**aind-ophys-extraction**

Initialization - how to run segmentation (default: `mean`, type: `str`)

Diameter - Diameter for cell segmentation of all 4 initialization methods (default: `0`, type: `int`)

**aind-pipeline-processing-metadata-aggregator**

Processor full name - Processor of the data

Copy ancillary files - Copy relevant metadata from the primary asset (default: `False`, type: `bool`)

Create derived data description - Output derived data description to results (default: `False`, type: `bool`)


# Run

`aind` Runs in the Code Ocean pipeline [here](https://codeocean.allenneuraldynamics.org/capsule/7026342/tree). If a user has credentials for `aind` Code Ocean, the pipeline can be run using the [Code Ocean API](https://github.com/codeocean/codeocean-sdk-python). 

Derived from the example on the [Code Ocean API Github](https://github.com/codeocean/codeocean-sdk-python/blob/main/examples/run_pipeline.py)

```python
import os

from codeocean import CodeOcean
from codeocean.computation import (
    DataAssetsRunParam,
    NamedRunParam,
    RunParams,
)
from codeocean.data_asset import (
    Source,
    ComputationSource,
    Target,
    AWSS3Target,
)

# Create the client using your domain and API token.

client = CodeOcean(domain=os.environ["CODEOCEAN_URL"], token=os.environ["API_TOKEN"])

# Run a pipeline with named parameters.

snr_thr = 1.8 # default = 1.5
nb = 3 # default = 2

run_params=RunParams(
    capsule_id=job_settings.pipeline_id,
    data_assets=[
        DataAssetsRunParam(
            id=job_settings.asset_id,
            mount="ophys",
        )
    ],
    named_parameters=[
        NamedRunParam(
            param_name="init", value="greedy_roi"
            ),
        NamedRunParam(
            param_name="neuropil", value="cnmf"
            ),
        NamedRunParam(
            param_name="nb", value=str(nb)
            ),
        NamedRunParam(
            param_name="snr_thr", value=str(snr_thr)
        )
        ],
)

computation = client.computations.run_capsule(run_params)

# Wait for pipeline to finish.

client.computations.wait_until_completed(computation)

# Create an external (S3) data asset from computation results.

data_asset_params = DataAssetParams(
    name="My External Result",
    description="<description of data>",
    mount="<mount>",
    tags=["<version>", "<platform>", "<data_type>"],
    source=Source[
        computation=ComputationSource(
            id=computation.id,
        ),
    ],
    target=Target[
        aws=AWSS3Target(
            bucket=os.environ["EXTERNAL_S3_BUCKET"],
            prefix="<some_prefix>",
        ),
    ],
)

data_asset = client.data_assets.create_data_asset(data_asset_params)

data_asset = client.data_assets.wait_until_ready(data_asset)
```


