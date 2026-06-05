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

* [aind-metadata-manager-capsule](https://github.com/AllenNeuralDynamics/aind-metadata-manager-capsule): The processing JSON generated for each plane passing through each processing capsule are appended together and saved into the top-level session directory.

# Running on HPC (Slurm + Singularity)

The pipeline can run off-Code-Ocean on a Slurm cluster. **Current scope: motion_correction only** — it's the only capsule with a published GHCR image. Other steps still reference the Code Ocean–internal Docker registry and will fail under `-profile hpc` until they are published to GHCR (see "Extending to other capsules" below).

## One-time setup

1. **Install Nextflow** if your cluster doesn't provide it as a module:

   ```bash
   curl -s https://get.nextflow.io | bash
   mkdir -p ~/.local/bin
   mv nextflow ~/.local/bin/
   chmod +x ~/.local/bin/nextflow
   which nextflow   # should resolve under ~/.local/bin
   ```

   Note: Nextflow ≥ 26 enforces strict DSL syntax. The pipeline has been updated to comply; older Nextflow versions also work.

2. **Authenticate to GitHub Container Registry.** The motion-correction image is private. Create a [GitHub Personal Access Token](https://github.com/settings/tokens) (classic) with `read:packages` scope, then export both vars in your shell (and add to `~/.bashrc` to persist):

   ```bash
   export SINGULARITY_DOCKER_USERNAME='<github-username>'
   export SINGULARITY_DOCKER_PASSWORD='ghp_xxxxxxxxxxxx'
   ```

   The `hpc` profile in `pipeline/nextflow.config` forwards these vars to each Slurm worker. You must have read access to the package from the `AllenNeuralDynamics` GHCR org for the pull to succeed.

3. **Stage the input session.** Because login-node home directories are usually small, symlink (don't copy) from a network share:

   ```bash
   mkdir -p <repo-root>/data
   ln -s /allen/aind/scratch/<user>/<session-name> <repo-root>/data/<session-name>
   ln -s /allen/aind/scratch/<user>/<session-name>/pipeline_parameters.json \
         <repo-root>/data/pipeline_parameters.json
   ```

   Expected layout under `data/<session-name>/`: a `pophys/` subdir plus the standard AIND JSONs (`session.json`, `data_description.json`, `processing.json`). `pipeline_parameters.json` lives in `data/`, **not** inside the session dir.

4. **(Optional) Pre-pull the Singularity image** on a login node so the first job hits cache:

   ```bash
   export NXF_SINGULARITY_CACHEDIR=/allen/aind/scratch/<user>/.singularity_cache
   mkdir -p "$NXF_SINGULARITY_CACHEDIR"
   singularity pull --name "$NXF_SINGULARITY_CACHEDIR/ghcr.io-allenneuraldynamics-motion-correction-latest.img" \
       docker://ghcr.io/allenneuraldynamics/motion-correction:latest
   ```

5. **Verify the partition.** `sinfo -p <partition>` to confirm it exists and accepts your jobs. Account flags (`-A` / `--slurm_account`) are only required if `sacctmgr show assoc user=$USER` returns a non-empty account.

## Submitting a run

A working launcher script is checked in as `run_hpc.sh` at the repo root. From the **repo root** (not from `pipeline/`):

```bash
sbatch run_hpc.sh
```

Edit `run_hpc.sh` to point `--local_session_dir` at your symlinked session and to set `--slurm_partition`. The script runs Nextflow as a single, cheap head job (`-N 1 -n 1 -c 1 --mem=2G`); Nextflow itself dispatches the heavyweight per-task Slurm jobs.

Equivalent one-shot command if you prefer to skip the wrapper:

```bash
nextflow run pipeline/main.nf -profile hpc \
    --local_session_dir <session-name> \
    --slurm_partition <partition> \
    --acquisition_data_type single \
```

## Monitoring

```bash
squeue -u $USER             # your queued / running jobs
scontrol show job <JOBID>   # full detail on one job
tail -f nf_<JOBID>.out      # live Nextflow progress (head job)
sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS    # post-mortem
```

## Extending to other capsules

Each pipeline step lives in its own `aind-ophys-*` repo with a Dockerfile. To add HPC support for an additional capsule:

1. Publish a container image to GHCR (the existing capsule Dockerfiles target the Code Ocean registry; publishing to GHCR is a CI / release-workflow change in the capsule repo, not in this repo).
2. Add a `withName: <process_name> { container = 'ghcr.io/...' }` override inside the `hpc` profile in `pipeline/nextflow.config`, alongside the existing `motion_correction` block.
3. Confirm any Code Ocean–injected env vars the process script uses (`GIT_ACCESS_TOKEN`, `GIT_HOST`) have HPC equivalents — for the motion-correction spike, the `${capsule_code_dir}` param replaces the runtime `git clone`, so capsule code is staged in advance rather than fetched per job.
4. Drop the `-until motion_correction` from the launcher to let the new step run.

## Known limitations

- `:latest` tags are mutable. Pin specific image tags once the GHCR images are versioned.
- Streaming directly from S3 via `--ophys_mount_url` is not supported on HPC — pre-sync or symlink the session into `data/` and pass `--local_session_dir`.
- The `data/schemas/` and `data/2p_roi_classifier/` Code Ocean datasets are skipped on HPC (`checkIfExists: false`); steps that need them will fail until those assets are staged locally.

# Parameters

If using in Code Ocean, use the `App Builder` panel to tune parameters. You have the option of using the `pipeline_parameters.json` in the root directory to tune parameters as well. To use this file, copy it into the `/data` directory and do not rename the file.

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

If using in Code Ocean, use the `App Builder` panel to tune parameters. You have the option of using the `pipeline_parameters.json` in the root directory to tune parameters as well. To use this file, copy it into the `/data` directory and do not rename the file.

Below are the parameters and their default values. Navigate to the processing repositories to view descriptions

**Top Level Paramters**
```
acquisition_data_type: single  # Single plane or multiplane configuration
debug: 0  # Run pipeline in debug mode
input_dir: /data  # Input data directory
output_dir: /results  # Where to store results
temp_dir: /scratch  #  Temporary directory
```

**Motion Correction**
```
do_registration: True
batch_size: 500
maxregshift: 0.1
align_by_chan: 1
smooth_sigma_time: 0
smooth_sigma: 1.15
nonrigid: True
maxregshiftNR: 5
snr_thresh: 1.2
data_type: h5
```
**Extraction**
```
diameter: 0
cellprob_threshold: 0.0
init: sparsery
functional_chan: 1
threshold_scaling: 1
max_overlap : 0.75
soma_crop: 0
allow_overlap: 0
```
**dF / F**
```
long_window: 60
short_window: 3.333
inactive_percentile: 10
noise_method: mad
```
**Metadata Manager**
```
processor_full_name: pipeline user
modality: pophys
pipeline_version: 
aggregate_quality_control: 0
verbose: 1
skip_ancillary_files: 0
data_summary: "data notes"
```
