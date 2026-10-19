# Running on a SLURM cluster

This guide runs the pipeline on a SLURM cluster with Apptainer (or Singularity), using the
development GHCR images. One small head job runs Nextflow, which submits each processing step
as its own SLURM job inside that step's container.

**Status:** no run has been made on a SLURM cluster yet.

## Open items

| # | Item | Why |
|---|---|---|
| 1 | Merge the wrapper and library path fixes, then repin the manifest to the merge commits | The manifest pins open PR heads. Each step clones its wrapper and checks out the pinned commit, so keep those branches until the repin. |
| 2 | A short Code Ocean debug run with `image_set=development-ghcr` on this branch | Confirms the task-relative layout before the cluster run. |
| 3 | Model assets published outside Code Ocean | Only Allen Code Ocean users can download the assets in section 3. |

Known limitation: an `OPHYS_MOUNT_URL` that is a local directory skips the converter, so raw
sessions must come from S3.

## Allen Institute HPC

Source: the IT Operations Confluence pages *Slurm Quick-Start Guide*, *High-Performance
Computing (HPC)*, and *Container support for HPC (Singularity / Apptainer)*. Questions go to
helpdesk@alleninstitute.org or the Slurm chat on Teams.

- **Login node:** `ssh hpc.corp.alleninstitute.org`. Work outside Slurm on it is prohibited,
  including image pulls; Nextflow itself runs inside the `sbatch` head job.
- **Partition:** always pass one. Jobs without a partition land in the limited `aibs_debug`
  partition. List partitions with `sinfo -o %P` and limits with `sacctmgr show qos -p`.
- **GPUs** are not tied to a partition; request a model with `--gres=gpu:<type>:1`. The
  classifier's CUDA 13 runtime needs a Turing or newer GPU, so exclude the V100, Titan Xp, and
  1080 Ti nodes by setting `GPU_CLUSTER_OPTIONS`, for example `--gres=gpu:a100:1`. Check the
  type names with `sinfo -o "%N %G"`.
- **Storage:** keep the work directory, results, and image cache under `/allen` so every node
  sees them (for example `/allen/aind/scratch/<group>/<user>`). Node-local
  `/scratch/fast/$SLURM_JOB_ID` is deleted when each job ends and cannot hold the work
  directory.
- **Containers** run as your own user; `/allen` and `/shared` are mounted automatically.
- **Modules:** run `module avail` from a compute node (`srun -p aibs_debug -c1 --mem=1G -t 10 --pty bash`).
  Java modules exist; Nextflow may need installing (section 1).

## 1. Requirements

- SLURM with a CPU partition and a Turing-or-newer GPU (the classifier needs one).
- Apptainer or Singularity on the compute nodes.
- Java 17 or newer and Nextflow 24.10.4, the version Code Ocean runs.
- Outbound network from compute nodes to `github.com`, `ghcr.io`, and `s3.amazonaws.com`.
- Shared scratch for the work directory, results, and image cache. The work directory holds a
  full copy of the input session plus intermediate files; a full-length eight-plane run wrote
  about 640 GB of results on Code Ocean.

Find partitions, GPU resources, and time limits:

```bash
sinfo -o "%P %G %l %c %m"
```

Install Nextflow if the cluster has no module:

```bash
export NXF_VER=24.10.4
curl -s https://get.nextflow.io | bash
mv nextflow ~/bin/
```

## 2. Get the pipeline

```bash
git clone --branch proj21/multi-backend-refactor \
  https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
cd aind-pophys-pipeline
```

## 3. Stage models and schemas

Four Code Ocean data assets supply models and the NWB extension schema. Download each from its
Code Ocean data asset page and copy it into the repository's `data/` directory, keeping these
names. Leave `DATA_PATH` unset so it defaults to that directory.

