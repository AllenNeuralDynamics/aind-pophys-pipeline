# Development GHCR scientific trial

Use only development pipeline `e4c03dcc-f43a-481c-ac55-257cfe538041`
([9120064](https://codeocean.allenneuraldynamics.org/capsule/9120064/tree)),
linked to `proj21/multi-backend-refactor`. Do not sync the production or Project 19 pipeline.

## Image selection

`image_set=default` preserves the existing backend image selection, including the Code
Ocean registry prefix. `image_set=development-ghcr` selects all eleven linux/amd64
digest references from `pipeline/development_images.env`, without that prefix. Unknown
selectors, missing/extra stages, and non-digest image references fail before processing.
This is an explicit development opt-in, not a production promotion.

The ten procps fleet identities match `environment/procps-fleet-inventory.json`.
That inventory records build-time state; its `published=false` fields are not a live
registry status. The separate anonymous-access audit verified all ten published digests.
The splitter digest passed isolated CO probe `18231fbb-991c-451e-8a39-f7a8a4cdb86d`.
These checks establish pullability, not scientific parity or GPU success.

`capsule_versions.env`, library pins, source wrappers, and default images are unchanged.
The splitter and aggregator still fetch CO-internal source in normal execution:
this trial does not establish off-CO portability. `ghcr_smoke_only` remains independent
and unchanged; set it explicitly to `false` for a scientific trial.

## Selected input

Sean selected the Project 19 reference dataset for the first GHCR debug trial.
The Code Ocean data-asset API confirms asset
`ff2fa171-9905-40d8-b058-cbf177e8cbb0` is ready and externally backed by
`s3://aind-open-data/multiplane-ophys_849375_2026-06-20_13-13-04`.
Use that exact source override, leaving persistent attachments unchanged.
Using the same dataset and debug parameters makes this a comparison against the
eight-plane reference run rather than a simultaneous change of input and runtime.

There are three different input identities:

| Evidence | Input |
| --- | --- |
| Selected Project 19 baseline `745be7a`, computation `eea0f242-8983-43e2-a367-430f33c60969` | `ff2fa171-9905-40d8-b058-cbf177e8cbb0` (`multiplane-ophys_849375_2026-06-20_13-13-04`) |
| Current `.codeocean/datasets.json` attached `ophys_mount` | `17ae3eed-ce82-47f1-ad54-1a597c39447c` |
| Current effective `ophys_mount_url` default | `s3://aind-open-data/multiplane-ophys_839909_2026-02-26_15-11-01` |

The S3 source takes precedence over `ophys_mount`. Mounting the baseline asset alone
does **not** select it. The newly declared `ophys_mount_url` App Panel control exposes
the existing source parameter with its existing default; it accepts a nonempty S3 URL
or absolute raw-data directory. An empty value is not a mount fallback. The old inactive
fallback in `main.nf` names `harvard-single`, not `ophys_mount`, and is not an appropriate
multiplane route.

The attached asset's relationship to either dataset is not needed for this trial:
the explicitly selected S3 source takes precedence. No mount changes are required.

## Proposed parameter contract (not submitted)

Start with **every** key/value in `pipeline/baseline.json` → `parameters` (43 keys),
then add exactly:

```json
{
  "image_set": "development-ghcr",
  "ghcr_smoke_only": "false",
  "ophys_mount_url": "s3://aind-open-data/multiplane-ophys_849375_2026-06-20_13-13-04"
}
```

The source above is the approved reference dataset. Retain baseline `debug="True"`,
`acquisition_data_type="multiplane"`, `aggregate_quality_control="0"`, `init="mean"`,
`upgrade_legacy_metadata="True"`, and `processor_full_name="Sean McCulloch"`.
Do not inherit the panel's `single`, `False`, or QC aggregation defaults.
Do not mount a `pipeline_parameters.json`: it can override scientific parameters.
The four shared model/schema mounts match the baseline and stay attached.

After Sean reviews, commits, and pushes, separately authorize development sync and
submission. Confirm all 46 parameter names exist in the synced panel, send them as
top-level `named_parameters` with `processes=[]`, and compare the resolved set immediately.
Undeclared API parameters have previously been silently ignored and launched science.
Confirm logged `stage_images` matches all eleven digests and the source is the approved
dataset. Submission must not proceed on an input or parameter mismatch.

Success requires exit code zero, expected plane count, real per-plane scientific
artifacts, and coherent processing provenance/dependency graph. The selected baseline
has eight debug-length planes and 60 processing records/graph keys. Root QC is intentionally
absent with aggregation disabled. A different input needs its own reviewed expectations;
neither a debug trial nor registry access proves full-length scientific parity.