| Directory | Code Ocean data asset | Files |
|---|---|---|
| `data/schemas/` | [Ophys_Extension_schema_10_14_2024_13_44](https://codeocean.allenneuraldynamics.org/data-assets/fb4b5cef-4505-4145-b8bd-e41d6863d7a9) | `ndx-aibs-behavior-ophys.extension.yaml`, `ndx-aibs-behavior-ophys.namespace.yaml` |
| `data/2p_roi_classifier/` | [paninhibitory_omfish_roi_classifier](https://codeocean.allenneuraldynamics.org/data-assets/57a10c5f-468f-4bb2-b3c6-7f4a80efa8ae) | `soma.classification_training.autoclassifier.onnx`, `dendrite.classification_training.autoclassifier.onnx` (the rest of the asset is unused training output) |
| `data/cellpose_models/` | [cellpose-cyto-cyto3](https://codeocean.allenneuraldynamics.org/data-assets/df0e5676-1354-4353-8b2c-f8062aa485db) | `cyto3`, `cytotorch_0`, `size_cyto3.npy`, `size_cytotorch_0.npy` |
| `data/roinet/` | [roicat-roinet-classification](https://codeocean.allenneuraldynamics.org/data-assets/7e4bd8f4-8881-4541-94b4-d1ac714d4a07) | `ROInet.zip`, `torch/hub/checkpoints/convnext_tiny-983f1562.pth` (keep the nested path) |

## 4. Write a parameter file

Start from the parameters of the selected Code Ocean run and switch to a short debug run of a
multiplane session:

```bash
python3 - <<'EOF'
import json
params = json.load(open("pipeline/baseline.json"))["parameters"]
params.update({"debug": "True", "acquisition_data_type": "multiplane",
               "soma-classifier-path": "", "dendrite-classifier-path": ""})
json.dump(params, open("hpc_run_parameters.json", "w"), indent=2)
EOF
```

`debug=True` caps the number of frames per plane. `acquisition_data_type` must match the
session; the pipeline default is `single`. Empty classifier paths select the models under
`data/2p_roi_classifier/`; the recorded Code Ocean values point at `/data`, which does not exist
in a task.

## 5. Submit

Set the variables, then submit the head job. Command-line `sbatch` options override the
placeholders inside `slurm_submit.sh`.

```bash
export PIPELINE_PATH="$PWD/pipeline"
export DEFAULT_QUEUE=<cpu-partition>
export GPU_CLUSTER_OPTIONS='--gres=gpu:a100:1'
export S3_ANONYMOUS=true
export OPHYS_MOUNT_URL=s3://aind-open-data/multiplane-ophys_849375_2026-05-20_12-10-09
export PARAMS_FILE="$PWD/hpc_run_parameters.json"
export RUN_ROOT=/allen/aind/scratch/<group>/$USER/pophys-hpc
export RESULTS_PATH="$RUN_ROOT/results"
export WORKDIR="$RUN_ROOT/work"
export NXF_APPTAINER_CACHEDIR="$RUN_ROOT/apptainer-cache"
export NXF_SINGULARITY_CACHEDIR="$NXF_APPTAINER_CACHEDIR"
export NXF_VER=24.10.4

sbatch --partition="$DEFAULT_QUEUE" --time=24:00:00 \
  --output="$RUN_ROOT/head-%j.out" pipeline/slurm_submit.sh
```

The session above is public (82 GB, eight planes). A debug run of the same session at the
same wrapper commits completed on Code Ocean in computation
`38a1356a-e273-4e10-8f7b-157ff8a28aca`; use it as the reference result.

`slurm_submit.sh` runs `preflight.sh`, which stops early if Java, Nextflow, Apptainer or
Singularity, the queue, the parameter file, the image manifest, or `data/` is missing.

## 6. Monitor and resume

```bash
squeue -u "$USER"
tail -f "$RESULTS_PATH/nextflow/nextflow.log"
```

Nextflow writes `report.html`, `timeline.html`, `trace.txt`, and `dag.html` under
`$RESULTS_PATH/nextflow/`. To resume after a failure, resubmit with the same variables and add
`-resume` after the script name:

```bash
sbatch --partition="$DEFAULT_QUEUE" --time=24:00:00 \
  --output="$RUN_ROOT/head-%j.out" pipeline/slurm_submit.sh -resume
```

## 7. Check the result

A zero exit code is not enough. Confirm:

- every plane directory under `$RESULTS_PATH` has `motion_correction`, `movie_qc`,
  `decrosstalk`, `extraction`, `dff`, `events`, and `classification` folders, and
  `motion_correction` contains a `*registered.h5`;
- the NWB output exists (`nwb/pophys.nwb.zarr`);
- `$RESULTS_PATH/processing.json` and `quality_control.json` exist, written by the final
  metadata aggregation step;
- the plane count and processing records match the reference computation.

## Troubleshooting

- **Image pulls fail on compute nodes:** confirm egress with
  `srun -p "$DEFAULT_QUEUE" curl -sI https://ghcr.io`. Images are public; no login is needed.
- **`Set PIPELINE_PATH`:** `sbatch` runs a copy of the script from SLURM's spool directory, so
  the script cannot find the repository by itself.
- **Classifier never starts or fails on CUDA:** check `GPU_CLUSTER_OPTIONS` names an available
  Turing-or-newer GPU type. Set `GPU_QUEUE` only if GPU jobs need a different partition.
- **Slurm commands fail with "Zero Bytes were transmitted":** an expired `SLURM_JWT`;
  run `unset SLURM_JWT`.
- **S3 access denied:** confirm `S3_ANONYMOUS=true` for public buckets; private buckets need AWS
  credentials in the head job's environment instead.
